# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Protocol.AgentCardServedSignatureTest do
  @moduledoc """
  A card served with `sign_with: [jwk: ..., kid: ...]` carries an A2A v1.1
  `AgentCardSignature` entry (`protected`, `signature`) over the exact served
  document. Every HTTP card mount is exercised over a real Bandit listener:
  the well-known card is fetched with a real HTTP client, verified with the
  public key against the served bytes, and refused after one byte is flipped.
  The older `CardSigning` HS256 option keeps working. No mocks.
  """
  use ExUnit.Case, async: true

  alias AshA2A.Protocol.AgentCardSignature, as: Sig
  alias AshA2A.Protocol.CardSigning
  alias AshA2A.Test.EphemeralHttp
  alias AshA2A.Test.PlugFixture.GreeterAgent

  @card_path "/.well-known/agent-card.json"

  @mounts [
    {"Protocol.Plug", AshA2A.Protocol.Plug},
    {"A2ATransport.Plug", AshA2A.A2ATransport.Plug},
    {"Transport.Plug", AshA2A.Transport.Plug},
    {"Transport.HTTPJSON", AshA2A.Transport.HTTPJSON}
  ]

  defp b64(bin), do: Base.url_encode64(bin, padding: false)

  defp ec_keys(kid) do
    {<<4, x::binary-32, y::binary-32>>, d} = :crypto.generate_key(:ecdh, :secp256r1)
    public = %{"kty" => "EC", "crv" => "P-256", "x" => b64(x), "y" => b64(y), "kid" => kid}
    {Map.put(public, "d", b64(d)), public}
  end

  defp ed_keys(kid) do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    public = %{"kty" => "OKP", "crv" => "Ed25519", "x" => b64(pub), "kid" => kid}
    {Map.put(public, "d", b64(priv)), public}
  end

  setup do
    agent = :"served_signature_agent_#{System.unique_integer([:positive])}"
    {:ok, pid} = GreeterAgent.start_link(name: agent)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    %{agent: agent}
  end

  # A real listener serving `mod` with `extra` options; returns the card URL.
  defp serve(mod, agent, extra) do
    # Bandit calls `init/1` itself on the `{plug, options}` pair.
    opts = [agent: agent, base_url: "http://agent.example/a2a"] ++ extra
    EphemeralHttp.start!({mod, opts}).base_url <> @card_path
  end

  defp fetch!(url) do
    resp = Req.get!(url, decode_body: false, retry: false)
    assert resp.status == 200
    resp
  end

  # Flips one bit of the first byte of `needle`'s value inside the served bytes.
  defp flip_byte(body, needle) do
    {at, len} = :binary.match(body, needle)
    <<head::binary-size(^at + ^len - 1), byte, tail::binary>> = body
    head <> <<Bitwise.bxor(byte, 1)>> <> tail
  end

  for {label, mod} <- @mounts do
    test "#{label}: the served card verifies against the served bytes; a flipped byte is refused",
         %{agent: agent} do
      {private, public} = ec_keys("card-2026-11")
      jwks = %{"keys" => [public]}
      url = serve(unquote(mod), agent, sign_with: [jwk: private, kid: "card-2026-11"])

      body = fetch!(url).body
      card = Jason.decode!(body)

      # v1.1 AgentCardSignature shape (a2a.proto: protected, signature, header).
      assert [%{"protected" => protected, "signature" => signature} = entry] = card["signatures"]
      assert Map.keys(entry) -- ["protected", "signature", "header"] == []
      assert {:ok, header_json} = Base.url_decode64(protected, padding: false)
      assert %{"alg" => "ES256", "kid" => "card-2026-11"} = Jason.decode!(header_json)
      assert {:ok, <<_::binary-64>>} = Base.url_decode64(signature, padding: false)

      assert {:ok, ["card-2026-11"]} = Sig.verify(card, jwks, require: :all)

      # One flipped byte anywhere in the signed document is refused.
      for needle <- [card["name"], card["description"], hd(card["skills"])["id"]] do
        tampered = body |> flip_byte(needle) |> Jason.decode!()
        refute tampered == card
        assert {:error, :bad_signature} = Sig.verify(tampered, jwks)
      end

      # ... and so is a flipped byte of the signature itself, or another key.
      forged = put_in(card, ["signatures", Access.at(0), "signature"], flip_b64(signature))
      assert {:error, _} = Sig.verify(forged, jwks)

      {_other_private, other_public} = ec_keys("card-2026-11")
      assert {:error, :bad_signature} = Sig.verify(card, %{"keys" => [other_public]})
      assert {:error, :unknown_kid} = Sig.verify(card, %{"keys" => [%{public | "kid" => "x"}]})

      # Stable bytes and ETag across requests (ECDSA is randomised; the signed
      # body is memoised).
      assert fetch!(url).body == body
    end
  end

  defp flip_b64(<<first, rest::binary>>), do: <<if(first == ?A, do: ?B, else: ?A)>> <> rest

  test "EdDSA keys sign too, and the kid defaults to the JWK's", %{agent: agent} do
    {private, public} = ed_keys("ed-1")
    url = serve(AshA2A.Transport.Plug, agent, sign_with: [jwk: private])

    card = url |> fetch!() |> Map.fetch!(:body) |> Jason.decode!()
    assert {:ok, ["ed-1"]} = Sig.verify(card, %{"keys" => [public]}, allowed_algs: ["EdDSA"])
    assert {:error, _} = Sig.verify(card, %{"keys" => [public]}, allowed_algs: ["ES256"])
  end

  test "the signed card still decodes, with its signatures", %{agent: agent} do
    {private, _public} = ec_keys("k")
    url = serve(AshA2A.Protocol.Plug, agent, sign_with: [jwk: private, kid: "k"])

    assert {:ok, card} =
             url
             |> fetch!()
             |> Map.fetch!(:body)
             |> Jason.decode!()
             |> AshA2A.Protocol.JSON.decode_agent_card()

    assert [%{"protected" => _, "signature" => _}] = card.signatures
  end

  test "a key that cannot sign is an error, never an unsigned card", %{agent: agent} do
    {_private, public_only} = ec_keys("k")

    opts =
      AshA2A.Transport.Plug.init(
        agent: agent,
        base_url: "http://x/a2a",
        sign_with: [jwk: public_only]
      )

    assert_raise ArgumentError, ~r/cannot sign the agent card/, fn ->
      :get |> Plug.Test.conn(@card_path) |> AshA2A.Transport.Plug.call(opts)
    end
  end

  test "the older HS256 CardSigning option is unchanged", %{agent: agent} do
    key = "served-signature-shared-secret-0123456789"
    url = serve(AshA2A.Protocol.Plug, agent, sign_with: [key: key, alg: :HS256, kid: "hs"])

    card = url |> fetch!() |> Map.fetch!(:body) |> Jason.decode!()

    assert [%{"protected" => _, "signature" => _, "header" => %{"alg" => "HS256"}}] =
             card["signatures"]

    assert CardSigning.verify(card, key) == :ok
  end

  test "without :sign_with no mount serves a signatures member", %{agent: agent} do
    for {label, mod} <- @mounts do
      card = mod |> serve(agent, []) |> fetch!() |> Map.fetch!(:body) |> Jason.decode!()
      refute Map.has_key?(card, "signatures"), label
    end
  end
end
