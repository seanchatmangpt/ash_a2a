defmodule AshA2A.Gall.Closure.EvidencePolicyTest do
  use ExUnit.Case, async: true
  alias AshA2A.Gall.Closure.EvidencePolicy

  test "evidence class and digest remain independently admitted" do
    digest = "sha256:" <> String.duplicate("a", 64)
    candidate = %{evidence_digest: digest, finding_class: "conformance"}
    assert {:ok, ^candidate} = EvidencePolicy.admit(candidate, [digest])

    assert {:error, {:refused_gall, :evidence_policy, :unadmitted_evidence}} =
             EvidencePolicy.admit(candidate, [])
  end
end
