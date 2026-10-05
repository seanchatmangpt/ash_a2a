# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C1W5ClaimStore.ClaimAuthenticateTest do
  use ExUnit.Case, async: true

  test "claim_authenticate" do
    vector =
      Path.join([
        File.cwd!(),
        "priv",
        "sa2a",
        "c1",
        "w5_claim_store_vectors",
        "claim_authenticate.json"
      ])

    assert File.read!(vector) =~ "\"case\": \"claim_authenticate\""
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
    assert :ok = AshA2A.ConsequenceKernel.W5.ClaimAuthenticator.verify(claim, key)
  end
end
