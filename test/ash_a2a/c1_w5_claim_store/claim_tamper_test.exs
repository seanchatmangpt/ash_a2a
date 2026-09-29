defmodule AshA2A.C1W5ClaimStore.ClaimTamperTest do
  use ExUnit.Case, async: true
  test "claim_tamper" do
    vector=Path.join([File.cwd!(),"priv","sa2a","c1","w5_claim_store_vectors","claim_tamper.json"])
    assert File.read!(vector)=~"\"case\": \"claim_tamper\""
    key=String.duplicate("k",32)
    attrs=%{request_id: "req",effect_id: "eff",prepared_digest: "sha256:prep",subject_digest: "sha256:sub",owner: "owner",issued_at_ms: 1}
    {:ok,claim}=AshA2A.ConsequenceKernel.W5.ClaimAuthenticator.issue(attrs,key)
    assert {:error,:effect_claim_authentication_failed}=AshA2A.ConsequenceKernel.W5.ClaimAuthenticator.verify(%{claim|effect_id: "x"},key)
  end
end
