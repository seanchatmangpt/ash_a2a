# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.CardDslV11FieldsTest.Resource do
  @moduledoc false
  use Ash.Resource,
    domain: AshA2A.CardDslV11FieldsTest.HomeDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
  end

  actions do
    defaults([:read])
  end

  a2a do
    skill(:echo, :read)
  end
end

defmodule AshA2A.CardDslV11FieldsTest.HomeDomain do
  @moduledoc false
  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.CardDslV11FieldsTest.Resource)
  end
end

defmodule AshA2A.CardDslV11FieldsTest.Agent do
  @moduledoc false
  use AshA2A.Agent,
    resource_or_domain: AshA2A.CardDslV11FieldsTest.Resource,
    name: "y6_card_dsl_agent",
    public_skills: [:echo]
end

defmodule AshA2A.CardDslV11FieldsTest.OAuthDomain do
  @moduledoc false
  use Ash.Domain, extensions: [AshA2A, AshA2A.Domain], validate_config_inclusion?: false

  resources do
    resource(AshA2A.CardDslV11FieldsTest.Resource)
  end

  agent do
    name "y6-card-dsl"
    description "Y6 DSL-declared v1.1 card surface"
  end

  security do
    security_scheme(:oauth, :oauth2,
      oauth_flows: %{
        "deviceCode" => %{
          "deviceAuthorizationUrl" => "https://auth.example.com/device",
          "tokenUrl" => "https://auth.example.com/token",
          "scopes" => %{"read" => "Read access"}
        }
      }
    )

    security_scheme(:oauth_pkce, :oauth2,
      oauth_flows: %{
        "authorizationCode" => %{
          "authorizationUrl" => "https://auth.example.com/authorize",
          "tokenUrl" => "https://auth.example.com/token",
          "scopes" => %{"read" => "Read access"},
          "pkceRequired" => true
        }
      }
    )

    requirements ["oauth"]
  end

  transport do
    base_url "https://y6.example.com"

    extension("https://example.com/ext/y6/v1",
      description: "Y6 extension",
      required: true,
      params: %{"mode" => "strict"}
    )

    mount agent: AshA2A.CardDslV11FieldsTest.Agent,
          path: "/rpc",
          binding: :jsonrpc

    mount agent: AshA2A.CardDslV11FieldsTest.Agent,
          path: "/rest",
          binding: :rest,
          tenant: "tenant-y6",
          protocol_version: "1.1"
  end
end

defmodule AshA2A.CardDslV11FieldsTest do
  use ExUnit.Case, async: true

  alias AshA2A.Protocol.CardSigning
  alias AshA2A.Protocol.JSON, as: Codec

  @key "y6-shared-secret-0123456789abcdef0"

  defp card, do: AshA2A.Info.agent_card(AshA2A.CardDslV11FieldsTest.OAuthDomain)
  defp wire(card), do: Codec.encode_agent_card(card, url: card.url)

  test "mount binding :rest maps to protocolBinding HTTP+JSON" do
    assert AshA2A.Domain.Mount.protocol_binding(:rest) == "HTTP+JSON"
    assert AshA2A.Domain.Mount.protocol_binding(:jsonrpc) == "JSONRPC"

    bindings = Enum.map(card().supported_interfaces, & &1.protocol_binding)
    assert bindings == ["JSONRPC", "HTTP+JSON"]
  end

  test "interface tenant and protocolVersion are emitted and decoded" do
    rest =
      wire(card())["supportedInterfaces"] |> Enum.find(&(&1["protocolBinding"] == "HTTP+JSON"))

    assert rest["tenant"] == "tenant-y6"
    assert rest["protocolVersion"] == "1.1"

    {:ok, decoded} = Codec.decode_agent_card(wire(card()))
    rest = Enum.find(decoded.supported_interfaces, &(&1.protocol_binding == "HTTP+JSON"))
    assert rest.tenant == "tenant-y6"
    assert rest.protocol_version == "1.1"
  end

  test "DSL extension and deviceCode+pkce flows survive build, encode and decode" do
    wire = wire(card())

    assert [%{"uri" => "https://example.com/ext/y6/v1", "required" => true} = ext] =
             wire["capabilities"]["extensions"]

    assert ext["params"] == %{"mode" => "strict"}

    schemes = wire["securitySchemes"]

    assert get_in(schemes, [
             "oauth",
             "oauth2SecurityScheme",
             "flows",
             "deviceCode",
             "deviceAuthorizationUrl"
           ]) ==
             "https://auth.example.com/device"

    assert get_in(schemes, [
             "oauth_pkce",
             "oauth2SecurityScheme",
             "flows",
             "authorizationCode",
             "pkceRequired"
           ]) ==
             true

    assert {:ok, decoded} = Codec.decode_agent_card(wire)

    assert [%{uri: "https://example.com/ext/y6/v1", required: true}] =
             decoded.capabilities.extensions

    assert Map.has_key?(decoded.security_schemes, "oauth")
    assert Map.has_key?(decoded.security_schemes, "oauth_pkce")
  end

  test "signed card carries the declared extension, flows, tenant and version" do
    signed = CardSigning.sign(card(), @key, kid: "y6-k1")
    wire = wire(signed)

    assert [%{"protected" => _, "signature" => _}] = wire["signatures"]
    assert CardSigning.verify(wire, @key) == :ok
    assert [%{"uri" => "https://example.com/ext/y6/v1"}] = wire["capabilities"]["extensions"]

    assert get_in(wire, [
             "securitySchemes",
             "oauth",
             "oauth2SecurityScheme",
             "flows",
             "deviceCode"
           ])

    assert Enum.any?(wire["supportedInterfaces"], &(&1["tenant"] == "tenant-y6"))

    tampered = put_in(wire, ["capabilities", "extensions"], [])
    assert {:error, _} = CardSigning.verify(tampered, @key)
  end

  test "closed protocolBinding set rejects an unknown binding on decode" do
    wire = wire(card())

    bad =
      update_in(wire["supportedInterfaces"], fn [first | rest] ->
        [Map.put(first, "protocolBinding", "CARRIER-PIGEON") | rest]
      end)

    assert {:error, {:invalid_field, "supportedInterfaces.protocolBinding"}} =
             Codec.decode_agent_card(bad)
  end

  describe "oauth_flows validation" do
    test "validate_oauth_flows accepts deviceCode and pkceRequired" do
      assert {:ok, _} =
               AshA2A.Domain.validate_oauth_flows(%{
                 "deviceCode" => %{
                   "deviceAuthorizationUrl" => "https://a/d",
                   "tokenUrl" => "https://a/t",
                   "scopes" => %{}
                 }
               })

      assert {:ok, _} =
               AshA2A.Domain.validate_oauth_flows(%{
                 "authorizationCode" => %{
                   "authorizationUrl" => "https://a/a",
                   "tokenUrl" => "https://a/t",
                   "scopes" => %{},
                   "pkceRequired" => true
                 }
               })
    end

    test "bad shapes are refused" do
      assert {:error, _} = AshA2A.Domain.validate_oauth_flows(%{"bogus" => %{}})
      assert {:error, _} = AshA2A.Domain.validate_oauth_flows(%{})
      assert {:error, _} = AshA2A.Domain.validate_oauth_flows("nope")
      # deviceCode missing REQUIRED members
      assert {:error, _} =
               AshA2A.Domain.validate_oauth_flows(%{
                 "deviceCode" => %{"tokenUrl" => "https://a/t"}
               })
    end

    test "a domain declaring a bad flow fails at compile time" do
      assert_raise Spark.Error.DslError, fn ->
        Code.compile_string("""
        defmodule AshA2A.CardDslV11FieldsTest.BadFlowDomain do
          use Ash.Domain, extensions: [AshA2A.Domain]

          security do
            security_scheme :oauth, :oauth2,
              oauth_flows: %{"deviceCode" => %{"tokenUrl" => "https://a/t"}}
          end
        end
        """)
      end
    end
  end
end
