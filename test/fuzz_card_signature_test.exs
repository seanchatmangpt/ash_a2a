# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.FuzzCardSignatureTest do
  # Seeded fuzz of the RFC 8785 canonicalizer and of detached-JWS verification of
  # agent cards (`AgentCardSignature.verify/3`).
  use ExUnit.Case, async: true

  alias AshA2A.FuzzGen
  alias AshA2A.Protocol.AgentCardSignature, as: Sig
  alias AshA2A.Wire.Jcs

  @iterations FuzzGen.iterations(400)

  setup_all do
    {pub, priv} = :crypto.generate_key(:ecdh, :secp256r1)
    <<4, x::binary-size(32), y::binary-size(32)>> = pub
    b = &Base.url_encode64(&1, padding: false)

    es = %{
      "kty" => "EC",
      "crv" => "P-256",
      "kid" => "k1",
      "x" => b.(x),
      "y" => b.(y),
      "d" => b.(priv)
    }

    {epub, epriv} = :crypto.generate_key(:eddsa, :ed25519)
    ed = %{"kty" => "OKP", "crv" => "Ed25519", "kid" => "k2", "x" => b.(epub), "d" => b.(epriv)}
    pub_only = fn jwk -> Map.delete(jwk, "d") end
    jwks = %{"keys" => [pub_only.(es), pub_only.(ed)]}
    {:ok, es: es, ed: ed, jwks: jwks}
  end

  defp b64(bin), do: Base.url_encode64(bin, padding: false)

  defp card, do: Map.delete(FuzzGen.full_card(), "signatures")

  defp signed(key, kid) do
    c = card()
    {:ok, entry} = Sig.sign(c, key, kid: kid)
    {c, entry, Sig.attach(c, [entry])}
  end

  defp safe_verify(card, keys, opts \\ []) do
    case FuzzGen.run_with_deadline(fn -> Sig.verify(card, keys, opts) end) do
      {:ok, {:ok, kids}} when is_list(kids) -> {:ok, kids}
      {:ok, {:error, _} = e} -> e
      other -> flunk("verify raised or hung: #{inspect(other, limit: 8)}")
    end
  end

  # ---- JCS -------------------------------------------------------------------------

  defp json_term(depth) do
    FuzzGen.json_safe(FuzzGen.term(depth, 4))
    |> scrub()
  end

  defp scrub(%{} = m), do: Map.new(m, fn {k, v} -> {k, scrub(v)} end)
  defp scrub(l) when is_list(l), do: Enum.map(l, &scrub/1)
  defp scrub(n) when is_float(n), do: FuzzGen.pick([1.5, -0.0, 1.0e21, 1.0e-7, 123.456])
  defp scrub(n) when is_integer(n), do: rem(n, 9_007_199_254_740_991)
  defp scrub(other), do: other

  test "JCS: RFC 8785 vectors" do
    assert {:ok, ~s({"a":1,"b":2})} = Jcs.encode(%{"b" => 2, "a" => 1})
    assert {:ok, ~s({"\\u20ac":1,"\\r":2})} != Jcs.encode(%{"\r" => 2, "€" => 1})
    assert {:ok, "[]"} = Jcs.encode([])
    assert {:ok, "1e+21"} = Jcs.encode(1.0e21)
    assert {:ok, "1e-7"} = Jcs.encode(1.0e-7)
    assert {:ok, "0"} = Jcs.encode(-0.0)
    assert {:ok, "1.5"} = Jcs.encode(1.5)
    # keys sort by UTF-16 code units: U+10000 (surrogates D800..) sorts before U+FFFF
    assert {:ok, out} = Jcs.encode(%{<<0xEF, 0xBF, 0xBF>> => 1, <<0xF0, 0x90, 0x80, 0x80>> => 2})
    assert String.starts_with?(out, "{\"" <> <<0xF0, 0x90, 0x80, 0x80>>)
  end

  test "JCS: encode is total, idempotent and key-order independent on random JSON" do
    FuzzGen.seed(1901)

    for i <- 1..@iterations do
      term = json_term(4)

      assert {:ok, {:ok, bytes}} =
               {:ok, FuzzGen.run_with_deadline(fn -> Jcs.encode(term) end) |> unwrap()},
             "iteration #{i}"

      assert String.valid?(bytes)
      assert {:ok, decoded} = Jason.decode(bytes)
      assert {:ok, ^bytes} = Jcs.encode(decoded), "not idempotent: #{bytes}"

      refute bytes =~ ~r/[\n\t ]+(?=(?:[^"]*"[^"]*")*[^"]*$)/,
             "whitespace outside strings: #{bytes}"
    end
  end

  defp unwrap({:ok, result}), do: result
  defp unwrap(other), do: flunk("raised or hung: #{inspect(other, limit: 6)}")

  # ---- detached JWS ----------------------------------------------------------------

  test "valid ES256 and EdDSA entries verify; unchanged cards verify only with their key", ctx do
    {_, _, es_card} = signed(ctx.es, "k1")
    {_, _, ed_card} = signed(ctx.ed, "k2")
    assert {:ok, ["k1"]} = safe_verify(es_card, ctx.jwks)
    assert {:ok, ["k2"]} = safe_verify(ed_card, ctx.jwks)
    assert {:error, _} = safe_verify(Map.put(es_card, "name", "tampered"), ctx.jwks)
  end

  defp header_json(overrides) do
    base = %{"alg" => "ES256", "kid" => "k1", "typ" => "JOSE"}

    merged =
      Enum.reduce(overrides, base, fn
        {k, :drop}, acc -> Map.delete(acc, k)
        {k, v}, acc -> Map.put(acc, k, v)
      end)

    Jason.encode!(merged)
  end

  defp resign(key, card, protected_b64) do
    {:ok, payload} = Jcs.encode(card)
    input = protected_b64 <> "." <> b64(payload)

    der =
      :crypto.sign(:ecdsa, :sha256, input, [
        Base.url_decode64!(key["d"], padding: false),
        :secp256r1
      ])

    {:"ECDSA-Sig-Value", r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", der)
    b64(<<r::unsigned-big-size(256), s::unsigned-big-size(256)>>)
  end

  test "alg confusion, crit, b64:false and odd protected headers are all refused", ctx do
    c = card()

    cases = [
      %{"alg" => "none"},
      %{"alg" => "HS256"},
      %{"alg" => "EdDSA"},
      %{"alg" => "es256"},
      %{"alg" => nil},
      %{"alg" => ["ES256"]},
      %{"alg" => :drop},
      %{"kid" => :drop},
      %{"kid" => ""},
      %{"kid" => "nope"},
      %{"kid" => 1},
      %{"kid" => ["k1"]},
      %{"crit" => ["b64"], "b64" => false},
      %{"crit" => []},
      %{"crit" => "b64"},
      %{"crit" => ["exp"], "exp" => 1}
    ]

    for overrides <- cases do
      protected = b64(header_json(overrides))
      sig = resign(ctx.es, c, protected)
      card = Sig.attach(c, [%{"protected" => protected, "signature" => sig}])
      assert {:error, _} = safe_verify(card, ctx.jwks), "accepted #{inspect(overrides)}"
    end

    # `b64: false` without `crit` is an unknown header member: it must not change how the
    # payload is read, so the entry verifies exactly like a plain one (and never raises).
    protected = b64(header_json(%{"b64" => false}))
    sig = resign(ctx.es, c, protected)
    card = Sig.attach(c, [%{"protected" => protected, "signature" => sig}])
    assert {:ok, ["k1"]} = safe_verify(card, ctx.jwks)
  end

  test "extra segments, non-UTF-8, padding and non-string members are refused", ctx do
    {c, entry, _} = signed(ctx.es, "k1")
    %{"protected" => p, "signature" => s} = entry

    variants = [
      %{"protected" => p <> "." <> p, "signature" => s},
      %{"protected" => p, "signature" => s <> "." <> s},
      %{"protected" => p <> "=", "signature" => s},
      %{"protected" => p, "signature" => s <> "="},
      %{"protected" => b64(<<255, 254, 253>>), "signature" => s},
      %{"protected" => b64("{\"alg\":\"ES256\",\"kid\":\"k1\""), "signature" => s},
      %{"protected" => b64("[]"), "signature" => s},
      %{"protected" => b64("null"), "signature" => s},
      %{"protected" => "", "signature" => s},
      %{"protected" => p, "signature" => ""},
      %{"protected" => p, "signature" => b64(<<0>>)},
      %{"protected" => p, "signature" => b64(:binary.copy(<<0>>, 64))},
      %{"protected" => p, "signature" => b64(:binary.copy(<<255>>, 64))},
      %{"protected" => 1, "signature" => s},
      %{"protected" => p},
      %{"signature" => s},
      %{},
      "string",
      nil,
      5,
      [entry]
    ]

    for v <- variants do
      assert {:error, _} = safe_verify(Map.put(c, "signatures", [v]), ctx.jwks), inspect(v)
    end

    for sigs <- [nil, "x", 5, %{}, [], [nil], [[]]] do
      assert {:error, _} = safe_verify(Map.put(c, "signatures", sigs), ctx.jwks)
    end
  end

  test "random protected headers and signatures never raise and are never accepted", ctx do
    FuzzGen.seed(1902)
    c = card()

    for i <- 1..@iterations do
      protected =
        case FuzzGen.int(4) do
          0 ->
            b64(Jason.encode!(json_term(3)))

          1 ->
            b64(FuzzGen.random_bytes(FuzzGen.int(64)))

          2 ->
            FuzzGen.random_bytes(FuzzGen.int(40))

          3 ->
            b64(
              header_json(%{
                "alg" => FuzzGen.pick(["ES256", "EdDSA", "none", "RS256", 1]),
                "kid" => FuzzGen.pick(["k1", "k2", "x"]),
                "crit" => FuzzGen.pick([:drop, [], ["b64"], 5])
              })
            )
        end

      sig =
        FuzzGen.pick([
          b64(FuzzGen.random_bytes(64)),
          b64(FuzzGen.random_bytes(FuzzGen.int(70))),
          FuzzGen.random_bytes(8)
        ])

      keys =
        FuzzGen.pick([
          ctx.jwks,
          fn _ -> ctx.es end,
          fn _ -> nil end,
          %{"keys" => [ctx.es, ctx.es]},
          %{"keys" => 5},
          nil,
          %{}
        ])

      card = Sig.attach(c, [%{"protected" => protected, "signature" => sig}])

      assert {:error, _} = safe_verify(card, keys, require: FuzzGen.pick([:any, :all])),
             "iteration #{i}"
    end
  end

  test "flipping any byte of a valid entry is refused or still names the same kid", ctx do
    for {key, kid} <- [{ctx.es, "k1"}, {ctx.ed, "k2"}] do
      {c, entry, _} = signed(key, kid)

      for field <- ["protected", "signature"],
          i <- 0..(byte_size(entry[field]) - 1),
          mask <- [1, 0x20, 0x80] do
        v = entry[field]
        <<pre::binary-size(^i), byte, post::binary>> = v
        bad = Map.put(entry, field, <<pre::binary, Bitwise.bxor(byte, mask), post::binary>>)

        case safe_verify(Map.put(c, "signatures", [bad]), ctx.jwks) do
          {:error, _} -> :ok
          {:ok, [^kid]} -> assert field == "signature", "mutated protected header still verified"
        end
      end
    end
  end

  test "mutated cards (types, unicode, extra members) never raise", ctx do
    FuzzGen.seed(1903)
    {c, _entry, valid} = signed(ctx.es, "k1")

    for _ <- 1..@iterations do
      mutated =
        valid
        |> FuzzGen.corrupt()
        |> Map.put("signatures", valid["signatures"])

      result = safe_verify(mutated, ctx.jwks)

      if result != {:error, :bad_signature} and match?({:ok, _}, result) do
        assert Map.delete(mutated, "signatures") == c or
                 Jcs.encode(Map.delete(mutated, "signatures")) == Jcs.encode(c)
      end
    end

    # non-UTF-8 and non-JSON terms in the card are refused, not raised
    for bad <- [<<255, 254>>, :atom, {1, 2}, self(), %{1 => 2}, %{"a" => <<255>>}] do
      assert {:error, _} = safe_verify(Map.put(valid, "x", bad), ctx.jwks)
    end
  end

  test "regression: non-UTF-8 strings and integers outside +-(2^53-1) are not canonicalizable",
       ctx do
    {_, _, valid} = signed(ctx.es, "k1")

    for bad <- [<<255, 254>>, 9_007_199_254_740_992, -9_007_199_254_740_992, FuzzGen.huge_int()] do
      assert {:error, :non_canonicalizable_card} =
               Sig.verify(Map.put(valid, "x", bad), ctx.jwks)

      assert {:error, :non_canonicalizable_card} =
               Sig.verify(Map.put(valid, <<255>>, bad), ctx.jwks)

      assert {:error, :non_canonicalizable_card} =
               Sig.sign(Map.put(card(), "x", bad), ctx.es, kid: "k1")
    end

    assert {:ok, _} = Sig.sign(Map.put(card(), "x", 9_007_199_254_740_991), ctx.es, kid: "k1")
  end
end
