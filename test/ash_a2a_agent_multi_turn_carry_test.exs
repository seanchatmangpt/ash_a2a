defmodule AshA2AAgentMultiTurnCarryTest do
  @moduledoc """
  Real multi-turn argument carry-over through a real supervised `A2A.Agent`:
  turn 1's Data arguments survive into turn 2's dispatch. No mocks.
  """

  use ExUnit.Case, async: true

  import AshA2A.Test.MessageHelpers

  alias AshA2A.Test.Fixture.MultiTurnPairAgent

  setup do
    AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [MultiTurnPairAgent])
    :ok
  end

  test "a follow-up supplying only the missing argument completes with turn 1's argument" do
    assert {:ok, turn1} = MultiTurnPairAgent.call(MultiTurnPairAgent, data_message(%{left: "a"}))
    assert turn1.status.state == :input_required

    assert {:ok, turn2} =
             MultiTurnPairAgent.call(MultiTurnPairAgent, data_message(%{right: "b"}),
               task_id: turn1.id
             )

    assert turn2.status.state == :completed
    assert [%A2A.Artifact{parts: [%A2A.Part.Data{data: result}]}] = turn2.artifacts
    assert result[:left] == "a"
    assert result[:right] == "b"
  end

  test "the current turn wins on key collision" do
    assert {:ok, turn1} =
             MultiTurnPairAgent.call(MultiTurnPairAgent, data_message(%{left: "old"}))

    assert turn1.status.state == :input_required

    assert {:ok, turn2} =
             MultiTurnPairAgent.call(
               MultiTurnPairAgent,
               data_message(%{left: "new", right: "r"}),
               task_id: turn1.id
             )

    assert [%A2A.Artifact{parts: [%A2A.Part.Data{data: result}]}] = turn2.artifacts
    assert result[:left] == "new"
  end

  test "a fresh task with no history is not affected by other tasks" do
    assert {:ok, _} = MultiTurnPairAgent.call(MultiTurnPairAgent, data_message(%{left: "a"}))
    assert {:ok, fresh} = MultiTurnPairAgent.call(MultiTurnPairAgent, data_message(%{right: "b"}))
    assert fresh.status.state == :input_required
  end
end
