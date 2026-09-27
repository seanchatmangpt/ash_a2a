defmodule AshA2A.SpgIdentityTest do
  use ExUnit.Case, async: true

  alias AshA2A.{Command, Identity, Receipt, SemanticProjection, SpgIdentity}

  test "SPG identity is stable command identity and survives receipt -> OCEL projection" do
    assert {:ok, spg} =
             SpgIdentity.new(
               graph_id: "spg:sa2a-brce-first-court",
               graph_version: "26.9.25",
               node_id: "actuate",
               edge_id: "e4",
               projection_family: "sa2a"
             )

    command =
      Command.new("example.change",
        command_id: "spg-command-1",
        agent_id: "agent-1",
        principal_id: "principal-1",
        input: %{value: 1},
        spg_identity: spg
      )

    same_without_spg =
      Command.new("example.change",
        command_id: "spg-command-2",
        agent_id: "agent-1",
        principal_id: "principal-1",
        input: %{value: 1}
      )

    refute command.fingerprint == same_without_spg.fingerprint

    receipt =
      Receipt.from_reply(
        command,
        Identity.execution("spg-execution-1"),
        :observe,
        {:reply, []}
      )

    assert receipt.metadata.spg_graph_id == "spg:sa2a-brce-first-court"
    assert receipt.metadata.spg_graph_version == "26.9.25"
    assert receipt.metadata.spg_node_id == "actuate"
    assert receipt.metadata.spg_edge_id == "e4"
    assert receipt.metadata.spg_projection_family == "sa2a"

    event = SemanticProjection.ocel_event(receipt)
    assert event["attributes"]["spg_graph_id"] == "spg:sa2a-brce-first-court"
    assert event["attributes"]["spg_graph_version"] == "26.9.25"
    assert event["attributes"]["spg_node_id"] == "actuate"
    assert event["attributes"]["spg_edge_id"] == "e4"
    assert event["attributes"]["spg_projection_family"] == "sa2a"
  end

  test "invalid empty semantic identities are refused" do
    assert {:error, {:refused_spg_identity, :node_id}} =
             SpgIdentity.new(
               graph_id: "spg:test",
               graph_version: "1",
               node_id: ""
             )
  end
end
