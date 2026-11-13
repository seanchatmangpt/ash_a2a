# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Authority.GraphPinTest do
  @moduledoc """
  Court for the AshA2A.Authority.GraphPin seam (lane Z12).

  Ladder: pin -> fresh :ok -> mutate digest -> stale refused -> re-pin
  recovers. Also: fail-closed unpinned, invalid-digest refuse, format
  parity with the HILT WorkOrder carried digest, and a pluggable-store
  proof (real second implementation, not a mock).
  """

  use ExUnit.Case, async: true

  alias AshA2A.Authority.GraphPin
  alias AshA2A.Authority.GraphPin.Store

  @digest "sha256:" <> String.duplicate("ab", 32)
  @other_digest "sha256:" <> String.duplicate("cd", 32)

  defmodule EtsStore do
    @moduledoc "Real second store implementation: proves the behaviour seam."
    @behaviour Store

    def init, do: :ets.new(__MODULE__, [:set, :public, :named_table])

    @impl Store
    def get(order_id) do
      case :ets.lookup(__MODULE__, order_id) do
        [{_, d}] -> d
        [] -> nil
      end
    end

    @impl Store
    def put(order_id, digest), do: :ets.insert(__MODULE__, {order_id, digest}) && :ok
  end

  setup do
    EtsStore.init()
    :ok
  end

  test "pin -> fresh :ok -> mutate -> :stale_graph_identity -> re-pin recovers" do
    assert :ok = GraphPin.pin("order-1", @digest)
    assert :ok = GraphPin.assert_fresh("order-1", @digest)

    # graph mutated under the order
    assert {:error, :stale_graph_identity} = GraphPin.assert_fresh("order-1", @other_digest)

    # re-pin recovers
    assert :ok = GraphPin.pin("order-1", @other_digest)
    assert :ok = GraphPin.assert_fresh("order-1", @other_digest)
    assert {:error, :stale_graph_identity} = GraphPin.assert_fresh("order-1", @digest)
  end

  test "unpinned order is fail-closed :unpinned, never :ok" do
    assert {:error, :unpinned} = GraphPin.assert_fresh("never-admitted", @digest)
  end

  test "invalid digests are refused on both ports" do
    assert {:error, :invalid_digest} = GraphPin.pin("order-2", "not-a-digest")
    assert {:error, :invalid_digest} = GraphPin.pin("order-2", "sha256:ZZ")

    assert :ok = GraphPin.pin("order-2", @digest)
    assert {:error, :invalid_digest} = GraphPin.assert_fresh("order-2", nil)
    assert {:error, :invalid_digest} = GraphPin.assert_fresh("order-2", "sha256:ZZ")
  end

  test "digest format matches HILT WorkOrder carried digests" do
    order =
      AshA2A.Hilt.WorkOrder.new!(
        work_order_id: "wo-z12",
        task_id: "task-z12",
        exact_subject_digest: "subj",
        candidate_digest: "cand",
        capability_id: "cap-z12",
        observation_bounds_digest: "ob",
        action_bounds_digest: "ab",
        authority_ceiling: :observe,
        consequence_class: :observe,
        process_evidence_digest: "pe",
        falsifier_digest: "f",
        graph_digest: @digest
      )

    assert order.graph_digest =~ ~r/\Asha256:[0-9a-f]{64}\z/
    assert :ok = GraphPin.pin(order.work_order_id, order.graph_digest)
    assert :ok = GraphPin.assert_fresh(order.work_order_id, order.graph_digest)
  end

  test "pluggable store: ETS backend preserves the same contract" do
    assert :ok = GraphPin.pin("order-ets", @digest, store: EtsStore)
    assert :ok = GraphPin.assert_fresh("order-ets", @digest, store: EtsStore)

    assert {:error, :stale_graph_identity} =
             GraphPin.assert_fresh("order-ets", @other_digest, store: EtsStore)

    assert {:error, :unpinned} = GraphPin.assert_fresh("order-ets", @digest)
  end

  test "pins are order-keyed: one order's mutation does not affect another" do
    assert :ok = GraphPin.pin("order-a", @digest)
    assert :ok = GraphPin.pin("order-b", @other_digest)
    assert :ok = GraphPin.assert_fresh("order-a", @digest)
    assert :ok = GraphPin.assert_fresh("order-b", @other_digest)
  end
end
