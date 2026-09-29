defmodule AshA2A.C1W5ClaimStore.UnknownRetryRefusedTest do
  use ExUnit.Case, async: true
  test "unknown_retry_refused" do
    vector=Path.join([File.cwd!(),"priv","sa2a","c1","w5_claim_store_vectors","unknown_retry_refused.json"])
    assert File.read!(vector)=~"\"case\": \"unknown_retry_refused\""
    assert {:error,:retry_forbidden_until_reconciliation}=AshA2A.ConsequenceKernel.W5.RecoveryGate.retry(:unknown_outcome)
  end
end
