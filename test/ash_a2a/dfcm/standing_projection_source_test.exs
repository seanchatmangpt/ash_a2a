defmodule AshA2A.DfCM.StandingProjectionSourceTest do
  use ExUnit.Case, async: true

  @contract "priv/ggen/ash_a2a/dfcm/standing_projection_contract.ttl"
  @query "priv/ggen/ash_a2a/dfcm/queries/fleet_donors.rq"

  test "one exact standing contract is source-bound to four fleet consumers" do
    ttl = File.read!(@contract)

    assert ttl =~ "seanchatmangpt/ash_a2a@d02bab5d1d5ec331433ce64cc3c0cc3125e21937"
    assert ttl =~ ~s(dfcm:technicalStanding "REQUIRED")
    assert ttl =~ ~s(dfcm:externalStanding "UNSPECIFIED")
    assert ttl =~ ~s(dfcm:runtimeAuthority "NONE")

    for consumer <- ~w(graphlaw affidavit castle xaas) do
      assert ttl =~ "dfcm:#{consumer} dfcm:requiresStandingContract dfcm:standingProjectionV1"
    end
  end

  test "generator query carries standing contract without reconstructing it in consumers" do
    query = File.read!(@query)

    for field <- ~w(standing_contract standing_subject technical_standing external_standing runtime_authority requires_exact_subject requires_frozen_closure requires_receipt_replay_binding) do
      assert query =~ "?#{field}"
    end

    assert query =~ "?donor dfcm:requiresStandingContract ?standing_contract"
    assert query =~ "?standing_contract dfcm:standingSubject ?standing_subject"
  end
end
