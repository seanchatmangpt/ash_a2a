# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Protocol.AgentCardSignatureTest do
  use ExUnit.Case, async: true

  alias AshA2A.Protocol.AgentCardSignature, as: Sig

  defp b64(b), do: Base.url_encode64(b, padding: false)

  defp ec_keys(kid) do
    {pub, priv} = :crypto.generate_key(:ecdh, :secp256r1)
    <<4, x::binary-32, y::binary-32>> = pub
    private = %{"kty" => "EC", "crv" => "P-256", "x" => b64(x), "y" => b64(y), "d" => b64(priv)}
    {private, Map.take(private, ["kty", "crv", "x", "y"]) |> Map.put("kid", kid)}
  end

  defp ed_keys(kid) do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    private = %{"kty" => "OKP", "crv" => "Ed25519", "x" => b64(pub), "d" => b64(priv)}
    {private, Map.take(private, ["kty", "crv", "x"]) |> Map.put("kid", kid)}
  end

  def ec_keys_pub(kid), do: ec_keys(kid)
  def ed_keys_pub(kid), do: ed_keys(kid)

  defp card,
    do: %{
      "name" => "Agent",
      "description" => "d",
      "skills" => [%{"id" => "a", "name" => "A"}],
      "version" => "1"
    }

  defp signed(key, opts) do
    {:ok, entry} = Sig.sign(card(), key, opts)
    Sig.attach(card(), [entry])
  end

  for {name, gen} <- [es256: :ec_keys_pub, eddsa: :ed_keys_pub] do
    test "#{name} round trip, key order independent, tamper refused" do
      {priv, pub} = apply(__MODULE__, unquote(gen), ["k1"])
      jwks = %{"keys" => [pub]}
      c = signed(priv, kid: "k1")
      assert {:ok, ["k1"]} = Sig.verify(c, jwks)

      assert {:ok, ["k1"]} =
               Sig.verify(c, fn
                 "k1" -> pub
                 _ -> nil
               end)

      tampered = Map.put(c, "name", "Evil")
      assert {:error, :bad_signature} = Sig.verify(tampered, jwks)
      assert {:error, :unknown_kid} = Sig.verify(c, %{"keys" => []})
    end
  end

  test "refuses missing kid on sign and verify" do
    {priv, pub} = ec_keys("k1")
    assert {:error, :missing_kid} = Sig.sign(card(), priv, [])

    # forge an entry without kid
    protected = b64(~s({"alg":"ES256"}))

    c =
      Sig.attach(card(), [
        %{"protected" => protected, "signature" => b64(:crypto.strong_rand_bytes(64))}
      ])

    assert {:error, :missing_kid} = Sig.verify(c, %{"keys" => [pub]})
  end

  test "refuses alg none and unlisted algs" do
    {priv, pub} = ec_keys("k1")
    assert {:error, {:alg_not_allowed, "none"}} = Sig.sign(card(), priv, kid: "k1", alg: "none")

    protected = b64(~s({"alg":"none","kid":"k1"}))
    c = Sig.attach(card(), [%{"protected" => protected, "signature" => ""}])
    assert {:error, {:alg_not_allowed, "none"}} = Sig.verify(c, %{"keys" => [pub]})

    hs = b64(~s({"alg":"HS256","kid":"k1"}))
    c2 = Sig.attach(card(), [%{"protected" => hs, "signature" => b64("x")}])
    assert {:error, {:alg_not_allowed, "HS256"}} = Sig.verify(c2, %{"keys" => [pub]})
  end

  test "alg/key confusion refused" do
    {ec_priv, ec_pub} = ec_keys("k1")
    {ed_priv, _ed_pub} = ed_keys("k2")

    assert {:error, :alg_key_mismatch} = Sig.sign(card(), ec_priv, kid: "k1", alg: "EdDSA")
    assert {:error, :alg_key_mismatch} = Sig.sign(card(), ed_priv, kid: "k2", alg: "ES256")

    # entry signed with ES256 but header claims EdDSA against the EC key
    {:ok, entry} = Sig.sign(card(), ec_priv, kid: "k1")
    forged = %{entry | "protected" => b64(~s({"alg":"EdDSA","kid":"k1"}))}
    c = Sig.attach(card(), [forged])
    assert {:error, :alg_key_mismatch} = Sig.verify(c, %{"keys" => [ec_pub]})

    # JWK pinned to a different alg
    pinned = Map.put(ec_pub, "alg", "EdDSA")

    assert {:error, :alg_key_mismatch} =
             Sig.verify(signed(ec_priv, kid: "k1"), %{"keys" => [pinned]})
  end

  test "wrong key and truncated signature refused" do
    {priv, _} = ec_keys("k1")
    {_, other_pub} = ec_keys("k1")

    assert {:error, :bad_signature} =
             Sig.verify(signed(priv, kid: "k1"), %{"keys" => [other_pub]})

    {:ok, entry} = Sig.sign(card(), priv, kid: "k1")
    {_, pub} = ec_keys("k1")
    c = Sig.attach(card(), [%{entry | "signature" => b64("short")}])
    assert {:error, :bad_signature} = Sig.verify(c, %{"keys" => [pub]})
  end

  test "unsigned card and non-canonical keys refused" do
    {priv, pub} = ec_keys("k1")
    assert {:error, :no_signatures} = Sig.verify(card(), %{"keys" => [pub]})

    dup = Map.put(card(), :name, "Agent")
    assert {:error, :non_canonicalizable_card} = Sig.sign(dup, priv, kid: "k1")
  end

  test "signatures member is excluded from the payload; attach keeps existing entries" do
    {priv, pub} = ec_keys("k1")
    {priv2, pub2} = ed_keys("k2")
    c = signed(priv, kid: "k1")
    {:ok, e2} = Sig.sign(c, priv2, kid: "k2")
    c = Sig.attach(c, [e2])
    assert length(c["signatures"]) == 2
    assert {:ok, kids} = Sig.verify(c, %{"keys" => [pub, pub2]}, require: :all)
    assert Enum.sort(kids) == ["k1", "k2"]
  end
end
