# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C1W5ClaimStore.StandingCompleteTest do
  use ExUnit.Case, async: true

  test "standing_complete" do
    vector =
      Path.join([
        File.cwd!(),
        "priv",
        "sa2a",
        "c1",
        "w5_claim_store_vectors",
        "standing_complete.json"
      ])

    assert File.read!(vector) =~ "\"case\": \"standing_complete\""
    key = String.duplicate("k", 32)

    attrs = %{
      request_id: "req",
      effect_id: "eff",
      prepared_digest: "sha256:prep",
      subject_digest: "sha256:sub",
      owner: "owner",
      issued_at_ms: 1
    }

    {:ok, claim} = AshA2A.ConsequenceKernel.W5.ClaimAuthenticator.issue(attrs, key)
    {:ok, r1} = AshA2A.ConsequenceKernel.W5.ClaimReceipt.build(claim, :claimed)
    {:ok, r2} = AshA2A.ConsequenceKernel.W5.ClaimReceipt.build(claim, :doing, r1["chain_digest"])
    replay = AshA2A.ConsequenceKernel.W5.ReplayEvidence.derive(claim)

    assert {:ok, :evidenced} =
             AshA2A.ConsequenceKernel.W5.Standing.derive(claim, [r1, r2], replay, :completed, key)
  end
end
