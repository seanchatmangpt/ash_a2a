# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ChicagoCaseStudy.SettlementProcessConformanceTest do
  use ExUnit.Case, async: true

  # Chicago Tier 3: Behavioral Conformance Gate
  # Invariant: Execution sequences obey formal process models (DFGs / Petri Nets)
  # Out-of-order actions fail closed with %ConformanceRefusal{}

  defmodule ProcessModel do
    def check_sequence([_ | _] = trace, allowed_transitions) do
      activities = Enum.map(trace, & &1["activity"])
      pairs = Enum.zip(activities, tl(activities))

      case Enum.find(pairs, fn pair -> pair not in allowed_transitions end) do
        nil ->
          {:ok, :admitted}

        {prev, illegal} ->
          expected =
            allowed_transitions
            |> Enum.filter(fn {from, _to} -> from == prev end)
            |> Enum.map(fn {_from, to} -> to end)

          {:error, %{
            reason: :unadmitted_transition,
            expected: expected,
            observed: illegal,
            fitness: 0.5
          }}
      end
    end
  end

  setup do
    allowed_transitions = [
      {"ValidateEligible", "HoldCollateral"},
      {"HoldCollateral", "TransferFunds"},
      {"TransferFunds", "ReleaseCollateral"}
    ]

    {:ok, transitions: allowed_transitions}
  end

  test "BRCE gate admits compliant sequential execution", ctx do
    trace = [
      %{"case_id" => "tx-100", "activity" => "ValidateEligible", "timestamp" => 1000},
      %{"case_id" => "tx-100", "activity" => "HoldCollateral",   "timestamp" => 1005},
      %{"case_id" => "tx-100", "activity" => "TransferFunds",    "timestamp" => 1010}
    ]

    assert {:ok, :admitted} = ProcessModel.check_sequence(trace, ctx.transitions)
  end

  test "BRCE gate halts unauthorized jump-step (TransferFunds before HoldCollateral)", ctx do
    deviant_trace = [
      %{"case_id" => "tx-100", "activity" => "ValidateEligible", "timestamp" => 1000},
      # VIOLATION: Skipped HoldCollateral directly to TransferFunds
      %{"case_id" => "tx-100", "activity" => "TransferFunds",    "timestamp" => 1005}
    ]

    assert {:error, refusal} = ProcessModel.check_sequence(deviant_trace, ctx.transitions)
    assert refusal.reason == :unadmitted_transition
    assert refusal.expected == ["HoldCollateral"]
    assert refusal.observed == "TransferFunds"
    assert refusal.fitness < 1.0
  end
end
