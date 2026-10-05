# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.DomainTransportsTest.Resource do
  @moduledoc """
  Real fixture resource: one real `:read` skill (`:echo`), so each mounted
  agent has exactly one skill and dispatch needs no `:skill` metadata.
  """

  use Ash.Resource,
    domain: AshA2A.DomainTransportsTest.HomeDomain,
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

defmodule AshA2A.DomainTransportsTest.HomeDomain do
  @moduledoc "Real fixture home domain for the fixture resource above."
  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.DomainTransportsTest.Resource)
  end
end

defmodule AshA2A.DomainTransportsTest.EchoAgent do
  @moduledoc "Real `AshA2A.Agent` GenServer over the fixture resource (JSON-RPC mount)."

  use AshA2A.Agent,
    resource_or_domain: AshA2A.DomainTransportsTest.Resource,
    name: "domain_transports_echo_agent",
    public_skills: [:echo]
end

defmodule AshA2A.DomainTransportsTest.RestAgent do
  @moduledoc "Real `AshA2A.Agent` GenServer over the fixture resource (REST mount)."

  use AshA2A.Agent,
    resource_or_domain: AshA2A.DomainTransportsTest.Resource,
    name: "domain_transports_rest_agent",
    public_skills: [:echo]
end

defmodule AshA2A.DomainTransportsTest.MountedDomain do
  @moduledoc """
  Real domain-level transport surface (lane G-I): two real agents mounted
  at declared paths over declared bindings, plus one `:grpc` mount.
  """

  use Ash.Domain, extensions: [AshA2A.Domain]

  agent do
    name "mounted-domain"
    description "Domain-level mounts court domain"
  end

  transport do
    base_url "https://agents.example.com"

    mount agent: AshA2A.DomainTransportsTest.EchoAgent,
      path: "/echo",
      binding: :jsonrpc

    mount agent: AshA2A.DomainTransportsTest.RestAgent,
      path: "/greeter",
      binding: :rest

    mount agent: AshA2A.DomainTransportsTest.EchoAgent,
      path: "/echo-grpc",
      binding: :grpc
  end
end

defmodule AshA2A.DomainTransportsTest.LegacyDefaultMountDomain do
  @moduledoc "Domain declaring only the path-only default mount (`default_mount`)."

  use Ash.Domain, extensions: [AshA2A.Domain]

  agent do
    name "legacy-default-mount"
  end

  transport do
    base_url "https://legacy.example.com"
    default_mount "/legacy"
  end
end

defmodule AshA2A.DomainTransportsTest.CardDomain do
  @moduledoc """
  Domain carrying both the capability (`AshA2A`) and transport
  (`AshA2A.Domain`) extensions, with three declared mounts over the three
  bindings -- the declared-transport `supported_interfaces` court subject.
  """

  use Ash.Domain, extensions: [AshA2A, AshA2A.Domain], validate_config_inclusion?: false

  resources do
    resource(AshA2A.DomainTransportsTest.Resource)
  end

  agent do
    name "card-domain"
    version "1.0.0"
  end

  transport do
    base_url "https://cards.example.com"

    mount agent: AshA2A.DomainTransportsTest.EchoAgent,
      path: "/echo",
      binding: :jsonrpc

    mount agent: AshA2A.DomainTransportsTest.RestAgent,
      path: "/greeter",
      binding: :rest

    mount agent: AshA2A.DomainTransportsTest.EchoAgent,
      path: "/echo-grpc",
      binding: :grpc
  end
end

defmodule AshA2A.DomainTransportsTest.OneMountDomain do
  @moduledoc "Card court subject declaring exactly one per-agent mount."

  use Ash.Domain, extensions: [AshA2A, AshA2A.Domain], validate_config_inclusion?: false

  resources do
    resource(AshA2A.DomainTransportsTest.Resource)
  end

  agent do
    name "one-mount-domain"
  end

  transport do
    base_url "https://one.example.com"

    mount agent: AshA2A.DomainTransportsTest.EchoAgent, path: "/only", binding: :jsonrpc
  end
end

defmodule AshA2A.DomainTransportsTest do
  @moduledoc """
  Court for domain-level transport definition (Workstream3 G5, lane G-I):
  the verified ash_json_api pattern -- domain-level route definition as the
  documented default -- applied to `AshA2A.Domain`.

  Real domain with two real agents + declared mounts -> `AshA2A.Domain.Router`
  serves both agents' cards and dispatch at their paths (real Bandit server,
  real supervised agent GenServers, real `Req` calls); a misdeclared agent is
  a compile-time verifier refusal (`Spark.Error.DslError`). No mocks.
  """

  use ExUnit.Case, async: false

  import Spark.Test, only: [assert_dsl_error: 2]

  @moduletag :serial_shard

  alias AshA2A.Domain.Info
  alias AshA2A.Domain.Mount
  alias AshA2A.Domain.Router
  alias AshA2A.Test.{AgentSupervisorCase, EphemeralHttp}

  setup do
    {_sup, _registry} =
      AgentSupervisorCase.start_supervised_agents!(__MODULE__, [
        AshA2A.DomainTransportsTest.EchoAgent,
        AshA2A.DomainTransportsTest.RestAgent
      ])

    %{
      server:
        EphemeralHttp.start!(
          {Router, domain: AshA2A.DomainTransportsTest.MountedDomain}
        )
    }
  end

  # -- persisted mount specs ---------------------------------------------------

  test "mounts/1 records every declared per-agent mount" do
    mounts = Info.mounts(AshA2A.DomainTransportsTest.MountedDomain)

    assert length(mounts) == 3
    assert Enum.map(mounts, &{&1.agent, &1.path, &1.binding}) == [
             {AshA2A.DomainTransportsTest.EchoAgent, "/echo", :jsonrpc},
             {AshA2A.DomainTransportsTest.RestAgent, "/greeter", :rest},
             {AshA2A.DomainTransportsTest.EchoAgent, "/echo-grpc", :grpc}
           ]

    assert Enum.all?(mounts, &match?(%Mount{}, &1))
  end

  test "default_mount/1 and mount/1 keep the path-only default semantics" do
    assert Info.default_mount(AshA2A.DomainTransportsTest.LegacyDefaultMountDomain) == "/legacy"
    assert Info.mount(AshA2A.DomainTransportsTest.LegacyDefaultMountDomain) == "/legacy"

    # no path-only declaration -> historical default
    assert Info.default_mount(AshA2A.DomainTransportsTest.MountedDomain) == "/a2a"
    assert Info.mount(AshA2A.DomainTransportsTest.MountedDomain) == "/a2a"
  end

  # -- declared-transport supported_interfaces default (lane ZD4) ---------------

  describe "declared-transport supported_interfaces default" do
    @version AshA2A.Protocol.Version.protocol_version()

    test "a domain with three declared mounts projects three supported_interfaces entries" do
      card = AshA2A.Info.agent_card(AshA2A.DomainTransportsTest.CardDomain)

      assert card.supported_interfaces == [
               %{
                 url: "https://cards.example.com/echo",
                 protocol_binding: "JSONRPC",
                 protocol_version: @version
               },
               %{
                 url: "https://cards.example.com/greeter",
                 protocol_binding: "HTTP+JSON",
                 protocol_version: @version
               },
               %{
                 url: "https://cards.example.com/echo-grpc",
                 protocol_binding: "GRPC",
                 protocol_version: @version
               }
             ]
    end

    test "a domain with one declared mount projects exactly one supported_interfaces entry" do
      card = AshA2A.Info.agent_card(AshA2A.DomainTransportsTest.OneMountDomain)

      assert card.supported_interfaces == [
               %{
                 url: "https://one.example.com/only",
                 protocol_binding: "JSONRPC",
                 protocol_version: @version
               }
             ]
    end

    test "an explicit :supported_interfaces opt still overrides the declared transports" do
      override = [%{url: "https://manual.example.com/rpc", protocol_binding: "JSONRPC"}]

      card =
        AshA2A.Info.agent_card(AshA2A.DomainTransportsTest.CardDomain,
          supported_interfaces: override
        )

      assert card.supported_interfaces == [
               %{
                 url: "https://manual.example.com/rpc",
                 protocol_binding: "JSONRPC",
                 protocol_version: @version
               }
             ]
    end

    test "a domain with no declared transports keeps the legacy single-JSONRPC default" do
      # HomeDomain declares the capability extension but no `transport`
      # section: no mounts -> the historical single-entry default at the
      # builder url.
      card = AshA2A.Info.agent_card(AshA2A.DomainTransportsTest.HomeDomain)

      assert card.supported_interfaces == [
               %{
                 url: "http://localhost:4000",
                 protocol_binding: "JSONRPC",
                 protocol_version: @version
               }
             ]
    end
  end

  # -- router serves both agents at their paths ----------------------------------

  test "jsonrpc mount serves the agent card and dispatch at its path", %{server: server} do
    card = Req.get!(url: server.base_url <> "/echo/.well-known/agent-card.json")
    assert card.status == 200
    assert %{"name" => "domain_transports_echo_agent"} = card.body

    resp =
      Req.post!(url: server.base_url <> "/echo",
        json: %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "message/send",
          "params" => %{"message" => message_map("hello from the domain router")}
        }
      )

    assert resp.status == 200
    assert %{"result" => %{"task" => %{"id" => task_id}}} = resp.body
    assert is_binary(task_id)
  end

  test "rest mount serves the agent card and dispatch at its path", %{server: server} do
    card = Req.get!(url: server.base_url <> "/greeter/.well-known/agent-card.json")
    assert card.status == 200
    assert %{"name" => "domain_transports_rest_agent"} = card.body

    resp =
      Req.post!(url: server.base_url <> "/greeter/message:send",
        headers: [{"content-type", "application/json"}],
        json: %{"message" => message_map("hello over rest")}
      )

    assert resp.status == 200
    assert %{"task" => %{"id" => task_id}} = resp.body
    assert is_binary(task_id)
  end

  test "grpc mount answers a typed 501 refusal naming the gRPC endpoint", %{server: server} do
    resp = Req.post!(url: server.base_url <> "/echo-grpc", json: %{"any" => "body"})

    assert resp.status == 501
    assert %{"error" => %{"code" => "grpc_not_served_over_http", "details" => details}} = resp.body
    assert details["reason"] == "GRPC_BINDING_NOT_ROUTABLE"
    assert details["metadata"]["endpoint"] =~ "GRPC.Server.Endpoint"
  end

  test "an undeclared path is a typed 404", %{server: server} do
    resp = Req.get!(url: server.base_url <> "/not-declared")

    assert resp.status == 404
  end

  # -- compile-time refusal ------------------------------------------------------

  test "kill: a mount naming a nonexistent agent fails compilation with a real DslError" do
    error =
      assert_dsl_error %Spark.Error.DslError{} do
        defmodule Elixir.AshA2A.Test.DomainTransports.Misdeclared do
          @moduledoc false

          use Ash.Domain, extensions: [AshA2A.Domain]

          agent do
            name "misdeclared"
          end

          transport do
            base_url "https://misdeclared.example.com"

            mount agent: This.Agent.Does.Not.Exist,
              path: "/nowhere",
              binding: :jsonrpc
          end
        end
      end

    assert error.message =~ "This.Agent.Does.Not.Exist"
    assert error.message =~ "does not exist"
  end

  test "kill: a duplicate mount path fails compilation with a real DslError" do
    error =
      assert_dsl_error %Spark.Error.DslError{} do
        defmodule Elixir.AshA2A.Test.DomainTransports.DuplicatePath do
          @moduledoc false

          use Ash.Domain, extensions: [AshA2A.Domain]

          agent do
            name "duplicate-path"
          end

          transport do
            base_url "https://duplicate.example.com"

            mount agent: AshA2A.DomainTransportsTest.EchoAgent, path: "/same", binding: :jsonrpc

            mount agent: AshA2A.DomainTransportsTest.RestAgent, path: "/same", binding: :rest
          end
        end
      end

    assert error.message =~ "/same"
    assert error.message =~ "more than once"
  end

  test "kill: an agent mounted twice over one binding fails compilation with a real DslError" do
    error =
      assert_dsl_error %Spark.Error.DslError{} do
        defmodule Elixir.AshA2A.Test.DomainTransports.DuplicateBinding do
          @moduledoc false

          use Ash.Domain, extensions: [AshA2A.Domain]

          agent do
            name "duplicate-binding"
          end

          transport do
            base_url "https://duplicate-binding.example.com"

            mount agent: AshA2A.DomainTransportsTest.EchoAgent, path: "/one", binding: :jsonrpc

            mount agent: AshA2A.DomainTransportsTest.EchoAgent, path: "/two", binding: :jsonrpc
          end
        end
      end

    assert error.message =~ "more than once over the `jsonrpc` binding"
  end

  # -- helpers ----------------------------------------------------------------

  defp message_map(text) do
    AshA2A.Protocol.JSON.encode!(AshA2A.Protocol.Message.new_user(text))
  end
end
