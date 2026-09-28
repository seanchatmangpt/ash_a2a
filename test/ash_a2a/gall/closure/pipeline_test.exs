defmodule AshA2A.Gall.Closure.PipelineTest do
  use ExUnit.Case, async: true
  alias AshA2A.Gall.Closure.{Determinism, IdempotencyPolicy, Pipeline}

  test "source admission composes into one-DO preflight without granting authority" do
    candidate = %{
      producer_repository: "seanchatmangpt/beam4pm",
      producer_sha: String.duplicate("a", 40),
      evidence_digest: "sha256:" <> String.duplicate("b", 64),
      semantic_subject_digest: "sha256:" <> String.duplicate("c", 64),
      candidate_digest: "sha256:" <> String.duplicate("d", 64),
      finding_class: "conformance",
      vocabulary: "https://w3id.org/ocel",
      capability_id: "Item.create"
    }

    policy = %{
      allowed_producers: %{"seanchatmangpt/beam4pm" => candidate.producer_sha},
      allowed_evidence_digests: [candidate.evidence_digest],
      allowed_semantic_subjects: [candidate.semantic_subject_digest],
      public_vocabularies: [candidate.vocabulary],
      allowed_capabilities: [candidate.capability_id],
      task_id: "task-1"
    }

    assert {:ok, admitted} = Pipeline.admit(candidate, policy)
    input = %{label: "x"}
    command = %{
      capability_id: "Item.create",
      input: input,
      target: "Item",
      metadata: %{
        gall_029_candidate_digest: candidate.candidate_digest,
        idempotency_key: IdempotencyPolicy.key_for(candidate.candidate_digest)
      }
    }

    scope = %{input_digest: Determinism.digest(input), target: "Item"}

    assert {:ok, ready} =
             Pipeline.preflight(admitted, command, %{
               scope: scope,
               max_consequences: 1,
               expected_postcondition: %{item_exists: true}
             })

    assert ready.budget == 1
    assert ready.provenance.authority == :none

    assert {:error, {:refused_gall, :budget_policy, {:must_equal_one, 2}}} =
             Pipeline.preflight(admitted, command, %{
               scope: scope,
               max_consequences: 2,
               expected_postcondition: %{item_exists: true}
             })
  end
end
