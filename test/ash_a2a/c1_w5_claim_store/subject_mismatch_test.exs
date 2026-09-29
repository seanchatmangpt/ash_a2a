defmodule AshA2A.C1W5ClaimStore.SubjectMismatchTest do
  use ExUnit.Case, async: true
  test "subject_mismatch" do
    vector=Path.join([File.cwd!(),"priv","sa2a","c1","w5_claim_store_vectors","subject_mismatch.json"])
    assert File.read!(vector)=~"\"case\": \"subject_mismatch\""
    p=%{prepared_digest: "sha256:prep",instance: %{subject_digest: "sha256:sub"}}; c=%{prepared_digest: "sha256:other",subject_digest: "sha256:sub"}; assert {:error,:effect_claim_exact_subject_mismatch}=AshA2A.ConsequenceKernel.W5.ClaimSubject.bind(p,c)
  end
end
