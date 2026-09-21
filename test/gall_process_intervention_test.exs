defmodule AshA2A.Gall.ProcessInterventionTest do
  use ExUnit.Case, async: true

  alias AshA2A.Gall.ProcessIntervention

  defp finding(overrides \\ %{}) do
    Map.merge(
      %{
        producer_sha: String.duplicate("a", 40),
        evidence_digest: "sha256:" <> String.duplicate("b", 64),
        semantic_subject_digest: "sha256:" <> String.duplicate("c", 64),
        finding_class: "conformance",
        horizon: "FAST",
        vocabulary: "https://w3id.org/ocel",
        requested_capability_id: "Example.Resource.change"
      },
      overrides
    )
  end

  test "GALL-029 admits evidence as authority-free candidate" do
    assert {:ok, candidate} =
             ProcessIntervention.admit(finding(),
               allowed_producers: [String.duplicate("a", 40)],
               public_vocabulary: ["https://w3id.org/ocel"]
             )

    assert candidate.authority == :none
    assert candidate.finding_class == "conformance"
    assert candidate.horizon == "FAST"
    assert String.starts_with?(candidate.candidate_digest, "sha256:")
  end

  test "prediction cannot self-promote and secrets fail closed" do
    assert {:ok, candidate} =
             ProcessIntervention.admit(finding(%{finding_class: "prediction"}))

    assert candidate.finding_class == "prediction"
    assert candidate.authority == :none

    assert {:error, :secret_bearing_finding} =
             ProcessIntervention.admit(Map.put(finding(), :authorization, "Bearer abc"))
  end

  test "stale producer and private vocabulary refuse" do
    assert {:error, :stale_or_unadmitted_producer} =
             ProcessIntervention.admit(finding(), allowed_producers: [String.duplicate("d", 40)])

    assert {:error, :private_or_unknown_vocabulary} =
             ProcessIntervention.admit(finding(),
               public_vocabulary: ["https://example.org/public"]
             )
  end
end
