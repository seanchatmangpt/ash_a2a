defmodule AshA2A.DfCM.StandingProjectionSourceTest do
  use ExUnit.Case, async: true

  @contract "priv/ggen/ash_a2a/dfcm/standing_projection_contract.ttl"
  @query "priv/ggen/ash_a2a/dfcm/queries/fleet_donors.rq"

  test "one standing contract names materially distinct consumers without granting runtime authority" do
    source = File.read!(@contract)

    for consumer <- ~w(graphlaw affidavit castle xaas) do
      assert source =~ "dfcm:#{consumer} dfcm:requiresStandingContract dfcm:standingProjectionV1"
    end

    assert source =~ ~s(dfcm:technicalStanding "REQUIRED")
    assert source =~ ~s(dfcm:externalStanding "UNSPECIFIED")
    assert source =~ ~s(dfcm:runtimeAuthority "NONE")
    assert source =~ "dfcm:requiresExactSubject true"
    assert source =~ "dfcm:requiresFrozenClosure true"
    assert source =~ "dfcm:requiresReceiptReplayBinding true"
  end

  test "generator query projects the standing binding instead of asking consumers to reconstruct it" do
    query = File.read!(@query)

    for variable <- ~w(
      standing_contract standing_subject technical_standing external_standing runtime_authority
      requires_exact_subject requires_frozen_closure requires_receipt_replay_binding
    ) do
      assert query =~ "?#{variable}"
    end

    assert query =~ "dfcm:requiresStandingContract ?standing_contract"
    assert query =~ "dfcm:standingSubject ?standing_subject"
  end
end
