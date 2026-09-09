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

  test "the built AgentCard lists the real :echo skill" do
    agent_card = AshA2A.Info.agent_card(Echo, name: "echo_agent")

    assert %A2A.AgentCard{name: "echo_agent"} = agent_card
    assert [%{id: "echo", name: "echo"}] = agent_card.skills
  end

  test "the domain also has a real (empty) verified capability index" do
    assert AshA2A.Info.capability_index?(AshA2A.Test.Fixture.Domain)
    assert AshA2A.Info.capability_index(AshA2A.Test.Fixture.Domain) == []
  end
end
