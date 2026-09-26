defmodule AshA2A.ExecutionSnapshotTest do
  use ExUnit.Case, async: true

  alias AshA2A.ExecutionSnapshot

  defp fresh(overrides \\ []) do
    attrs = [
      task_id: "task-1",
      work_order_digest: "sha256:work-order",
      command_digest: "sha256:command",
      exact_subject: "repo@abc",
      candidate_digest: "sha256:candidate",
      authority_digest: "sha256:authority",
      consequence_digest: "sha256:consequence",
      capability_digest: "sha256:capability",
      execution_manifest_digest: "sha256:manifest",
      root_task_id: "task-1"
    ]

    ExecutionSnapshot.new!(Keyword.merge(attrs, overrides))
  end

  test "worker death does not kill durable task state or semantic identity" do
    {:ok, claimed} = ExecutionSnapshot.claim(fresh(), "worker-a")
    {:ok, running} = ExecutionSnapshot.start(claimed)
    {:ok, checkpointed} = ExecutionSnapshot.checkpoint(running, 1, "history-1")
    semantic_before = ExecutionSnapshot.semantic_identity_digest(checkpointed)
    topology_before = ExecutionSnapshot.digest(checkpointed)

    {:ok, reclaimable} = ExecutionSnapshot.worker_lost(checkpointed)
    assert reclaimable.task_id == checkpointed.task_id
    assert reclaimable.checkpoint == checkpointed.checkpoint
    assert is_nil(reclaimable.worker_id)

    {:ok, reclaimed} = ExecutionSnapshot.claim(reclaimable, "worker-b")
    {:ok, resumed} = ExecutionSnapshot.start(reclaimed)

    assert resumed.task_id == checkpointed.task_id
    assert resumed.checkpoint.sequence == 1
    assert resumed.worker_id == "worker-b"
    assert ExecutionSnapshot.semantic_identity_digest(resumed) == semantic_before
    refute ExecutionSnapshot.digest(resumed) == topology_before
  end

  test "checkpoint binds the exact semantic execution identity" do
    {:ok, claimed} = ExecutionSnapshot.claim(fresh(), "worker-a")
    {:ok, running} = ExecutionSnapshot.start(claimed)
    {:ok, checkpointed} = ExecutionSnapshot.checkpoint(running, 1, "history-1")

    assert checkpointed.checkpoint.semantic_identity_digest ==
             ExecutionSnapshot.semantic_identity_digest(checkpointed)

    assert checkpointed.checkpoint.command_digest == "sha256:command"
    assert checkpointed.checkpoint.candidate_digest == "sha256:candidate"
    assert checkpointed.checkpoint.authority_digest == "sha256:authority"
    assert checkpointed.checkpoint.consequence_digest == "sha256:consequence"
  end

  test "checkpoint sequence must be monotonic" do
    {:ok, claimed} = ExecutionSnapshot.claim(fresh(), "worker-a")
    {:ok, running} = ExecutionSnapshot.start(claimed)
    {:ok, checkpointed} = ExecutionSnapshot.checkpoint(running, 2, "history-2")

    assert {:error, :checkpoint_not_monotonic} =
             ExecutionSnapshot.checkpoint(checkpointed, 2, "history-again")
  end

  test "same bound receipt replay is idempotent but receipt substitution is refused" do
    {:ok, claimed} = ExecutionSnapshot.claim(fresh(), "worker-a")
    {:ok, running} = ExecutionSnapshot.start(claimed)

    {:ok, completed} =
      ExecutionSnapshot.complete(running, "receipt-1", "sha256:receipt-binding")

    assert {:ok, ^completed} =
             ExecutionSnapshot.complete(completed, "receipt-1", "sha256:receipt-binding")

    assert {:error, :receipt_binding_mismatch} =
             ExecutionSnapshot.complete(completed, "receipt-1", "sha256:forged-binding")

    assert {:error, :duplicate_consequence} =
             ExecutionSnapshot.complete(completed, "receipt-2", "sha256:receipt-binding")
  end

  test "legacy receipt replay remains idempotent without manufacturing a binding" do
    {:ok, claimed} = ExecutionSnapshot.claim(fresh(), "worker-a")
    {:ok, running} = ExecutionSnapshot.start(claimed)
    {:ok, completed} = ExecutionSnapshot.complete(running, "receipt-1")

    assert is_nil(completed.consequence_receipt_digest)
    assert {:ok, ^completed} = ExecutionSnapshot.complete(completed, "receipt-1")
  end

  test "deterministic durable encoding survives restart without identity drift" do
    {:ok, claimed} = ExecutionSnapshot.claim(fresh(), "worker-a")
    {:ok, running} = ExecutionSnapshot.start(claimed)
    {:ok, checkpointed} = ExecutionSnapshot.checkpoint(running, 7, "history-7")
    encoded = ExecutionSnapshot.encode(checkpointed)

    restored = ExecutionSnapshot.decode!(encoded)

    assert restored == checkpointed
    assert ExecutionSnapshot.encode(restored) == encoded
    assert ExecutionSnapshot.replay_key(restored) == ExecutionSnapshot.replay_key(checkpointed)
  end

  test "invalid identity is rejected before any lifecycle transition" do
    Enum.each(ExecutionSnapshot.required_identity_fields(), fn field ->
      attrs = [
        task_id: "task-1",
        work_order_digest: "sha256:work-order",
        command_digest: "sha256:command",
        exact_subject: "repo@abc",
        candidate_digest: "sha256:candidate",
        authority_digest: "sha256:authority",
        consequence_digest: "sha256:consequence",
        capability_digest: "sha256:capability",
        execution_manifest_digest: "sha256:manifest"
      ]

      assert_raise ArgumentError, fn ->
        ExecutionSnapshot.new!(Keyword.put(attrs, field, ""))
      end
    end)
  end

  test "refusal is lifecycle evidence, never provider projection" do
    snapshot = fresh(provider_projection: %{provider: "provider-a", transport: "http"})
    {:ok, refused} = ExecutionSnapshot.refuse(snapshot, :authority_mismatch)

    assert refused.state == :refused
    assert refused.refusal == %{reason: :authority_mismatch}
    assert refused.provider_projection == snapshot.provider_projection

    assert ExecutionSnapshot.semantic_identity_digest(refused) ==
             ExecutionSnapshot.semantic_identity_digest(snapshot)
  end
end
