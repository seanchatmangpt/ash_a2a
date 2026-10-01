defmodule AshA2A.DfCM.CanonicalStandingProjectionTest do
  use ExUnit.Case, async: true
  @ontology "priv/ggen/ash_a2a/dfcm/ontology.ttl"
  @projection_query "priv/ggen/ash_a2a/dfcm/queries/standing_release_donor.rq"

  test "standing release has one canonical semantic owner" do
    ontology = File.read!(@ontology)
    assert ontology =~ "graphlaw_standing_release"
    assert ontology =~ ~s(dfcm:technicalStanding "QUALIFIED")
    assert ontology =~ ~s(dfcm:externalStanding "UNSPECIFIED")
    assert ontology =~ ~s(dfcm:runtimeAuthority "NONE")
    assert ontology =~ ~s(dfcm:requiresExactSubject true)
    assert ontology =~ ~s(dfcm:requiresReleaseBinding true)
    assert ontology =~ ~s(dfcm:requiresFrozenClosure true)
    assert ontology =~ ~s(dfcm:requiresReceiptReplayBinding true)
    refute File.exists?("priv/ggen/ash_a2a/dfcm/standing_projection_contract.ttl")
  end

  test "native query projects complete standing binding" do
    query = File.read!(@projection_query)
    for variable <- ~w(?standing_source ?technical_standing ?external_standing ?runtime_authority ?requires_exact_subject ?requires_release_binding ?requires_frozen_closure ?requires_receipt_replay_binding) do
      assert query =~ variable
    end
  end
end
