defmodule AshA2A.C1W5ClaimStore.StandingUnknownTest do
  use ExUnit.Case, async: true

  test "standing_unknown" do
    vector =
      Path.join([
        File.cwd!(),
        "priv",
        "sa2a",
        "c1",
        "w5_claim_store_vectors",
        "standing_unknown.json"
      ])

    assert File.read!(vector) =~ "\"case\": \"standing_unknown\""
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
    replay = AshA2A.ConsequenceKernel.W5.ReplayEvidence.derive(claim)

    assert {:error, :standing_unknown_outcome} =
             AshA2A.ConsequenceKernel.W5.Standing.derive(
               claim,
               [r1],
               replay,
               :unknown_outcome,
               key
             )
  end
end
