# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.AgentCardHonestyTest.Resource do
  @moduledoc false
  use Ash.Resource,
    domain: AshA2A.AgentCardHonestyTest.PlainDomain,
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

defmodule AshA2A.AgentCardHonestyTest.PlainDomain do
  @moduledoc false
  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.AgentCardHonestyTest.Resource)
  end
end

defmodule AshA2A.AgentCardHonestyTest.Agent do
  @moduledoc false
  use AshA2A.Agent,
    resource_or_domain: AshA2A.AgentCardHonestyTest.Resource,
    name: "card_honesty_agent",
    public_skills: [:echo]
end

defmodule AshA2A.AgentCardHonestyTest.MountedDomain do
  @moduledoc false
  use Ash.Domain, extensions: [AshA2A, AshA2A.Domain], validate_config_inclusion?: false

  resources do
    resource(AshA2A.AgentCardHonestyTest.Resource)
  end

  agent do
    name "honesty-mounted"
  end

  transport do
    base_url "https://honesty.example.com"
    streaming(false)
    mount agent: AshA2A.AgentCardHonestyTest.Agent, path: "/rpc", binding: :jsonrpc
    mount agent: AshA2A.AgentCardHonestyTest.Agent, path: "/rest", binding: :rest
  end
end

defmodule AshA2A.AgentCardHonestyTest.FullDomain do
  @moduledoc false
  use Ash.Domain, extensions: [AshA2A, AshA2A.Domain], validate_config_inclusion?: false

  resources do
    resource(AshA2A.AgentCardHonestyTest.Resource)
  end

  agent do
    name "honesty-full"
  end

  transport do
    base_url "https://full.example.com"
    streaming(true)
    push_notifications(true)
    extended_agent_card(true)
    user_artifacts(true)
    mount agent: AshA2A.AgentCardHonestyTest.Agent, path: "/rpc", binding: :jsonrpc
  end

  security do
    security_scheme(:token, :bearer)
    requirements(["token"])
  end
end

defmodule AshA2A.AgentCardHonestyTest do
  use ExUnit.Case, async: true

  alias AshA2A.AgentCardHonestyTest, as: T
  alias AshA2A.Protocol.AgentCard

  @domains [T.PlainDomain, T.MountedDomain, T.FullDomain]

  for domain <- @domains do
    test "card for #{inspect(domain)} passes its own audit" do
      card = AshA2A.Info.agent_card(unquote(domain))
      assert AgentCard.audit(card, domain: unquote(domain)) == []

      wire = AshA2A.Protocol.JSON.encode_agent_card(card, url: card.url)
      assert AgentCard.audit(wire, domain: unquote(domain)) == []
    end
  end

  test "mounted card advertises exactly the mounted bindings and no streaming" do
    card = AshA2A.Info.agent_card(T.MountedDomain)
    assert Enum.map(card.supported_interfaces, & &1.protocol_binding) == ["JSONRPC", "HTTP+JSON"]
    refute card.capabilities.streaming
  end

  test "a deliberately inconsistent card fails the audit with every code" do
    card = AshA2A.Info.agent_card(T.MountedDomain)

    bad = %{
      card
      | supported_interfaces:
          card.supported_interfaces ++
            [%{url: "https://x/grpc", protocol_binding: "GRPC", protocol_version: "1.0"}],
        capabilities:
          Map.merge(card.capabilities, %{
            streaming: true,
            push_notifications: true,
            live: true
          }),
        skills:
          card.skills ++
            [%{id: "Ghost.private", name: "ghost", description: "d", tags: []}],
        security_schemes: %{"ghost" => %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "bearer"}},
        security: [%{"missing" => []}]
    }

    codes = bad |> AgentCard.audit(domain: T.MountedDomain) |> Enum.map(& &1.code)

    assert :unmounted_binding in codes
    assert :capability_not_enabled in codes
    assert :skill_not_public in codes
    assert :security_scheme_not_configured in codes
    assert :security_requirement_undeclared in codes
  end

  test "explicit mounted_opts override the domain" do
    card = AshA2A.Info.agent_card(T.FullDomain)

    codes =
      card
      |> AgentCard.audit(domain: T.FullDomain, streaming: false, bindings: ["HTTP+JSON"])
      |> Enum.map(& &1.code)

    assert :capability_not_enabled in codes
    assert :unmounted_binding in codes
  end

  test ":card_signatures passes through unmodified" do
    sigs = [%{"protected" => "p", "signature" => "s"}]
    card = AshA2A.Info.agent_card(T.PlainDomain, card_signatures: sigs)
    assert card.signatures == sigs
    assert AshA2A.Info.agent_card(T.PlainDomain).signatures == []

    wire = AshA2A.Protocol.JSON.encode_agent_card(card, url: card.url)
    assert wire["signatures"] == sigs
  end
end
