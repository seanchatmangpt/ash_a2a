defmodule AshA2A.W10ExtendedCardResignTest do
  use ExUnit.Case, async: true

  alias AshA2A.A2ATransport.ExtendedCard
  alias AshA2A.Protocol.{CardSigner, CardSigning, JSON}

  @key :crypto.strong_rand_bytes(32)

  defp public_map(signatures_key \\ nil) do
    card = AshA2A.Info.agent_card(AshA2A.Test.Fixture.Echo)
    card = if signatures_key, do: CardSigning.sign(card, signatures_key), else: card

    card
    |> JSON.encode_agent_card(url: "http://localhost/a2a")
    |> Jason.encode!()
    |> Jason.decode!()
  end

  defp verifies?(map, key) do
    {:ok, card} = JSON.decode_agent_card(map)
    CardSigning.verify(card, key)
  end

  defp add_skill(map) do
    skill = %{"id" => "extra", "name" => "Extra", "description" => "added", "tags" => []}
    Map.update!(map, "skills", &(&1 ++ [skill]))
  end

  test "CardSigner.sign/2 output verifies and strip_signatures removes it" do
    signed = CardSigner.sign(public_map(), key: @key, kid: "k1")
    assert [_] = signed["signatures"]
    assert :ok = verifies?(signed, @key)
    refute Map.has_key?(CardSigner.strip_signatures(signed), "signatures")
  end

  test "verifier_for_jwk/1 verifies an ES256 card from a published JWK" do
    ec = :public_key.generate_key({:namedCurve, :secp256r1})
    [jwk] = CardSigning.jwks([{"e1", ec}])["keys"]
    signed = CardSigner.sign(public_map(), key: ec, alg: :ES256, kid: "e1")
    {:ok, card} = JSON.decode_agent_card(signed)
    assert :ok = CardSigning.verifier_for_jwk(jwk).(card)
    assert :ok = CardSigning.verifier_for_jwk(%{"keys" => [jwk]}).(card)
  end

  test "modified extended card never carries a stale signature" do
    stale = public_map(@key) |> add_skill()
    assert {:error, _} = verifies?(stale, @key)

    opts = %{a2a: %{agent_card_opts: []}}
    out = ExtendedCard.resign(stale, opts)
    refute Map.has_key?(out, "signatures")
  end

  test "modified extended card is re-signed when a signing key is configured" do
    stale = public_map(@key) |> add_skill()
    opts = %{a2a: %{agent_card_opts: [sign_with: [key: @key, kid: "k1"]]}}
    out = ExtendedCard.resign(stale, opts)
    assert [_] = out["signatures"]
    assert :ok = verifies?(out, @key)
  end
end
