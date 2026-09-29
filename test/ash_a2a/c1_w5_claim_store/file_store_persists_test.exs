defmodule AshA2A.C1W5ClaimStore.FileStorePersistsTest do
  use ExUnit.Case, async: true
  test "file_store_persists" do
    vector=Path.join([File.cwd!(),"priv","sa2a","c1","w5_claim_store_vectors","file_store_persists.json"])
    assert File.read!(vector)=~"\"case\": \"file_store_persists\""
    key=String.duplicate("k",32)
    attrs=%{request_id: "req",effect_id: "eff",prepared_digest: "sha256:prep",subject_digest: "sha256:sub",owner: "owner",issued_at_ms: 1}
    {:ok,claim}=AshA2A.ConsequenceKernel.W5.ClaimAuthenticator.issue(attrs,key)
    path=Path.join(System.tmp_dir!(),"sa2a_claim_"<>Integer.to_string(System.unique_integer([:positive]))<>".bin"); {:ok,s}=AshA2A.ConsequenceKernel.W5.EffectClaimStore.File.start_link(path: path); assert :ok=AshA2A.ConsequenceKernel.W5.EffectClaimStore.File.put(s,claim); GenServer.stop(s); {:ok,s2}=AshA2A.ConsequenceKernel.W5.EffectClaimStore.File.start_link(path: path); assert {:ok,c}=AshA2A.ConsequenceKernel.W5.EffectClaimStore.File.fetch(s2,claim.claim_id); assert c.effect_id==claim.effect_id; GenServer.stop(s2); File.rm(path)
  end
end
