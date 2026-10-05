# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Hilt.WorkOrderGraphDigestTest do
  @moduledoc """
  Two-port graph-digest integrity in `AshA2A.Hilt.WorkOrder` (lane A1,
  v26.10.1-loop): a carried `graph_digest` on the work order is checkpoint
  evidence pinned against the executing command's `semantic_subject.graph_digest`
  at admission. Identity (`identity_digest/1`) is SA2A work-order identity and
  never includes `graph_digest` (RESOLUTIONS R5); the pin lives on the two-port
  plane, enforced by `checkpoint_graph_digest/2` inside `admit_command/2`.
  """

  use ExUnit.Case, async: false

  import AshA2A.Test.MessageHelpers

  alias AshA2A.{Command, CommandBus, ReceiptStore, SemanticSubject}
  alias AshA2A.Hilt.WorkOrder
  alias AshA2A.Test.Fixture.Echo

  @ga "sha256:" <> String.duplicate("a", 64)
  @gb "sha256:" <> String.duplicate("b", 64)
  @gc "sha256:" <> String.duplicate("c", 64)
  @gd "sha256:" <> String.duplicate("d", 64)

  setup do
    # A2A-2601: real production retry window, shrunk for this suite's asserts.
    Application.put_env(:ash_a2a, :receipt_commit_retry_delays_ms, [1, 1])
    on_exit(fn -> Application.delete_env(:ash_a2a, :receipt_commit_retry_delays_ms) end)

    name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    start_supervised!({AshA2A.ReceiptStore.Memory, name: name})
    %{store_opts: [name: name]}
  end

  defp subject(graph_digest \\ @ga) do
    {:ok, subject} =
      SemanticSubject.new(
        graph_digest: graph_digest,
        projection_digest: @gb,
        manufacturer_digest: @gc,
        ephemeral?: false
      )

    subject
  end

  defp candidate(graph_digest) do
    Command.new("AshA2A.Test.Fixture.Echo.read",
      command_id: "hilt-graph-1",
      agent_id: "agent-1",
      principal_id: "anonymous",
      task_id: "hilt-graph-task-1",
      semantic_subject: subject(graph_digest),
      input: %{},
      metadata: %{candidate_digest: "sha256:hilt-graph-candidate"}
    )
  end

  # graph_digest: :carry (default) omits the key entirely to exercise
  # carry-by-default; any other value is passed through explicitly.
  defp order_for(command, opts \\ []) do
    graph_opt =
      case Keyword.fetch(opts, :graph_digest) do
        {:ok, :carry} -> []
        {:ok, value} -> [graph_digest: value]
        :error -> []
      end

    WorkOrder.for_command!(command, :observe,
      [
        work_order_id: "hilt-graph-wo-1",
        observation_bounds: %{resources: ["echo"], max_items: 1},
        action_bounds: %{actions: [command.capability_id], max_external_requests: 0},
        authority_ceiling: :observe,
        process_evidence: %{ocel_required: true},
        falsifier: %{refuse_on: [:stale_graph_identity]},
        metadata: %{}
      ] ++ graph_opt
    )
  end

  describe "checkpoint_graph_digest/2 via admit_command/2" do
    test "disagreeing graph digest is refused :stale_graph_identity" do
      command = candidate(@ga)
      order = order_for(command, graph_digest: @gd)

      assert {:error, :stale_graph_identity} = WorkOrder.admit_command(order, command)
    end

    test "agreeing graph digest admits" do
      command = candidate(@ga)
      order = order_for(command, graph_digest: @ga)
      bound = WorkOrder.bind_command(order, command)

      assert :ok = WorkOrder.admit_command(order, bound)
    end

    test "nil order graph digest skips the checkpoint (order nil, subject present)" do
      command = candidate(@ga)
      order = order_for(command, graph_digest: nil)
      bound = WorkOrder.bind_command(order, command)

      assert :ok = WorkOrder.admit_command(order, bound)
    end

    test "nil subject graph digest skips the checkpoint (hand-built subject, order digest present)" do
      # SemanticSubject.new/1 enforces the sha256 form; a struct built directly
      # (e.g. by an older producer) may carry graph_digest: nil. The checkpoint
      # must skip, not refuse, when either port lacks a digest.
      raw_subject = %SemanticSubject{
        graph_digest: nil,
        projection_digest: @gb,
        manufacturer_digest: @gc,
        ephemeral?: false
      }

      command =
        Command.new("AshA2A.Test.Fixture.Echo.read",
          command_id: "hilt-graph-nil-subject",
          agent_id: "agent-1",
          principal_id: "anonymous",
          task_id: "hilt-graph-task-nil",
          semantic_subject: raw_subject,
          input: %{},
          metadata: %{candidate_digest: "sha256:hilt-graph-candidate"}
        )

      order = order_for(command, graph_digest: @ga)
      bound = WorkOrder.bind_command(order, command)

      assert :ok = WorkOrder.admit_command(order, bound)
    end

    test "both nil skip" do
      raw_subject = %SemanticSubject{
        graph_digest: nil,
        projection_digest: @gb,
        manufacturer_digest: "sha256:" <> String.duplicate("c", 64),
        ephemeral?: false
      }

      command =
        Command.new("AshA2A.Test.Fixture.Echo.read",
          command_id: "hilt-graph-both-nil",
          agent_id: "agent-1",
          principal_id: "anonymous",
          task_id: "hilt-graph-task-both-nil",
          semantic_subject: raw_subject,
          input: %{},
          metadata: %{candidate_digest: "sha256:hilt-graph-candidate"}
        )

      order = order_for(command)
      bound = WorkOrder.bind_command(order, command)

      assert %WorkOrder{graph_digest: nil} = order
      assert :ok = WorkOrder.admit_command(order, bound)
    end
  end

  describe "new!/1 graph_digest validation" do
    test "nil is accepted" do
      command = candidate(@ga)

      assert %WorkOrder{graph_digest: nil} = order_for(command, graph_digest: nil)
    end

    test "valid sha256:64-hex is accepted" do
      command = candidate(@ga)
      assert %WorkOrder{graph_digest: @ga} = order_for(command, graph_digest: @ga)
    end

    test "wrong scheme raises" do
      command = candidate(@ga)

      assert_raise ArgumentError, ~r/graph_digest/, fn ->
        order_for(command, graph_digest: "md5:" <> String.duplicate("a", 64))
      end
    end

    test "63 hex chars raise" do
      command = candidate(@ga)

      assert_raise ArgumentError, ~r/graph_digest/, fn ->
        order_for(command, graph_digest: "sha256:" <> String.duplicate("a", 63))
      end
    end

    test "64 non-hex chars raise" do
      command = candidate(@ga)

      assert_raise ArgumentError, ~r/graph_digest/, fn ->
        order_for(command, graph_digest: "sha256:" <> String.duplicate("g", 64))
      end
    end

    test "non-binary raises" do
      command = candidate(@ga)

      assert_raise ArgumentError, ~r/graph_digest/, fn ->
        order_for(command, graph_digest: 42)
      end
    end
  end

  describe "for_command!/3 carry-by-default" do
    test "carries the command subject's graph_digest by default" do
      command = candidate(@ga)
      order = WorkOrder.for_command!(command, :observe, order_opts())

      assert order.graph_digest == @ga
    end

    test "an explicit opts[:graph_digest] overrides the carried default" do
      command = candidate(@ga)
      order = WorkOrder.for_command!(command, :observe, order_opts(graph_digest: @gd))

      assert order.graph_digest == @gd
    end

    test "an explicit opts[:graph_digest: nil] builds a checkpoint-free order" do
      command = candidate(@ga)
      order = WorkOrder.for_command!(command, :observe, order_opts(graph_digest: nil))

      assert order.graph_digest == nil
    end
  end

  describe "identity-digest exclusion pin (R5)" do
    test "identity_digest is invariant under a graph_digest change" do
      command = candidate(@ga)

      carried = WorkOrder.for_command!(command, :observe, order_opts())
      divergent = WorkOrder.for_command!(command, :observe, order_opts(graph_digest: @gd))

      assert WorkOrder.identity_digest(carried) == WorkOrder.identity_digest(divergent)
    end

    test "bind_command metadata stays work-order identity, never graph_digest" do
      command = candidate(@ga)
      carried = WorkOrder.for_command!(command, :observe, order_opts())
      divergent = WorkOrder.for_command!(command, :observe, order_opts(graph_digest: @gd))

      bound_carried = WorkOrder.bind_command(carried, command)
      bound_divergent = WorkOrder.bind_command(divergent, command)

      assert bound_carried.metadata.work_order_digest ==
               WorkOrder.identity_digest(carried)

      assert bound_divergent.metadata.work_order_digest ==
               WorkOrder.identity_digest(divergent)

      assert bound_carried.metadata.work_order_digest == bound_divergent.metadata.work_order_digest
    end
  end

  describe "e2e through the real CommandBus" do
    test "stale graph identity is refused before claim; no receipt is minted", %{
      store_opts: store_opts
    } do
      command = candidate(@ga)
      order = order_for(command, graph_digest: @gd)
      bound = WorkOrder.bind_command(order, command)

      assert {:error, %{code: :stale_graph_identity}} =
               CommandBus.run(bound, data_message(%{}), Echo,
                 store_opts: store_opts,
                 work_order: order
               )

      assert :error = ReceiptStore.Memory.fetch(bound.command_id, store_opts)
    end

    test "lawful pair completes and replays the closed receipt", %{store_opts: store_opts} do
      command = candidate(@ga)
      order = order_for(command, graph_digest: @ga)
      bound = WorkOrder.bind_command(order, command)

      assert {:ok, first} =
               CommandBus.run(bound, data_message(%{}), Echo,
                 store_opts: store_opts,
                 work_order: order
               )

      assert first.status == :completed

      assert {:ok, replay} =
               CommandBus.run(bound, data_message(%{}), Echo,
                 store_opts: store_opts,
                 work_order: order
               )

      assert replay.replayed?
      assert replay.receipt_id == first.receipt_id
    end
  end

  defp order_opts(extra \\ []) do
    [
      work_order_id: "hilt-graph-wo-1",
      observation_bounds: %{resources: ["echo"], max_items: 1},
      action_bounds: %{actions: ["AshA2A.Test.Fixture.Echo.read"], max_external_requests: 0},
      authority_ceiling: :observe,
      process_evidence: %{ocel_required: true},
      falsifier: %{refuse_on: [:stale_graph_identity]},
      metadata: %{}
    ] ++ extra
  end
end
