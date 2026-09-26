defmodule AshA2A.ExecutionSnapshotSemanticIdentityTest do
  use ExUnit.Case, async: true

  alias AshA2A.ExecutionSnapshot

  defp snapshot(overrides \\ []) do
    base = [
      task_id: "task-1",
      exact_subject: "repo@example-subject",
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
      provider_projection: %{provider: "provider-a", transport: "wss"},
      checkpoint: %{sequence: 1},
      created_at: 1_700_000_000_000,
      sequence: 1,
      state: :running
    ]

    ExecutionSnapshot.new!(Keyword.merge(base, overrides))
  end

  test "topology changes do not change semantic work identity" do
    left = snapshot()

    right =
      snapshot(
        worker_id: "worker-b",
        provider_projection: %{provider: "provider-b", transport: "http"},
        checkpoint: %{sequence: 99},
        created_at: 1_800_000_000_000,
        sequence: 99,
        state: :checkpointed
      )

    assert ExecutionSnapshot.semantic_identity_digest(left) ==
             ExecutionSnapshot.semantic_identity_digest(right)

    refute ExecutionSnapshot.digest(left) == ExecutionSnapshot.digest(right)
  end

  test "semantic subject and consequence requirements remain identity-bearing" do
    original = snapshot()

    refute ExecutionSnapshot.semantic_identity_digest(original) ==
             ExecutionSnapshot.semantic_identity_digest(
               snapshot(exact_subject: "repo@different-subject")
             )

    refute ExecutionSnapshot.semantic_identity_digest(original) ==
             ExecutionSnapshot.semantic_identity_digest(
               snapshot(effect_digest: "sha256:different-effect")
             )

    refute ExecutionSnapshot.semantic_identity_digest(original) ==
             ExecutionSnapshot.semantic_identity_digest(
               snapshot(authority_requirement: "DO")
             )
  end

  test "digests are lowercase sha256 hex" do
    snapshot = snapshot()

    assert ExecutionSnapshot.digest(snapshot) =~ ~r/^[0-9a-f]{64}$/
    assert ExecutionSnapshot.semantic_identity_digest(snapshot) =~ ~r/^[0-9a-f]{64}$/
  end
end
