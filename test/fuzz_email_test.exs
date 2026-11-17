# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.FuzzEmailTest do
  # Seeded fuzz of `AshA2A.Email.Inbound.parse/1` and `AshA2A.Email.Dkim.verify/2`
  # over mutated signed messages: refusal or a valid unchanged result, never a raise.
  use ExUnit.Case, async: true

  alias AshA2A.Email.{Dkim, Inbound}
  alias AshA2A.FuzzGen

  @now 1_800_000_000
  @iterations FuzzGen.iterations(300)

  setup_all do
    {:RSAPrivateKey, _, n, e, _, _, _, _, _, _, _} =
      priv = :public_key.generate_key({:rsa, 1024, 65537})

    {:SubjectPublicKeyInfo, der, :not_encrypted} =
      :public_key.pem_entry_encode(:SubjectPublicKeyInfo, {:RSAPublicKey, n, e})

    {:ok, priv: priv, p: Base.encode64(der)}
  end

  defp opts(p, extra \\ []) do
    resolver = fn
      "example.com", "sel" -> {:ok, p}
      _, _ -> {:error, :nxdomain}
    end

    [key_resolver: resolver, now: fn -> @now end] ++ extra
  end

  defp canon_body(body) do
    lines =
      body
      |> String.split("\r\n")
      |> Enum.map(&(&1 |> String.replace(~r/[ \t]+/, " ") |> String.trim_trailing()))
      |> Enum.reverse()
      |> Enum.drop_while(&(&1 == ""))
      |> Enum.reverse()

    if lines == [], do: "", else: Enum.join(lines, "\r\n") <> "\r\n"
  end

  defp canon_hdr({n, v}),
    do: String.downcase(n) <> ":" <> (v |> String.replace(~r/[ \t]+/, " ") |> String.trim())

  # Independent test-side signer (same construction as email_dkim_test.exs).
  defp sign(priv, headers, body, o \\ []) do
    h = Keyword.get(o, :h, ["from", "to", "subject"])
    bh = Keyword.get(o, :bh, :crypto.hash(:sha256, canon_body(body)) |> Base.encode64())
    extra = Keyword.get(o, :tags, "")

    value =
      "v=1; a=rsa-sha256; c=relaxed/relaxed; d=example.com; s=sel; h=#{Enum.join(h, ":")}; bh=#{bh};#{extra} b="

    signed =
      h
      |> Enum.map(fn name ->
        headers |> Enum.reverse() |> Enum.find(fn {n, _} -> String.downcase(n) == name end)
      end)
      |> Enum.reject(&is_nil/1)

    data =
      Enum.map_join(signed, &(canon_hdr(&1) <> "\r\n")) <> canon_hdr({"DKIM-Signature", value})

    sig = :public_key.sign(data, :sha256, priv) |> Base.encode64()
    sig = Keyword.get(o, :sig, sig)

    folded =
      sig |> String.graphemes() |> Enum.chunk_every(60) |> Enum.map_join("\r\n\t", &Enum.join/1)

    all = [{"DKIM-Signature", " " <> value <> folded}] ++ headers
    Enum.map_join(all, &"#{elem(&1, 0)}:#{elem(&1, 1)}\r\n") <> "\r\n" <> body
  end

  defp headers,
    do: [
      {"From", " Alice <alice@example.com>"},
      {"To", " bob@example.org"},
      {"Subject", " Hello   there"},
      {"X-Other", " unsigned"}
    ]

  @body "Approve 1.\r\n  trailing   spaces \r\n\r\n"

  defp outcome(fun) do
    case FuzzGen.run_with_deadline(fun) do
      {:ok, result} -> result
      other -> flunk("raised or hung: #{inspect(other, limit: 6)}")
    end
  end

  defp essence({:ok, i}), do: {i.from, i.to, i.subject, String.trim(i.body_text)}
  defp essence(other), do: other

  test "flipping any single byte of a valid signed message: refusal or same result, never a raise",
       %{priv: priv, p: p} do
    msg = sign(priv, headers(), @body)
    assert :ok = Dkim.verify(msg, opts(p))
    original = essence(Inbound.parse(msg))

    for i <- 0..(byte_size(msg) - 1), mask <- [0x01, 0x20, 0xFF] do
      <<pre::binary-size(^i), b, post::binary>> = msg
      mutated = <<pre::binary, Bitwise.bxor(b, mask), post::binary>>

      case outcome(fn -> Dkim.verify(mutated, opts(p)) end) do
        {:error, reason} when is_atom(reason) ->
          :ok

        :ok ->
          # an accepted message must mean the same thing to the parser
          assert essence(outcome(fn -> Inbound.parse(mutated) end)) == original,
                 "byte #{i} ^ #{mask} accepted but changed the message: #{inspect(mutated)}"
      end

      parsed = outcome(fn -> Inbound.parse(mutated) end)
      assert match?({:ok, _}, parsed) or match?({:error, _}, parsed)
    end
  end

  test "random byte deletions, insertions and truncations never raise", %{priv: priv, p: p} do
    FuzzGen.seed(1801)
    msg = sign(priv, headers(), @body)

    for _ <- 1..@iterations do
      i = FuzzGen.int(byte_size(msg))
      <<pre::binary-size(^i), rest::binary>> = msg

      mutated =
        case FuzzGen.int(4) do
          0 ->
            pre

          1 ->
            pre <> FuzzGen.random_bytes(1 + FuzzGen.int(8)) <> rest

          2 ->
            n = min(1 + FuzzGen.int(8), byte_size(rest))
            pre <> binary_part(rest, n, byte_size(rest) - n)

          3 ->
            msg <> FuzzGen.random_bytes(FuzzGen.int(64))
        end

      assert match?({:error, _}, outcome(fn -> Dkim.verify(mutated, opts(p)) end)) or
               outcome(fn -> Dkim.verify(mutated, opts(p)) end) == :ok

      parsed = outcome(fn -> Inbound.parse(mutated) end)
      assert match?({:ok, _}, parsed) or match?({:error, _}, parsed)
    end
  end

  test "tag lists: duplicates, junk, folded and huge headers, bad base64, bh mismatch",
       %{priv: priv, p: p} do
    refused = fn msg -> {:error, _} = outcome(fn -> Dkim.verify(msg, opts(p)) end) end

    assert {:error, :duplicate_tag} =
             Dkim.verify(sign(priv, headers(), @body, tags: " d=evil.com;"), opts(p))

    assert {:error, :duplicate_tag} =
             Dkim.verify(sign(priv, headers(), @body, tags: " bh=AAAA;"), opts(p))

    assert {:error, :malformed_signature} =
             Dkim.verify(sign(priv, headers(), @body, tags: " junk;"), opts(p))

    assert {:error, :malformed_signature} =
             Dkim.verify(sign(priv, headers(), @body, bh: "!!not-base64!!"), opts(p))

    assert {:error, :malformed_signature} =
             Dkim.verify(sign(priv, headers(), @body, sig: "@@@"), opts(p))

    assert {:error, :body_hash_mismatch} =
             Dkim.verify(
               sign(priv, headers(), @body, bh: Base.encode64(:crypto.hash(:sha256, "other"))),
               opts(p)
             )

    assert {:error, :body_hash_mismatch} =
             Dkim.verify(sign(priv, headers(), @body, bh: Base.encode64("short")), opts(p))

    assert {:error, :bad_signature} =
             Dkim.verify(
               sign(priv, headers(), @body, sig: Base.encode64(:crypto.strong_rand_bytes(128))),
               opts(p)
             )

    # folded header names/values and a huge header
    big = String.duplicate("a", 500_000)

    refused.(
      sign(priv, [{"From", " a@example.com"}, {"To", " " <> big}], @body, h: ["from", "to"]) <>
        "x"
    )

    assert :ok = Dkim.verify(sign(priv, headers() ++ [{"X-Big", " " <> big}], @body), opts(p))

    refused.(
      "DKIM-Signature: " <>
        String.duplicate("a=1;", 50_000) <> "\r\nFrom: a@example.com\r\n\r\nbody"
    )

    refused.("DKIM-Signature: v=1;\r\n" <> String.duplicate(" fold\r\n", 50_000) <> "\r\n")
    refused.(String.duplicate("DKIM-Signature: v=1\r\n", 5_000) <> "\r\nbody")
  end

  test "Dkim.verify and Inbound.parse are total over random messages", %{p: p} do
    FuzzGen.seed(1802)

    pieces = [
      "DKIM-Signature:",
      " v=1;",
      " a=rsa-sha256;",
      " c=relaxed/relaxed;",
      " d=example.com;",
      " s=sel;",
      " h=from;",
      " bh=",
      " b=",
      "From: a@example.com",
      "\r\n",
      "\n",
      "\r\n\t",
      ";",
      "=",
      ":",
      "\r\n\r\n",
      "<",
      ">",
      "\"",
      "\xFF\xFE"
    ]

    for _ <- 1..@iterations do
      raw =
        if FuzzGen.int(4) == 0 do
          FuzzGen.random_bytes(FuzzGen.int(200))
        else
          Enum.map_join(1..(1 + FuzzGen.int(40)), fn _ -> FuzzGen.pick(pieces) end)
        end

      r = outcome(fn -> Dkim.verify(raw, opts(p)) end)
      assert r == :ok or match?({:error, a} when is_atom(a), r)
      parsed = outcome(fn -> Inbound.parse(raw) end)
      assert match?({:ok, _}, parsed) or match?({:error, _}, parsed)
    end
  end

  test "Inbound.parse is total over random maps and non-binary input" do
    FuzzGen.seed(1803)

    keys = ~w(from to subject text body message_id in_reply_to references headers attachments
              auth_results dkim spf dmarc recipient sender message-id)

    for _ <- 1..@iterations do
      input =
        case FuzzGen.int(5) do
          0 ->
            FuzzGen.term(3, 4)

          1 ->
            FuzzGen.json_safe(FuzzGen.term(3, 4))

          _ ->
            Map.new(for(_ <- 1..FuzzGen.int(8)//1, do: {FuzzGen.pick(keys), FuzzGen.term(2, 3)}))
        end

      parsed = outcome(fn -> Inbound.parse(input) end)
      assert match?({:ok, _}, parsed) or match?({:error, _}, parsed)

      assert outcome(fn -> Dkim.verifier(key_resolver: fn _, _ -> {:error, :x} end).(input) end) in [
               true,
               false
             ]
    end
  end
end
