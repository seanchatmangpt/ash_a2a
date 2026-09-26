defmodule AshA2A.ExecutionSnapshotSemanticIdentityTest do
  use ExUnit.Case, async: true

  alias AshA2A.ExecutionSnapshot

  defp snapshot(overrides \\ []) do
    base = [
      task_id: "task-1",
      work_order_digest: "sha256:work-order",
      command_digest: "sha256:command",
      exact_subject: "repo@example-subject",
      candidate_digest: "sha256:candidate",
      authority_digest: "sha256:authority",
      consequence_digest: "sha256:consequence",
      capability_digest: "sha256:capability",
      semantic_request_digest: "sha256:request",
      tool_surface_digest: "sha256:tools",
      ontology_digest: "sha256:ontology",
      policy_digest: "sha256:policy",
      effect_digest: "sha256:effect",
      authority_requirement: "CONSTRUCT",
      planner_snapshot: %{planner: "fond", digest: "sha256:planner"},
      execution_manifest_digest: "sha256:manifest",
      root_task_id: "root-1",
      parent_task_id: "parent-1",
      delegation_policy: %{max_depth: 3},
      depth: 1,
      worker_id: "worker-a",
      provider_projection: %{provider: "provider-a", transport: "wss", run_id: "run-a"},
      checkpoint: %{sequence: 1},
      created_at: 1_700_000_000_000,
      sequence: 1,
      state: :running
    ]

    ExecutionSnapshot.new!(Keyword.merge(base, overrides))
  end

  test "provider run transport and lifecycle changes do not change semantic work identity" do
    left = snapshot()

    right =
      snapshot(
        worker_id: "worker-b",
        provider_projection: %{provider: "provider-b", transport: "http", run_id: "run-z"},
        checkpoint: %{sequence: 99},
        created_at: 1_800_000_000_000,
        sequence: 99,
        state: :checkpointed
      )

    assert ExecutionSnapshot.semantic_identity_digest(left) ==
             ExecutionSnapshot.semantic_identity_digest(right)

    refute ExecutionSnapshot.digest(left) == ExecutionSnapshot.digest(right)
  end

  test "every exact execution identity component is identity-bearing" do
    original = snapshot()

    for {field, replacement} <- [
          task_id: "task-2",
          work_order_digest: "sha256:other-work-order",
          command_digest: "sha256:other-command",
          exact_subject: "repo@different-subject",
          candidate_digest: "sha256:other-candidate",
          authority_digest: "sha256:other-authority",
          consequence_digest: "sha256:other-consequence",
          capability_digest: "sha256:other-capability",
          execution_manifest_digest: "sha256:other-manifest"
        ] do
      changed = snapshot([{field, replacement}])

      refute ExecutionSnapshot.semantic_identity_digest(original) ==
               ExecutionSnapshot.semantic_identity_digest(changed),
             "#{field} must participate in semantic identity"
    end
  end

  test "planner policy and effect semantics remain identity-bearing" do
    original = snapshot()

    for changed <- [
          snapshot(effect_digest: "sha256:different-effect"),
          snapshot(authority_requirement: "DO"),
          snapshot(policy_digest: "sha256:different-policy"),
          snapshot(planner_snapshot: %{planner: "hddl", digest: "sha256:other-plan"})
        ] do
      refute ExecutionSnapshot.semantic_identity_digest(original) ==
               ExecutionSnapshot.semantic_identity_digest(changed)
    end
  end

  test "deterministic serialization ignores nested map insertion order" do
    left =
      snapshot(
        planner_snapshot: Map.new([{:planner, "fond"}, {:digest, "sha256:planner"}]),
        delegation_policy: Map.new([{:max_depth, 3}, {:mode, :bounded}])
      )

    right =
      snapshot(
        planner_snapshot: Map.new([{:digest, "sha256:planner"}, {:planner, "fond"}]),
        delegation_policy: Map.new([{:mode, :bounded}, {:max_depth, 3}])
      )

    assert ExecutionSnapshot.semantic_identity_digest(left) ==
             ExecutionSnapshot.semantic_identity_digest(right)

    assert ExecutionSnapshot.encode(left) == ExecutionSnapshot.encode(right)
  end

  test "digests are lowercase sha256 hex" do
    snapshot = snapshot()

    assert ExecutionSnapshot.digest(snapshot) =~ ~r/^[0-9a-f]{64}$/
    assert ExecutionSnapshot.semantic_identity_digest(snapshot) =~ ~r/^[0-9a-f]{64}$/
    assert ExecutionSnapshot.replay_key(snapshot) =~ ~r/^[0-9a-f]{64}$/
  end
end
