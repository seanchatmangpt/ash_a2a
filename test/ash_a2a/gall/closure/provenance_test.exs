defmodule AshA2A.Gall.Closure.ProvenanceTest do
  use ExUnit.Case, async: true
  alias AshA2A.Gall.Closure.Provenance

  test "provenance retains producer, evidence, semantic and candidate identities" do
    candidate = %{
      producer_repository: "seanchatmangpt/beam4pm",
      producer_sha: String.duplicate("a", 40),
      evidence_digest: "sha256:" <> String.duplicate("b", 64),
      semantic_subject_digest: "sha256:" <> String.duplicate("c", 64),
      candidate_digest: "sha256:" <> String.duplicate("d", 64)
    }

    envelope = Provenance.build(candidate, "task-1")
    assert envelope.task_id == "task-1"
    assert envelope.authority == :none
    assert Provenance.valid?(envelope)
    refute Provenance.valid?(Map.put(envelope, :task_id, "task-2"))
  end
end
