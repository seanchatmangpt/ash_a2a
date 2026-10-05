# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

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
