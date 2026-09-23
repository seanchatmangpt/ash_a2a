defmodule AshA2A.Semantic.WorkEnvelopeTest do
  use ExUnit.Case, async: true

  alias AshA2A.Semantic.{CanonicalGraph, WorkEnvelope}

  @ttl """
  @prefix gall: <https://semantic-a2a.dev/gall#> .
  <urn:gall:checkpoint:test:001> a gall:CodingCheckpoint .
  """

  defp descriptor(digest) do
    %{
      "work_order_iri" => "urn:gall:work-order:test:001",
      "checkpoint_iri" => "urn:gall:checkpoint:test:001",
      "repository_identity" => "seanchatmangpt/ash_a2a",
      "base_sha" => String.duplicate("b", 40),
      "graph_digest" => "sha256:" <> digest
    }
  end

  test "checkpoint envelope is bound to observed canonical graph identity" do
    {:ok, digest} = CanonicalGraph.canonical_digest(@ttl)

    input =
      descriptor(digest)
      |> Map.merge(%{
        "goal" => "transport the work subject",
        "verifier_suite" => "ash-a2a-dod",
        "standing" => "UNKNOWN",
        "required_capabilities" => ["Read", "Edit"],
        "forbidden_capabilities" => ["Push", "Publish"]
      })

    assert {:ok, envelope} = WorkEnvelope.checkpoint(@ttl, input)
    assert envelope["graph_digest"] == "sha256:" <> digest
    assert envelope["canonicalization"] == "RDFC-1.0/SHA-256/n-quads-sorted"
  end

  test "caller supplied graph identity cannot replace observed identity" do
    input = %{
      descriptor(String.duplicate("0", 64))
      | "graph_digest" => "sha256:" <> String.duplicate("0", 64)
    }

    assert {:error, %{code: :refused_graph_identity_mismatch}} =
             WorkEnvelope.checkpoint(@ttl, input)
  end

  test "capability contradiction is refused" do
    {:ok, digest} = CanonicalGraph.canonical_digest(@ttl)

    input =
      descriptor(digest)
      |> Map.merge(%{
        "required_capabilities" => ["Publish"],
        "forbidden_capabilities" => ["Publish"]
      })

    assert {:error, %{code: :refused_capability_contradiction}} =
             WorkEnvelope.checkpoint(@ttl, input)
  end

  test "lease and receipt preserve exact work subject identity without promoting standing" do
    {:ok, digest} = CanonicalGraph.canonical_digest(@ttl)
    assert {:ok, checkpoint} = WorkEnvelope.checkpoint(@ttl, descriptor(digest))

    assert {:ok, lease} =
             WorkEnvelope.work_lease(checkpoint, %{
               "epoch_id" => "123e4567-e89b-42d3-a456-426614174000",
               "worker_id" => "zcode-01",
               "worktree" => "/tmp/worktree"
             })

    assert lease["work_order_iri"] == checkpoint["work_order_iri"]
    assert lease["checkpoint_iri"] == checkpoint["checkpoint_iri"]
    assert lease["graph_digest"] == checkpoint["graph_digest"]
    assert lease["repository_identity"] == checkpoint["repository_identity"]
    assert lease["base_sha"] == checkpoint["base_sha"]
    refute Map.has_key?(lease, "standing")
    refute Map.has_key?(lease, "authority")

    assert {:ok, receipt} =
             WorkEnvelope.receipt(checkpoint, %{
               "receipt_iri" => "urn:receipt:1",
               "candidate_sha" => String.duplicate("c", 40),
               "standing" => "BUILD_BROKEN",
               "verifier" => "ash-a2a-dod"
             })

    assert receipt["standing"] == "BUILD_BROKEN"
    assert receipt["work_order_iri"] == checkpoint["work_order_iri"]
    assert receipt["checkpoint_iri"] == checkpoint["checkpoint_iri"]
    assert receipt["repository_identity"] == checkpoint["repository_identity"]
    assert receipt["base_sha"] == checkpoint["base_sha"]
  end

  test "checkpoint refuses incomplete exact work subject identity" do
    {:ok, digest} = CanonicalGraph.canonical_digest(@ttl)
    base = descriptor(digest)

    assert {:error, %{code: :refused_missing_semantic_field, field: "work_order_iri"}} =
             WorkEnvelope.checkpoint(@ttl, Map.delete(base, "work_order_iri"))

    assert {:error, %{code: :refused_invalid_semantic_field, field: "repository_identity"}} =
             WorkEnvelope.checkpoint(@ttl, %{base | "repository_identity" => "ash_a2a"})

    assert {:error, %{code: :refused_invalid_semantic_field, field: "base_sha"}} =
             WorkEnvelope.checkpoint(@ttl, %{base | "base_sha" => "main"})
  end
end
