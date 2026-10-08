# Endpoint-level court for the Plug JWKS publication surface (lane G4):
# a real AshA2A.Protocol.Plug dispatch (Plug.Test, no mocks) with
# :jwks_keys configured — GET .well-known/jwks.json serves exactly the
# public members of the keys that signed the card, resolvable by the
# PROTECTED-header kid.

defmodule AshA2A.Protocol.PlugJwksTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias AshA2A.Protocol.{AgentCard, CardSigning, Plug}

  defp card do
    %AgentCard{
      name: "jwks-endpoint-court",
      description: "plug JWKS endpoint court",
      url: "http://127.0.0.1:1",
      version: "1.0.0",
      skills: [%{id: "echo", name: "Echo", description: "echo", tags: ["tck"]}]
    }
  end

  defp opts do
    Plug.init(
      agent: self(),
      base_url: "http://127.0.0.1:1",
      jwks_keys: [
        {"ec-active", :public_key.generate_key({:namedCurve, :secp256r1})},
        {"rsa-active", :public_key.generate_key({:rsa, 2048, 65537})}
      ]
    )
  end

  test "GET .well-known/jwks.json serves both published kids" do
    {opts, ec_key, rsa_key} = keys_fixture()

    conn =
      :get
      |> conn("/.well-known/jwks.json")
      |> Plug.call(opts)

    assert conn.status == 200
    assert {:ok, %{"keys" => keys}} = Jason.decode(conn.resp_body)

    kids = keys |> Enum.map(& &1["kid"]) |> Enum.sort()
    assert kids == ["ec-active", "rsa-active"]
    assert Enum.all?(keys, &(&1["use"] == "sig"))

    assert %{"kty" => "EC", "crv" => "P-256"} =
             Enum.find(keys, &(&1["kid"] == "ec-active"))

    assert %{"kty" => "RSA", "n" => n} = Enum.find(keys, &(&1["kid"] == "rsa-active"))
    # 2048-bit modulus = 256 bytes.
    assert byte_size(Base.url_decode64!(n, padding: false)) == 256
  end

  test "JWKS served by the endpoint verifies the card signature end to end" do
    {opts, ec_key, _rsa_key} = keys_fixture()
    signed = CardSigning.sign(card(), ec_key, alg: :ES256, kid: "ec-active")

    conn =
      :get
      |> conn("/.well-known/jwks.json")
      |> Plug.call(opts)

    assert conn.status == 200
    assert {:ok, served} = Jason.decode(conn.resp_body)

    # The verifier resolves the key ONLY through the endpoint's document.
    assert CardSigning.verify(signed, served) == :ok
  end

  test "unconfigured JWKS path 404s (no vacuous empty key set)" do
    conn =
      :get
      |> conn("/.well-known/jwks.json")
      |> Plug.call(Plug.init(agent: self(), base_url: "http://127.0.0.1:1"))

    assert conn.status == 404
  end

  defp keys_fixture do
    ec_key = :public_key.generate_key({:namedCurve, :secp256r1})
    rsa_key = :public_key.generate_key({:rsa, 2048, 65537})

    opts =
      Plug.init(
        agent: self(),
        base_url: "http://127.0.0.1:1",
        jwks_keys: [{"ec-active", ec_key}, {"rsa-active", rsa_key}]
      )

    {opts, ec_key, rsa_key}
  end
end
