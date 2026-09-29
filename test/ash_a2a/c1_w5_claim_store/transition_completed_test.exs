defmodule AshA2A.C1W5ClaimStore.TransitionCompletedTest do
  use ExUnit.Case, async: true
  test "transition_completed" do
    vector=Path.join([File.cwd!(),"priv","sa2a","c1","w5_claim_store_vectors","transition_completed.json"])
    assert File.read!(vector)=~"\"case\": \"transition_completed\""
    assert :ok=AshA2A.ConsequenceKernel.W5.ClaimTransition.admit(:doing,:completed)
  end
end
