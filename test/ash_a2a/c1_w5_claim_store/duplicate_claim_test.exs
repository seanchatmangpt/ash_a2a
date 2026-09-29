defmodule AshA2A.C1W5ClaimStore.DuplicateClaimTest do
  use ExUnit.Case, async: true
  test "duplicate_claim" do
    vector=Path.join([File.cwd!(),"priv","sa2a","c1","w5_claim_store_vectors","duplicate_claim.json"])
    assert File.read!(vector)=~"\"case\": \"duplicate_claim\""
    key=String.duplicate("k",32)
    attrs=%{request_id: "req",effect_id: "eff",prepared_digest: "sha256:prep",subject_digest: "sha256:sub",owner: "owner",issued_at_ms: 1}
    {:ok,claim}=AshA2A.ConsequenceKernel.W5.ClaimAuthenticator.issue(attrs,key)
    {:ok,s}=AshA2A.ConsequenceKernel.W5.EffectClaimStore.Memory.start_link(); assert :ok=AshA2A.ConsequenceKernel.W5.EffectClaimStore.Memory.put(s,claim); assert {:error,:effect_claim_duplicate}=AshA2A.ConsequenceKernel.W5.EffectClaimStore.Memory.put(s,claim)
  end
end
