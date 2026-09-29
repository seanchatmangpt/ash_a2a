defmodule Actuator.DecodeTest do
  @moduledoc "Total-schema decoding of effects and certificates (no shell/URL/path/MFA, no smuggled keys)."
  use ExUnit.Case, async: true
  alias Actuator.{Certificate, Effect, Kit}

  defp enc(m), do: Jcs.encode(m)

  test "a canonical effect decodes to a typed struct" do
    assert {:ok, %Effect{effect_type: "ledger_append", params: %{"entry" => "hello"}}} =
             Effect.decode(enc(Kit.effect_map()))
  end

  test "refuses unknown fields, missing fields, unknown effect types, bad params" do
    assert {:error, :malformed_effect} =
             Effect.decode(enc(Map.put(Kit.effect_map(), "cmd", "rm -rf /")))

    assert {:error, :malformed_effect} =
             Effect.decode(enc(Map.delete(Kit.effect_map(), "subject")))

    assert {:error, :unknown_effect_type} =
             Effect.decode(enc(Kit.effect_map(%{"effect_type" => "shell"})))

    assert {:error, :malformed_effect} =
             Effect.decode(
               enc(Kit.effect_map(%{"params" => %{"entry" => "x", "path" => "/etc/passwd"}}))
             )

    assert {:error, :malformed_effect} =
             Effect.decode(enc(Kit.effect_map(%{"params" => %{"entry" => 5}})))

    noop = Kit.effect_map(%{"effect_type" => "noop_probe", "params" => %{"url" => "http://x"}})
    assert {:error, :malformed_effect} = Effect.decode(enc(noop))
  end

  test "refuses floats, non-canonical encodings, duplicate keys and oversize input" do
    canon = enc(Kit.effect_map())
    assert {:error, :non_canonical_effect} = Effect.decode(" " <> canon)

    assert {:error, :non_canonical_effect} =
             Effect.decode(Jason.encode!(Kit.effect_map(), pretty: true))

    dup = String.replace(canon, "\"v\":1", "\"v\":1,\"v\":2")
    assert {:error, :non_canonical_effect} = Effect.decode(dup)
    float = String.replace(canon, "\"policy_epoch\":3", "\"policy_epoch\":3.5")
    assert {:error, _} = Effect.decode(float)
    assert {:error, :malformed_effect} = Effect.decode(String.duplicate("a", 20_000))
    assert {:error, :malformed_effect} = Effect.decode(:not_binary)
  end

  test "a certificate carrying a public key or extra field is malformed (keys come from the pinned registry only)" do
    built = Kit.build()
    good = Jason.decode!(built.cert_bytes)
    assert {:ok, %Certificate{}} = Certificate.decode(built.cert_bytes)

    for {k, v} <- [{"public_key", "AAAA"}, {"jwk", %{}}, {"standing", "valid"}] do
      assert {:error, :malformed_certificate} = Certificate.decode(enc(Map.put(good, k, v)))
    end

    [s] = good["signatures"]
    smuggled = Map.put(good, "signatures", [Map.put(s, "public_key", "AAAA")])
    assert {:error, :malformed_certificate} = Certificate.decode(enc(smuggled))

    assert {:error, :malformed_certificate} =
             Certificate.decode(enc(Map.put(good, "signatures", [])))

    padded = Map.put(good, "signatures", [Map.put(s, "signature", s["signature"] <> "=")])
    assert {:error, :malformed_certificate} = Certificate.decode(enc(padded))
  end

  test "a signature whose kid is not in the pinned registry is refused even if the key is valid" do
    other = Kit.build()
    built = Kit.build(ctx: [registry: other.ctx.registry])
    req = Kit.request(built)
    assert {:error, 10, :unknown_kid} = Actuator.Fence.run(built.ctx, req, Kit.view())
  end
end
