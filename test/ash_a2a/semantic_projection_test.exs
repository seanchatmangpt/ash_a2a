defmodule AshA2A.SemanticProjectionTest do
  use ExUnit.Case, async: true

  alias AshA2A.{Command, Identity, Receipt, SemanticProjection}
  alias AshA2A.Test.Fixture.Echo

  test "receipt projection preserves typed identity, replay, consequence, and standing" do
    command =
      Command.new("AshA2A.Test.Fixture.Echo.read",
        command_id: "semantic-1",
        agent_id: "agent-1",
        principal_id: "principal-1",
        task_id: "task-1"
      )

    receipt =
      Receipt.from_reply(command, Identity.execution("exec-1"), :observe, {:reply, []})

    semantic = SemanticProjection.receipt(receipt)

    assert semantic.command_id == "command:semantic-1"
    assert semantic.execution_id == "execution:exec-1"
    assert semantic.task_id == "task:task-1"
    assert semantic.capability_id == "AshA2A.Test.Fixture.Echo.read"
    assert semantic.consequence == :observe
    assert semantic.standing == :observed
  end

  test "OCEL event identity is the committed receipt identity" do
    command =
      Command.new("AshA2A.Test.Fixture.Echo.read",
        command_id: "semantic-2",
        agent_id: "agent-1",
        principal_id: "principal-1"
      )

    receipt = Receipt.from_reply(command, Identity.execution("exec-2"), :observe, {:reply, []})
    event = SemanticProjection.ocel_event(receipt)

    assert event["event_id"] == Identity.external(receipt.receipt_id)
    assert event["event_type"] == "ash_a2a.receipt.completed"
    assert event["attributes"]["command_id"] == "command:semantic-2"
    assert event["attributes"]["execution_id"] == "execution:exec-2"
  end

  test "capability projection joins Ash capability identity to ash_r2rml inspection without executing RDF" do
    assert {:ok, projection} =
             SemanticProjection.capability(Echo, "AshA2A.Test.Fixture.Echo.read")

    assert projection.resource == inspect(Echo)
    assert projection.action == :read
    assert Map.has_key?(projection, :r2rml_mapping_result)
  end
end
