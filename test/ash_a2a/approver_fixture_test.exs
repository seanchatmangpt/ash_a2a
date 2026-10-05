# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ApproverFixtureTest do
  @moduledoc """
  Cross-runtime court for the native Swift approver (RFC-SA2A-007 E-I / E-E).

  Fixtures under `test/support/approver_fixtures/` were produced by the Swift
  `SoftwareP256Signer` (`sa2a-approver fixtures`). This test verifies them with plain
  `:crypto` -- an independent runtime and independent verifier -- and mutates them to
  prove each verification can fail. DB-free; no mocks.
  """
  use ExUnit.Case, async: true

  @dir Path.expand("../support/approver_fixtures", __DIR__)
  @swift_elixir_dir Path.expand(
                      "../../sa2a-approver/Tests/SA2AApproverCoreTests/Fixtures/elixir",
                      __DIR__
                    )
  @spki_header Base.decode16!("3059301306072A8648CE3D020106082A8648CE3D030107034200")
  @domain "SA2A-C2-APPROVAL-v1" <> <<0>>
  @n 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551

  defp cases do
    @dir |> Path.join("manifest.json") |> File.read!() |> :json.decode() |> Map.fetch!("cases")
  end

  defp load(dir) do
    rd = fn f -> File.read!(Path.join(dir, f)) end

    %{
      msg: rd.("message.bin"),
      sig: rd.("signature.der"),
      spki: rd.("spki.der"),
      kid: rd.("kid.txt"),
      effect: rd.("effect.json")
    }
  end

  defp point(<<@spki_header, 4, _::binary-size(64)>> = spki),
    do: binary_part(spki, byte_size(@spki_header), 65)

  defp verify(msg, sig, spki) do
    :crypto.verify(:ecdsa, :sha256, msg, sig, [point(spki), :secp256r1])
  rescue
    _ -> false
  end

  # Independent strict-DER oracle (canonical minimal ints, r,s in 1..n-1, no trailing bytes).
  defp strict_der?(<<0x30, len, rest::binary>>) when len < 0x80 and byte_size(rest) == len do
    with {:ok, r, rest} <- der_int(rest), {:ok, s, <<>>} <- der_int(rest) do
      r in 1..(@n - 1) and s in 1..(@n - 1)
    else
      _ -> false
    end
  end

  defp strict_der?(_), do: false

  defp der_int(<<2, l, v::binary-size(l), rest::binary>>) when l >= 1 do
    case v do
      <<b, _::binary>> when b >= 0x80 -> :error
      <<0, b, _::binary>> when b < 0x80 -> :error
      _ -> {:ok, :binary.decode_unsigned(v), rest}
    end
  end

  defp der_int(_), do: :error

  defp kid(spki),
    do: :crypto.hash(:sha256, spki) |> binary_part(0, 16) |> Base.url_encode64(padding: false)

  defp flip(bin, pos, bit) do
    <<pre::binary-size(^pos), b, post::binary>> = bin
    <<pre::binary, Bitwise.bxor(b, Bitwise.bsl(1, bit)), post::binary>>
  end

  test "manifest lists at least three Swift-produced cases" do
    assert length(cases()) >= 3
  end

  for name <- ~w(case1 case2 case3) do
    @name name

    test "#{name}: Swift SoftwareP256Signer output verifies with plain :crypto" do
      f = load(Path.join(@dir, @name))
      assert byte_size(f.spki) == 91
      assert binary_part(f.spki, 0, 26) == @spki_header
      assert strict_der?(f.sig)
      assert verify(f.msg, f.sig, f.spki)
      assert kid(f.spki) == f.kid
      assert byte_size(f.kid) == 22
    end

    test "#{name}: signed bytes are domain + JCS, bound to the effect digest and kid" do
      f = load(Path.join(@dir, @name))
      assert <<@domain, body::binary>> = f.msg
      # Independent JCS oracle: the repo's JCS encoder over the decoded body reproduces the bytes.
      assert Jcs.encode(:json.decode(body)) == body

      m = :json.decode(body)

      assert Map.keys(m) |> Enum.sort() ==
               ~w(alg audience effect_digest expires generation kid nonce not_before policy_epoch principal revocation_epoch v)

      assert m["kid"] == f.kid
      assert m["alg"] == "ES256"
      digest = "sha256:" <> Base.encode16(:crypto.hash(:sha256, f.effect), case: :lower)
      assert m["effect_digest"] == digest
      assert Jcs.encode(:json.decode(f.effect)) == f.effect
    end

    test "#{name}: every single-bit flip of the signature is refused" do
      f = load(Path.join(@dir, @name))

      for byte <- 0..(byte_size(f.sig) - 1), bit <- 0..7 do
        refute verify(f.msg, flip(f.sig, byte, bit), f.spki),
               "flip byte #{byte} bit #{bit} verified"
      end
    end

    test "#{name}: every single-bit flip of every signed byte is refused" do
      f = load(Path.join(@dir, @name))

      for byte <- 0..(byte_size(f.msg) - 1), bit <- [0, 7] do
        refute verify(flip(f.msg, byte, bit), f.sig, f.spki)
      end
    end

    test "#{name}: wrong message, wrong key, truncated and extended signature are refused" do
      f = load(Path.join(@dir, @name))
      other = load(Path.join(@dir, if(@name == "case1", do: "case2", else: "case1")))
      refute verify(other.msg, f.sig, f.spki)
      refute verify(f.msg, f.sig, other.spki)
      refute verify(f.msg, binary_part(f.sig, 0, byte_size(f.sig) - 1), f.spki)
      refute strict_der?(f.sig <> <<0>>)
      refute strict_der?(binary_part(f.sig, 0, byte_size(f.sig) - 1))
    end
  end

  test "WYSIWYS oracle: mutated effect bytes no longer match the signed effect_digest" do
    f = load(Path.join(@dir, "case1"))
    <<@domain, body::binary>> = f.msg
    signed = :json.decode(body)["effect_digest"]
    tampered = String.replace(f.effect, "svc/payments", "svc/payrolls")
    refute tampered == f.effect
    refute "sha256:" <> Base.encode16(:crypto.hash(:sha256, tampered), case: :lower) == signed
  end

  test "mutating any signed field invalidates the signature (ERR7-E-2 shape)" do
    f = load(Path.join(@dir, "case1"))
    <<@domain, body::binary>> = f.msg
    m = :json.decode(body)

    for {k, v} <- m do
      mutated = Map.put(m, k, if(is_integer(v), do: v + 1, else: v <> "x"))
      msg = @domain <> Jcs.encode(mutated)
      refute verify(msg, f.sig, f.spki), "mutating #{k} still verified"
    end
  end

  test "Elixir-signed fixture (Swift reverse-direction input) is self-consistent under :crypto" do
    f = load(@swift_elixir_dir)
    assert verify(f.msg, f.sig, f.spki)
    assert strict_der?(f.sig)
    assert kid(f.spki) == f.kid
    <<@domain, body::binary>> = f.msg
    assert Jcs.encode(:json.decode(body)) == body
    refute verify(flip(f.msg, 30, 0), f.sig, f.spki)
  end
end
