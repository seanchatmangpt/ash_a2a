defmodule AshA2A.C1W5ClaimStore.ReconciledRetryTest do
  use ExUnit.Case, async: true

  test "reconciled_retry" do
    vector =
      Path.join([
        File.cwd!(),
        "priv",
        "sa2a",
        "c1",
        "w5_claim_store_vectors",
        "reconciled_retry.json"
      ])

    assert File.read!(vector) =~ "\"case\": \"reconciled_retry\""
    assert :ok = AshA2A.ConsequenceKernel.W5.RecoveryGate.retry(:reconciled_not_applied)
  end
end
