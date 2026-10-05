# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C1W5ClaimStore.ReplayMatchTest do
  use ExUnit.Case, async: true

  test "replay_match" do
    vector =
      Path.join([
        File.cwd!(),
        "priv",
        "sa2a",
        "c1",
        "w5_claim_store_vectors",
        "replay_match.json"
      ])

    assert File.read!(vector) =~ "\"case\": \"replay_match\""
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
    r = AshA2A.ConsequenceKernel.W5.ReplayEvidence.derive(claim)
    assert :ok = AshA2A.ConsequenceKernel.W5.ReplayEvidence.verify(claim, r)
  end
end
