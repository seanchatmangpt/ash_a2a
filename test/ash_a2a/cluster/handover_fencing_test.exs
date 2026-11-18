# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Cluster.HandoverFencingTest.MapStore do
  @moduledoc false
  # A real, hand-written task-store interface implementation (Agent-backed map).
  def start, do: Agent.start_link(fn -> %{} end)

  def get(agent, id) do
    case Agent.get(agent, &Map.get(&1, id)) do
      nil -> {:error, :not_found}
      task -> {:ok, task}
    end
  end

  def put(agent, task), do: Agent.update(agent, &Map.put(&1, task.id, task))
end

defmodule AshA2A.Cluster.HandoverFencingTest do
  use ExUnit.Case, async: true

  alias AshA2A.Cluster.Checkpoint
  alias AshA2A.Cluster.Handover
  alias AshA2A.Cluster.HandoverFencingTest.MapStore

  @claim_key "a2a.cluster.claim"

  setup do
    {:ok, agent} = MapStore.start()
    store = {MapStore, agent}
    Checkpoint.land(store, "t-1", %{step: 1})
    {:ok, task} = MapStore.get(agent, "t-1")
    %{store: store, agent: agent, task: task}
  end

  test "a runner whose claim was taken over cannot complete or release the peer's claim",
       %{store: store, agent: agent, task: task} do
    resume = fn _task, _frame ->
      # While this (slow) runner works, a peer takes the claim over.
      {:ok, current} = MapStore.get(agent, "t-1")
      peer = %{"node" => :peer@host, "ref" => "PEER", "expires_at_ms" => 4_102_444_800_000}
      MapStore.put(agent, %{current | metadata: Map.put(current.metadata, @claim_key, peer)})
      {:ok, :slow_result}
    end

    assert {:error, %{task_id: "t-1", reason: {:handover, :claim_lost}}} =
             Handover.rehydrate_one(store, task, resume)

    {:ok, stored} = MapStore.get(agent, "t-1")
    refute AshA2A.Protocol.Task.terminal?(stored)
    assert stored.metadata[@claim_key]["ref"] == "PEER"
  end

  test "an uncontested resume completes and clears the claim", %{
    store: store,
    agent: agent,
    task: task
  } do
    assert {:ok, %{task_id: "t-1", result: :ok_result}} =
             Handover.rehydrate_one(store, task, fn _t, _f -> {:ok, :ok_result} end)

    {:ok, stored} = MapStore.get(agent, "t-1")
    assert stored.status.state == :completed
    refute Map.has_key?(stored.metadata, @claim_key)
  end
end
