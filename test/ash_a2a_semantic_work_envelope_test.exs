defmodule AshA2A.Semantic.WorkEnvelopeTest do
  use ExUnit.Case, async: true

  alias AshA2A.Semantic.{CanonicalGraph, WorkEnvelope}

  @ttl """
  @prefix gall: <https://semantic-a2a.dev/gall#> .
  <urn:gall:checkpoint:test:001> a gall:CodingCheckpoint .
  """

  test "checkpoint envelope is bound to observed canonical graph identity" do
    {:ok, digest} = CanonicalGraph.canonical_digest(@ttl)

    descriptor = %{
      "checkpoint_iri" => "urn:gall:checkpoint:test:001",
      "repository" => "seanchatmangpt/ash_a2a",
      "base_sha" => String.duplicate("b", 40),
      "graph_digest" => "sha256:" <> digest,
      "goal" => "transport the work subject",
      "verifier_suite" => "ash-a2a-dod",
      "standing" => "UNKNOWN",
      "required_capabilities" => ["Read", "Edit"],
      "forbidden_capabilities" => ["Push", "Publish"]
    }

    assert {:ok, envelope} = WorkEnvelope.checkpoint(@ttl, descriptor)
    assert envelope["graph_digest"] == "sha256:" <> digest
    assert envelope["canonicalization"] == "RDFC-1.0/SHA-256/n-quads-sorted"
  end

  test "caller supplied graph identity cannot replace observed identity" do
    descriptor = %{
      "checkpoint_iri" => "urn:gall:checkpoint:test:001",
      "repository" => "seanchatmangpt/ash_a2a",
      "base_sha" => String.duplicate("b", 40),
      "graph_digest" => "sha256:" <> String.duplicate("0", 64)
    }

    assert {:error, %{code: :refused_graph_identity_mismatch}} =
             WorkEnvelope.checkpoint(@ttl, descriptor)
  end

  test "capability contradiction is refused" do
    {:ok, digest} = CanonicalGraph.canonical_digest(@ttl)

    descriptor = %{
      "checkpoint_iri" => "urn:gall:checkpoint:test:001",
      "repository" => "repo",
      "base_sha" => String.duplicate("b", 40),
      "graph_digest" => "sha256:" <> digest,
      "required_capabilities" => ["Publish"],
      "forbidden_capabilities" => ["Publish"]
    }

    assert {:error, %{code: :refused_capability_contradiction}} =
             WorkEnvelope.checkpoint(@ttl, descriptor)
  end

  test "lease and receipt preserve checkpoint identity without promoting standing" do
    {:ok, digest} = CanonicalGraph.canonical_digest(@ttl)

    {:ok, checkpoint} =
      WorkEnvelope.checkpoint(@ttl, %{
        "checkpoint_iri" => "urn:gall:checkpoint:test:001",
        "repository" => "repo",
        "base_sha" => String.duplicate("b", 40),
        "graph_digest" => "sha256:" <> digest
      })

    assert {:ok, lease} =
             WorkEnvelope.work_lease(checkpoint, %{
               "epoch_id" => "123e4567-e89b-42d3-a456-426614174000",
               "worker_id" => "zcode-01",
               "worktree" => "/tmp/worktree"
             })

    assert lease["graph_digest"] == checkpoint["graph_digest"]
    refute Map.has_key?(lease, "standing")

    assert {:ok, receipt} =
             WorkEnvelope.receipt(checkpoint, %{
               "receipt_iri" => "urn:receipt:1",
               "candidate_sha" => String.duplicate("c", 40),
               "standing" => "BUILD_BROKEN",
               "verifier" => "ash-a2a-dod"
             })

    assert receipt["standing"] == "BUILD_BROKEN"
  end
end
