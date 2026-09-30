defmodule AshA2A.Semantic.EvidenceRefTest do
  use ExUnit.Case, async: true

  alias AshA2A.Identity.Canonical
  alias AshA2A.Semantic.EvidenceRef

  defp ref(overrides \\ %{}) do
    Map.merge(
      %{
        "schema" => "sa2a.semantic-evidence-envelope.v1",
        "contractVersion" => "v26.9.29",
        "subject" => "urn:customer:42",
        "sourceDigest" => "sha256:" <> String.duplicate("a", 64),
        "graphDigest" => "sha256:" <> String.duplicate("b", 64),
        "replayIdentity" => "replay:customer:42",
        "envelopeDigest" => "sha256:" <> String.duplicate("c", 64),
        "authority" => "NONE",
        "consequence" => "EVIDENCE_ONLY"
      },
      overrides
    )
  end

  defp exact_ref(overrides \\ %{}) do
    body =
      %{
        "schema" => "sa2a.semantic-evidence-envelope.v1",
        "contractVersion" => "v26.9.29",
        "canonicalization" => "RDFC-1.0",
        "authority" => "NONE",
        "consequence" => "EVIDENCE_ONLY",
        "subject" => "urn:customer:42",
        "source" => %{
          "id" => "customer",
          "uri" => "urn:source:customer",
          "graph" => "urn:graph:customer",
          "subjectTemplate" => "https://example.org/customer/{id}",
          "version" => "1",
          "digest" => "sha256:" <> String.duplicate("a", 64)
        },
        "graphDigest" => "sha256:" <> String.duplicate("b", 64),
        "replayIdentity" => "replay:customer:42",
        "receiptDigest" => nil,
        "provenance" => %{
          "producer" => "ash_r2rml",
          "producerVersion" => "26.9.29",
          "graphlawContractCommit" => "4e4873ca377d50af5268e8736be4afe6badeb862",
          "sourceIdentityDigest" => "sha256:" <> String.duplicate("a", 64)
        }
      }
      |> deep_merge(overrides)

    Map.put(body, "envelopeDigest", producer_digest(body))
  end

  defp producer_digest(body) do
    if Code.ensure_loaded?(AshR2RML.VKG.Serializer) and
         function_exported?(AshR2RML.VKG.Serializer, :digest, 1) do
      "sha256:" <> apply(AshR2RML.VKG.Serializer, :digest, [body])
    else
      {:ok, canonical} = Canonical.encode(body)

      "sha256:" <>
        (:crypto.hash(:sha256, ["ashr2rml.vkg.canonical.v1\n", canonical])
         |> Base.encode16(case: :lower))
    end
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, l, r ->
      if is_map(l) and is_map(r), do: deep_merge(l, r), else: r
    end)
  end

  test "admits portable powerless evidence reference" do
    assert {:ok, admitted} = EvidenceRef.admit(ref())
    assert admitted["authority"] == "NONE"
    assert admitted["consequence"] == "EVIDENCE_ONLY"
    assert {:ok, "sha256:" <> digest} = EvidenceRef.digest(admitted)
    assert byte_size(digest) == 64
  end

  test "admits current AshR2RML exact-source envelope and preserves exact identity" do
    envelope = exact_ref()

    assert {:ok, admitted} = EvidenceRef.admit(envelope)
    assert admitted == envelope
    assert admitted["canonicalization"] == "RDFC-1.0"
    assert admitted["source"]["digest"] == "sha256:" <> String.duplicate("a", 64)
    assert admitted["provenance"]["producer"] == "ash_r2rml"
  end

  test "exact-source envelope mutation invalidates the replayable envelope digest" do
    envelope = exact_ref()
    mutated = %{envelope | "subject" => "urn:customer:43"}

    assert {:error,
            %{
              code: :refused_semantic_evidence,
              subject: :envelope_digest,
              evidence: %{reason: :replay_mismatch}
            }} = EvidenceRef.admit(mutated)
  end

  test "exact-source envelope refuses incomplete source identity and hidden top-level fields" do
    source_missing_graph = exact_ref(%{"source" => %{"graph" => nil}})

    assert {:error, %{subject: :source}} = EvidenceRef.admit(source_missing_graph)

    with_hidden_authority = Map.put(exact_ref(), "runtimeAuthority", "DO")
    assert {:error, %{subject: :shape}} = EvidenceRef.admit(with_hidden_authority)
  end

  test "refuses authority smuggling" do
    assert {:error, %{code: :refused_semantic_evidence, subject: :authority}} =
             EvidenceRef.admit(ref(%{"authority" => "DO"}))

    assert {:error, %{code: :refused_semantic_evidence, subject: :authority}} =
             EvidenceRef.admit(exact_ref(%{"authority" => "DO"}))
  end

  test "refuses missing replay identity" do
    assert {:error, %{subject: :replay_identity}} =
             EvidenceRef.admit(ref(%{"replayIdentity" => ""}))
  end
end
