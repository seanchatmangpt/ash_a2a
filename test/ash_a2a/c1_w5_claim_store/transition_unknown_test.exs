defmodule AshA2A.C1W5ClaimStore.TransitionUnknownTest do
  use ExUnit.Case, async: true
  test "transition_unknown" do
    vector=Path.join([File.cwd!(),"priv","sa2a","c1","w5_claim_store_vectors","transition_unknown.json"])
    assert File.read!(vector)=~"\"case\": \"transition_unknown\""
    assert :ok=AshA2A.ConsequenceKernel.W5.ClaimTransition.admit(:doing,:unknown_outcome)
  end
end
