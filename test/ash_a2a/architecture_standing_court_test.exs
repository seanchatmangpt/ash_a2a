# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Architecture.StandingCourtTest do
  use ExUnit.Case, async: true
  alias AshA2A.Architecture.StandingCourt

  @sha String.duplicate("a", 64)
  @contract String.duplicate("b", 64)
  @candidate String.duplicate("c", 64)
  @qualification String.duplicate("d", 64)
  @observer String.duplicate("e", 64)

  defp claim do
    %{
      repository: "seanchatmangpt/ash_a2a",
      commit: @sha,
      contract_digest: @contract,
      candidate_digest: @candidate
    }
  end

  defp evidence do
    %{
      repository: "seanchatmangpt/ash_a2a",
      commit: @sha,
      contract_digest: @contract,
      candidate_digest: @candidate,
      qualification_digest: @qualification,
      observer_digest: @observer
    }
  end

  test "TTL is executable policy and authority ceiling is NONE" do
    p = StandingCourt.policy()
    assert p.authority == "NONE"
    assert MapSet.new(~w(UNKNOWN REFUSED ADMITTED)) |> MapSet.subset?(p.states)
  end

  test "complete independently observed exact-subject evidence is admitted and replays" do
    receipt = StandingCourt.judge(claim(), evidence())
    assert receipt.standing == :admitted
    assert receipt.authority == "NONE"
    assert receipt.exact_subject == "seanchatmangpt/ash_a2a@" <> @sha
    assert :ok == StandingCourt.replay(claim(), evidence(), receipt)
  end

  test "missing independent evidence remains UNKNOWN" do
    receipt = StandingCourt.judge(claim(), Map.delete(evidence(), :observer_digest))
    assert receipt.standing == :unknown
    assert {:missing_evidence, "observer_digest"} in receipt.reasons
  end

  test "stale commit and cross-subject reuse are REFUSED" do
    stale = Map.put(evidence(), :commit, String.duplicate("f", 64))
    cross = Map.put(evidence(), :repository, "seanchatmangpt/not-ash_a2a")
    assert StandingCourt.judge(claim(), stale).standing == :refused
    assert StandingCourt.judge(claim(), cross).standing == :refused
  end

  test "malformed and self-attested qualification are REFUSED" do
    malformed = Map.put(evidence(), :qualification_digest, "not-a-digest")
    forged = Map.put(evidence(), :self_attested_qualification, true)
    assert StandingCourt.judge(claim(), malformed).standing == :refused
    assert StandingCourt.judge(claim(), forged).standing == :refused
  end

  test "observer must be independent of qualification" do
    laundering = Map.put(evidence(), :observer_digest, @qualification)
    receipt = StandingCourt.judge(claim(), laundering)
    assert receipt.standing == :refused
    assert {:forbidden_evidence, "non_independent_observer"} in receipt.reasons
  end

  test "receipt mutation and evidence drift fail deterministic replay" do
    receipt = StandingCourt.judge(claim(), evidence())
    forged = %{receipt | authority: "DO"}
    assert {:error, :replay_divergence} == StandingCourt.replay(claim(), evidence(), forged)

    drifted = Map.put(evidence(), :observer_digest, String.duplicate("9", 64))
    assert {:error, :replay_divergence} == StandingCourt.replay(claim(), drifted, receipt)
  end

  test "map key order does not change deterministic receipt" do
    reversed = evidence() |> Enum.reverse() |> Map.new()
    assert StandingCourt.judge(claim(), evidence()) == StandingCourt.judge(claim(), reversed)
  end
end
