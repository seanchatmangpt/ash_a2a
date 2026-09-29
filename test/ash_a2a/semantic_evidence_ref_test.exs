defmodule AshA2A.Semantic.EvidenceRefTest do
  use ExUnit.Case, async: true

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

  test "admits portable powerless evidence reference" do
    assert {:ok, admitted} = EvidenceRef.admit(ref())
    assert admitted["authority"] == "NONE"
    assert admitted["consequence"] == "EVIDENCE_ONLY"
    assert {:ok, "sha256:" <> digest} = EvidenceRef.digest(admitted)
    assert byte_size(digest) == 64
  end

  test "refuses authority smuggling" do
    assert {:error, %{code: :refused_semantic_evidence, subject: :authority}} =
             EvidenceRef.admit(ref(%{"authority" => "DO"}))
  end

  test "refuses missing replay identity" do
    assert {:error, %{subject: :replay_identity}} =
             EvidenceRef.admit(ref(%{"replayIdentity" => ""}))
  end
end
