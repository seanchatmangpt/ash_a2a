defmodule AshA2A.DslCardSurface.Res do
  @moduledoc false

  use Ash.Resource,
    domain: AshA2A.DslCardSurface.Home,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  alias AshA2A.Protocol.Part

  attributes do
    uuid_primary_key(:id)
  end

  actions do
    defaults([:read])

    action :needs_more, :term do
      public?(true)

      run(fn _input, _ctx ->
        {:ok, {:input_required, [Part.Text.new("need more")]}}
      end)
    end

    action :needs_auth, :term do
      public?(true)

      run(fn _input, _ctx ->
        {:ok, {:auth_required, [Part.Text.new("log in")]}}
      end)
    end

    action :many, :term do
      public?(true)

      run(fn _input, _ctx ->
        {:ok,
         %AshA2A.Artifacts{
           artifacts: [[Part.Text.new("a")], %{name: "second", parts: [Part.Text.new("b")]}]
         }}
      end)
    end
  end

  a2a do
    skill(:echo, :read,
      examples: ["echo hello"],
      input_modes: ["text/plain", "application/json"],
      output_modes: ["application/json"],
      streaming?: true
    )

    skill(:needs_more, :needs_more, consequence: :observe)
    skill(:needs_auth, :needs_auth, consequence: :observe)
    skill(:many, :many, consequence: :observe)
  end
end

defmodule AshA2A.DslCardSurface.Home do
  @moduledoc false
  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.DslCardSurface.Res)
  end
end

defmodule AshA2A.DslCardSurface.CardDomain do
  @moduledoc false
  use Ash.Domain, extensions: [AshA2A, AshA2A.Domain], validate_config_inclusion?: false

  resources do
    resource(AshA2A.DslCardSurface.Res)
  end

  agent do
    name("w11-card")
    default_input_modes(["application/json"])
    default_output_modes(["application/json", "text/plain"])
    sign_card("key-1")
  end

  security do
    security_scheme(:token, :bearer, bearer_format: "JWT")
    security_scheme(:key, :api_key, location: :query, param_name: "k")
    security_scheme(:basic, :http, http_scheme: "basic")

    security_scheme(:oauth, :oauth2,
      oauth_flows: %{
        "clientCredentials" => %{
          "tokenUrl" => "https://auth.example.com/token",
          "scopes" => %{"read" => "read things"}
        }
      },
      scopes: ["read"]
    )

    security_scheme(:oidc, :openid_connect, openid_url: "https://auth.example.com/.well-known")
    security_scheme(:tls, :mtls)

    requirements(["token", "oauth"])
    requirement_scopes(%{"oauth" => ["read"]})
  end

  transport do
    base_url("https://w11.example.com")
    extended_agent_card(true)
    push_allowed_hosts(["hooks.example.com"])
    push_retry(max_attempts: 3, backoff_ms: 200)

    extension("https://example.com/ext/one", required: true, description: "one")
    extension("https://example.com/ext/two", params: %{"k" => "v"})
  end
end

defmodule AshA2A.DslCardSurfaceTest do
  use ExUnit.Case, async: true

  import Spark.Test, only: [assert_dsl_error: 2]

  alias AshA2A.Domain.Info
  alias AshA2A.DslCardSurface.{CardDomain, Res}

  describe "skill entity" do
    test "examples/modes/streaming? are copied into the compiled capability" do
      skill = Enum.find(AshA2A.Info.capability_index(Res), &(&1.action == :read))

      assert skill.examples == ["echo hello"]
      assert skill.input_modes == ["text/plain", "application/json"]
      assert skill.output_modes == ["application/json"]
      assert skill.streaming? == true
    end

    test "the card skill projects examples and modes; undeclared skills omit them" do
      card = AshA2A.Info.agent_card(Res)
      echo = Enum.find(card.skills, &String.ends_with?(&1.id, ".read"))
      other = Enum.find(card.skills, &String.ends_with?(&1.id, ".many"))

      assert echo.examples == ["echo hello"]
      assert echo.input_modes == ["text/plain", "application/json"]
      assert echo.output_modes == ["application/json"]
      refute Map.has_key?(other, :examples)
      refute Map.has_key?(other, :input_modes)
    end

    test "kill: a non-MIME mode fails compilation" do
      error =
        assert_dsl_error %Spark.Error.DslError{} do
          defmodule Elixir.AshA2A.W11Test.BadMode do
            @moduledoc false
            use Ash.Resource, domain: nil, data_layer: Ash.DataLayer.Ets, extensions: [AshA2A]

            attributes do
              uuid_primary_key(:id)
            end

            actions do
              defaults([:read])
            end

            a2a do
              skill(:echo, :read, input_modes: ["not a mime"])
            end
          end
        end

      assert error.message =~ "refused_mode_not_mime"
    end

    test "kill: a security requirement naming no declared scheme fails compilation" do
      error =
        assert_dsl_error %Spark.Error.DslError{} do
          defmodule Elixir.AshA2A.W11Test.BadSecurityDomain do
            @moduledoc false
            use Ash.Domain,
              extensions: [AshA2A, AshA2A.Domain],
              validate_config_inclusion?: false

            resources do
              resource(AshA2A.DslCardSurface.Res)
            end

            agent do
              name("bad-sec")
            end

            transport do
              base_url("https://x.example.com")
            end

            security do
              security_scheme(:token, :bearer)
            end

            a2a do
              skill(:echo, AshA2A.DslCardSurface.Res, :read,
                security_requirements: [%{"ghost" => []}]
              )
            end
          end
        end

      assert error.message =~ "refused_security_requirement_undeclared"
    end
  end

  describe "domain config" do
    test "agent modes and sign_card are persisted" do
      assert Info.agent_default_input_modes(CardDomain) == ["application/json"]
      assert Info.agent_default_output_modes(CardDomain) == ["application/json", "text/plain"]
      assert Info.agent_sign_card(CardDomain) == "key-1"
    end

    test "builder prefers declared default modes over its own default" do
      card = AshA2A.Info.agent_card(CardDomain)
      assert card.default_input_modes == ["application/json"]
      assert card.default_output_modes == ["application/json", "text/plain"]
    end

    test "all security scheme kinds project to protocol structs" do
      schemes = AshA2A.Info.agent_card(CardDomain).security_schemes

      assert %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "bearer", bearer_format: "JWT"} =
               schemes["token"]

      assert %AshA2A.Protocol.SecurityScheme.APIKey{name: "k", in: "query"} = schemes["key"]
      assert %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "basic"} = schemes["basic"]

      assert %AshA2A.Protocol.SecurityScheme.OAuth2{flows: %{"clientCredentials" => _}} =
               schemes["oauth"]

      assert %AshA2A.Protocol.SecurityScheme.OpenIDConnect{
               open_id_connect_url: "https://auth.example.com/.well-known"
             } = schemes["oidc"]

      assert %AshA2A.Protocol.SecurityScheme.MutualTLS{} = schemes["tls"]
    end

    test "per-requirement scopes reach card.security" do
      security = AshA2A.Info.agent_card(CardDomain).security
      assert %{"token" => []} in security
      assert %{"oauth" => ["read"]} in security
    end

    test "extensions merge into capabilities; extended_agent_card is declared" do
      caps = AshA2A.Info.agent_card(CardDomain).capabilities

      assert caps.extended_agent_card == true

      assert [
               %AshA2A.Protocol.AgentExtension{
                 uri: "https://example.com/ext/one",
                 required: true
               },
               %AshA2A.Protocol.AgentExtension{
                 uri: "https://example.com/ext/two",
                 params: %{"k" => "v"}
               }
             ] = caps.extensions
    end

    test "push policy options are persisted" do
      assert Info.push_allowed_hosts(CardDomain) == ["hooks.example.com"]
      assert Info.push_retry(CardDomain) == [max_attempts: 3, backoff_ms: 200]
    end

    test "kill: duplicate extension uri fails compilation" do
      error =
        assert_dsl_error %Spark.Error.DslError{} do
          defmodule Elixir.AshA2A.W11Test.DupExt do
            @moduledoc false
            use Ash.Domain, extensions: [AshA2A.Domain]

            agent do
              name("dup")
            end

            transport do
              base_url("https://x.example.com")
              extension("https://example.com/e")
              extension("https://example.com/e")
            end
          end
        end

      assert error.message =~ "duplicate"
    end

    test "kill: oauth2 without oauth_flows fails compilation" do
      error =
        assert_dsl_error %Spark.Error.DslError{} do
          defmodule Elixir.AshA2A.W11Test.BadOauth do
            @moduledoc false
            use Ash.Domain, extensions: [AshA2A.Domain]

            agent do
              name("bad-oauth")
            end

            transport do
              base_url("https://x.example.com")
            end

            security do
              security_scheme(:o, :oauth2)
            end
          end
        end

      assert error.message =~ "oauth_flows"
    end
  end

  describe "mount tenant / protocol_version" do
    defmodule TenantAgent do
      @moduledoc false
      use AshA2A.Agent,
        resource_or_domain: AshA2A.DslCardSurface.Res,
        name: "w11_tenant_agent",
        public_skills: [:echo]
    end

    defmodule TenantDomain do
      @moduledoc false
      use Ash.Domain, extensions: [AshA2A.Domain]

      agent do
        name("tenant-domain")
      end

      transport do
        base_url("https://t.example.com")

        mount agent: AshA2A.DslCardSurfaceTest.TenantAgent,
              path: "/t",
              binding: :jsonrpc,
              tenant: "acme",
              protocol_version: "1.0"
      end
    end

    test "supported_interfaces carries tenant and protocol_version only when declared" do
      assert [
               %{
                 url: "https://t.example.com/t",
                 protocol_binding: "JSONRPC",
                 tenant: "acme",
                 protocol_version: "1.0"
               }
             ] = Info.supported_interfaces(TenantDomain)
    end

    test "builder normalization keeps the tenant on the interface" do
      card =
        AshA2A.CapabilityIndex.AgentCardBuilder.build_agent_card([],
          supported_interfaces: [
            %{url: "https://t.example.com/t", protocol_binding: "JSONRPC", tenant: "acme"}
          ]
        )

      version = AshA2A.Protocol.Version.protocol_version()
      assert [%{tenant: "acme", protocol_version: ^version}] = card.supported_interfaces
    end
  end

  describe "generic-action return contract" do
    alias AshA2A.Protocol.{Message, Part}

    defp dispatch(skill),
      do: AshA2A.Dispatcher.dispatch_observe(skill, Message.new_user("hi"), Res)

    test "{:input_required, parts} replies input_required" do
      assert {:input_required, [%Part.Text{text: "need more"}]} = dispatch(:needs_more)
    end

    test "{:auth_required, parts} replies an untagged auth_required error" do
      assert {:error, {:auth_required, [%Part.Text{text: "log in"}]}} = dispatch(:needs_auth)
    end

    test "%AshA2A.Artifacts{} flattens artifact parts in order" do
      assert {:reply, [%Part.Text{text: "a"}, %Part.Text{text: "b"}]} = dispatch(:many)
    end
  end
end
