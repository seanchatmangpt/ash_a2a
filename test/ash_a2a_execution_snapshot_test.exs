defmodule AshA2A.ExecutionSnapshotTest do
  use ExUnit.Case, async: true

  alias AshA2A.ExecutionSnapshot

  defp fresh do
    ExecutionSnapshot.new!(
      task_id: "task-1",
      exact_subject: "repo@abc",
      capability_digest: "cap",
      execution_manifest_digest: "manifest",
      root_task_id: "task-1"
    )
  end

  test "worker death does not kill durable task state" do
    {:ok, claimed} = ExecutionSnapshot.claim(fresh(), "worker-a")
    {:ok, running} = ExecutionSnapshot.start(claimed)
    {:ok, checkpointed} = ExecutionSnapshot.checkpoint(running, 1, "history-1")
    before = ExecutionSnapshot.digest(checkpointed)

    {:ok, reclaimable} = ExecutionSnapshot.worker_lost(checkpointed)
    assert reclaimable.task_id == checkpointed.task_id
    assert reclaimable.checkpoint == checkpointed.checkpoint
    assert is_nil(reclaimable.worker_id)

    {:ok, reclaimed} = ExecutionSnapshot.claim(reclaimable, "worker-b")
    {:ok, resumed} = ExecutionSnapshot.start(reclaimed)

    assert resumed.task_id == checkpointed.task_id
    assert resumed.checkpoint.sequence == 1
    assert resumed.worker_id == "worker-b"
    refute ExecutionSnapshot.digest(resumed) == before
  end

  test "checkpoint sequence must be monotonic" do
    {:ok, claimed} = ExecutionSnapshot.claim(fresh(), "worker-a")
    {:ok, running} = ExecutionSnapshot.start(claimed)
    {:ok, checkpointed} = ExecutionSnapshot.checkpoint(running, 2, "history-2")

    assert {:error, :checkpoint_not_monotonic} =
             ExecutionSnapshot.checkpoint(checkpointed, 2, "history-again")
  end

  test "same receipt replay is idempotent but second consequence is refused" do
    {:ok, claimed} = ExecutionSnapshot.claim(fresh(), "worker-a")
    {:ok, running} = ExecutionSnapshot.start(claimed)
    {:ok, completed} = ExecutionSnapshot.complete(running, "receipt-1")

    assert {:ok, ^completed} = ExecutionSnapshot.complete(completed, "receipt-1")

    assert {:error, :duplicate_consequence} =
             ExecutionSnapshot.complete(completed, "receipt-2")
  end

  test "invalid identity is rejected before any lifecycle transition" do
    assert_raise ArgumentError, fn ->
      ExecutionSnapshot.new!(
        task_id: "",
        exact_subject: "repo@abc",
        capability_digest: "cap",
        execution_manifest_digest: "manifest"
      )
    end
  end
end
