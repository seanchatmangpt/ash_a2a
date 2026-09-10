defmodule AshA2ATest do
  @moduledoc """
  Chicago-style: compiles the real `AshA2A.Test.Fixture.Echo` resource
  (`test/support/fixture.ex`), a real `Ash.Resource` with `extensions:
  [AshA2A]` and a real `a2a do skill :echo, :read end` block -- no
  Mock/mox/patch, no stubbed A2A or Ash behavior.
  """

  use ExUnit.Case

  alias AshA2A.Test.Fixture.Echo

  test "AshA2A.Info.capability_index?/1 is true for the real compiled fixture" do
    assert AshA2A.Info.capability_index?(Echo)
  end

  test "the persisted capability index contains the real :echo skill" do
    assert [%AshA2A.Skill{name: :echo, resource: Echo, action: :read}] =
             AshA2A.Info.capability_index(Echo)
  end

  test "the persisted skill's domain is the real, statically resolved domain" do
    assert [%AshA2A.Skill{domain: AshA2A.Test.Fixture.Domain}] =
             AshA2A.Info.capability_index(Echo)

    assert Ash.Resource.Info.domain(Echo) == AshA2A.Test.Fixture.Domain
  end

  test "the built AgentCard lists the real :echo skill" do
    agent_card = AshA2A.Info.agent_card(Echo, name: "echo_agent")

    assert %A2A.AgentCard{name: "echo_agent"} = agent_card
    assert [%{id: "echo", name: "echo"}] = agent_card.skills
  end

  test "the skill's own resolved domain is accepted by a real Ash.Query.for_read/3 call" do
    # Exercises the exact `domain:` opt `AshA2A.Dispatcher.build_opts/2` now
    # sources from `skill.domain` (falling back to the exec-context domain
    # only when `skill.domain` is `nil`) -- confirms it is a real,
    # Ash-accepted domain, not merely a non-nil value.
    [%AshA2A.Skill{domain: domain} = skill] = AshA2A.Info.capability_index(Echo)
    refute is_nil(domain)

    assert {:ok, []} =
             skill.resource
             |> Ash.Query.for_read(:read, %{}, domain: domain)
             |> Ash.read(domain: domain)
  end

  test "the domain also has a real (empty) verified capability index" do
    assert AshA2A.Info.capability_index?(AshA2A.Test.Fixture.Domain)
    assert AshA2A.Info.capability_index(AshA2A.Test.Fixture.Domain) == []
  end

  test "AshA2A.Dispatcher.dispatch/3 dispatches the real :echo skill without a KeyError" do
    # Real repro for the reviewed `skill.domain` KeyError: a bare `AshA2A.Skill`
    # struct with no `:domain` key would crash `Map.get(skill, :domain)` in
    # `AshA2A.Dispatcher.build_opts/2` with a `KeyError`. `AshA2A.Skill` now
    # declares `:domain` (skill.ex:23) and `BuildCapabilityIndex` fills it in
    # at compile time, so this must run cleanly against the real compiled
    # fixture, not a hand-built struct.
    message = A2A.Message.new_user([A2A.Part.Data.new(%{})])

    assert {:reply, [%A2A.Part.Data{data: %{results: []}}]} =
             AshA2A.Dispatcher.dispatch(:echo, message, Echo)
  end
end
