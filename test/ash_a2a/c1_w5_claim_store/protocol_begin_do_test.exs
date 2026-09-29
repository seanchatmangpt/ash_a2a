defmodule AshA2A.C1W5ClaimStore.ProtocolBeginDoTest do
  use ExUnit.Case, async: true
  test "protocol_begin_do" do
    vector=Path.join([File.cwd!(),"priv","sa2a","c1","w5_claim_store_vectors","protocol_begin_do.json"])
    assert File.read!(vector)=~"\"case\": \"protocol_begin_do\""
    key=String.duplicate("k",32); {:ok,s}=AshA2A.ConsequenceKernel.W5.EffectClaimStore.Memory.start_link(); p=%{prepared_digest: "sha256:prep",instance: %{request_id: "req",effect_id: "eff",subject_digest: "sha256:sub"}}; opts=[claim_store: AshA2A.ConsequenceKernel.W5.EffectClaimStore.Memory,claim_store_handle: s,claim_key: key]; {:ok,ctx}=AshA2A.ConsequenceKernel.W5.ClaimProtocol.claim(p,"owner",opts); assert :ok=AshA2A.ConsequenceKernel.W5.ClaimProtocol.begin_do(ctx); assert {:ok,c}=AshA2A.ConsequenceKernel.W5.EffectClaimStore.Memory.fetch(s,ctx.claim_id); assert c.state==:doing
  end
end
