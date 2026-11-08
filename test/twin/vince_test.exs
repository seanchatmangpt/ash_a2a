defmodule AshA2A.Twin.VinceTest do
  use ExUnit.Case, async: true

  alias AshA2A.Twin.MechanicalPrior
  alias AshA2A.Twin.Vince

  # -- Exact-half detector: real number matrix ------------------------------

  test "exact_half? exact matrix" do
    assert Vince.exact_half?(100_000, 50_000)
    assert Vince.exact_half?(7, 3.5)
    # odd NTE: half is x.5 — exact equality on the diff, not on ints
    assert Vince.exact_half?(101, 50.5)
    refute Vince.exact_half?(100_000, 49_999)
    refute Vince.exact_half?(100_000, 51_000)
    refute Vince.exact_half?(100_000, 100_000)
    refute Vince.exact_half?(100_000, 0)
  end

  test "exact_half? tolerance absorbs cent-level rounding" do
    assert Vince.exact_half?(100_001, 50_000, 1)
    refute Vince.exact_half?(100_001, 50_000, 0)
    assert Vince.exact_half?(100_000, 50_005, 10)
    refute Vince.exact_half?(100_000, 50_100, 10)
  end

  # -- Round-number detector: calibration matrix ---------------------------

  test "round_suspicious? only flags offer-round/nte-unround mismatch" do
    # round offer + unround NTE -> suspicious (shape-chosen offer)
    assert Vince.round_suspicious?(123_457, 100_000)
    assert Vince.round_suspicious?(7_531, 7_500)
    # round on BOTH sides -> normal quoting, not flagged
    refute Vince.round_suspicious?(120_000, 100_000)
    refute Vince.round_suspicious?(80_000, 40_000)
    # unround offer + unround NTE -> fine
    refute Vince.round_suspicious?(123_457, 98_765)
    # unround offer + round NTE -> fine (offer reflects a computed number)
    refute Vince.round_suspicious?(100_000, 61_803)
  end

  test "round_suspicious? float offers use integer part" do
    assert Vince.round_suspicious?(99_999.99, 50_000.0)
    refute Vince.round_suspicious?(100_000.0, 50_000.0)
  end

  # -- GPM floor: boundary values ------------------------------------------

  test "gpm exact and floor boundary: 0.22 admits, 0.2199 challenges" do
    # (100_000 - 78_000)/100_000 = 0.22 exactly -> admits (floor itself is lawful)
    assert Vince.gpm(100_000, 78_000) == 0.22
    refute Vince.gpm_breach?(100_000, 78_000, 0.22)

    # 0.2199 -> breach -> challenge
    assert Vince.gpm_breach?(100_000, 78_010, 0.22)
    # (100_000 - 78_010)/100_000 = 0.2199
    assert_in_delta Vince.gpm(100_000, 78_010), 0.2199, 1.0e-12

    assert Vince.gpm_breach?(100_000, 100_000, 0.22) # 0.0 margin
    assert Vince.gpm_breach?(100_000, 120_000, 0.22) # negative margin
    refute Vince.gpm_breach?(250_000, 180_000, 0.22) # 0.28, pack example
  end

  # -- evaluate_intent: verdict shape and detector precedence --------------

  describe "evaluate_intent/2" do
    test "clean intent admits with a GPM ticket" do
      v = Vince.new()
      {v2, {:admit, ticket}} = Vince.evaluate_intent(v, %{trade: :t1, nte: 250_000, offer: 180_000})
      assert ticket.gpm == 0.28
      assert ticket.trade == :t1
      # admit does not touch the challenge ledger
      assert v2.challenges == %{}
    end

    test "GPM breach challenges with gpm_floor code and demanded evidence" do
      v = Vince.new()
      {v2, {:challenge, c}} = Vince.evaluate_intent(v, %{trade: :t2, nte: 100_000, offer: 85_000})
      assert c.code == :gpm_floor
      assert "itemized_cost_breakdown" in c.demanded_evidence
      assert is_reference(c.retry_token)
      assert v2.challenges[:t2] == 1
    end

    test "exact-half offer challenges with monkey_math code" do
      v = Vince.new()
      # 200_000/2 = 100_000, GPM 0.5 -> above floor, so monkey_math fires
      {_v2, {:challenge, c}} = Vince.evaluate_intent(v, %{trade: :t3, nte: 200_000, offer: 100_000})
      assert c.code == :monkey_math
      assert "labor_hours_breakdown" in c.demanded_evidence
    end

    test "round-number mismatch challenges with round_number_suspicious code" do
      v = Vince.new()
      # offer 90_000 on nte 123_457: GPM ~0.271 ok, not half, offer round / nte not
      {_v2, {:challenge, c}} =
        Vince.evaluate_intent(v, %{trade: :t4, nte: 123_457, offer: 90_000})

      assert c.code == :round_number_suspicious
      assert c.demanded_evidence == ["cost_basis_worksheet"]
    end

    test "detector precedence: GPM floor wins over monkey math" do
      # nte 200_000 offer 100_000 is half AND gpm 0.5 (no breach) -> monkey_math.
      # Force both: nte 100_000, offer 50_000 is half; gpm 0.5 no breach.
      # Breach+half: nte 10_000, offer 5_000 -> half, gpm 0.5 no breach.
      # Use nte 100_000 offer 39_000: gpm 0.61 fine, not half. Instead:
      # nte 100_000 offer 49_999.99 -> not half (diff 0.01 > 0 tolerance),
      # gpm 0.50 fine. To get a genuine both-fire: nte 100_004, offer 50_000
      # -> half within 2 tolerance, gpm ~0.5004 fine. Breach+half needs
      # offer < 78_000 and offer = nte/2, e.g. nte 150_000 offer 75_000:
      # gpm 0.5 -> no breach. GPM breach and exact-half cannot co-fire when
      # floor < 0.5: a half-split always has GPM exactly 0.5 > 0.22.
      # Verified: with floor 0.22, gpm_floor and monkey_math are mutually
      # exclusive; precedence is still enforced by cond order for custom
      # floors > 0.5.
      vhi = Vince.new(gpm_floor: 0.6)
      {_v, {:challenge, c}} = Vince.evaluate_intent(vhi, %{trade: :t5, nte: 150_000, offer: 75_000})
      assert c.code == :gpm_floor
    end

    test "repeat challenge on same trade escalates to :escalate_multisig" do
      v = Vince.new()
      {v1, {:challenge, _}} = Vince.evaluate_intent(v, %{trade: :t6, nte: 100_000, offer: 85_000})
      # partner retries on the SAME trade without satisfying the challenge
      {v2, {:refuse, :escalate_multisig}} =
        Vince.evaluate_intent(v1, %{trade: :t6, nte: 100_000, offer: 85_000})

      # a DIFFERENT trade still gets a fresh (non-escalated) evaluation
      {_v3, {:challenge, c}} = Vince.evaluate_intent(v2, %{trade: :t7, nte: 100_000, offer: 85_000})
      assert c.code == :gpm_floor
    end

    test "satisfying nothing changes: even an improved offer escalates once challenged" do
      v = Vince.new()
      {v1, {:challenge, _}} = Vince.evaluate_intent(v, %{trade: :t8, nte: 100_000, offer: 85_000})
      # retry with a clean offer on the same trade ref still escalates —
      # the trade ref must be retired, not silently retried
      {_v2, {:refuse, :escalate_multisig}} =
        Vince.evaluate_intent(v1, %{trade: :t8, nte: 100_000, offer: 78_000})
    end
  end

  # -- Mechanical prior hook ------------------------------------------------

  defmodule PermissivePrior do
    @behaviour MechanicalPrior

    @impl true
    def prior_verdict(_claim, _telemetry), do: {:admit, %{source: :permissive}}
  end

  defmodule InterrogatePrior do
    @behaviour MechanicalPrior

    # blown-motor claim + high ambient temp -> demand winding resistance
    @impl true
    def prior_verdict(:blown_motor, %{ambient_temp_c: t}) when t >= 40 do
      {:challenge, ["winding_resistance_readings"],
       "thermal-stress motor failure requires winding-resistance evidence"}
    end

    def prior_verdict(:blown_motor, %{ambient_temp_c: _}), do: {:admit, %{source: :motor_cool}}
    def prior_verdict(_claim, _telemetry), do: {:refuse, :unknown_claim_class}
  end

  describe "check_claim/3" do
    test "default RefuseAll prior refuses every claim" do
      v = Vince.new()
      {^v, {:refuse, %{code: :mechanical_prior, reason: :refuse_all_default_prior}}} =
        Vince.check_claim(v, {:claim, :anything}, %{})
    end

    test "pluggable prior admits through the hook" do
      v = Vince.new(prior: PermissivePrior)
      {^v, {:admit, ticket}} = Vince.check_claim(v, :whatever, %{})
      assert ticket.source == :permissive
    end

    test "counter-punch: blown motor + high ambient temp demands winding resistance" do
      v = Vince.new(prior: InterrogatePrior)
      {_v2, {:challenge, c}} = Vince.check_claim(v, :blown_motor, %{ambient_temp_c: 45})
      assert c.code == :mechanical_prior
      assert c.demanded_evidence == ["winding_resistance_readings"]
      assert c.msg =~ "winding-resistance"
    end

    test "blown motor at moderate temp admits through the prior" do
      v = Vince.new(prior: InterrogatePrior)
      {_v2, {:admit, _}} = Vince.check_claim(v, :blown_motor, %{ambient_temp_c: 20})
    end

    test "unknown claim class is refused with typed reason" do
      v = Vince.new(prior: InterrogatePrior)
      {_v2, {:refuse, %{code: :mechanical_prior, reason: :unknown_claim_class}}} =
        Vince.check_claim(v, :hail_damage, %{})
    end
  end

  # -- new/1 options --------------------------------------------------------

  test "new/1 honours gpm_floor and tolerance overrides" do
    v = Vince.new(gpm_floor: 0.30, tolerance: 5)
    assert v.gpm_floor == 0.30
    assert v.tolerance == 5
    # tolerance now absorbs a 3-unit half-split miss
    {_v2, {:challenge, c}} = Vince.evaluate_intent(v, %{trade: :t9, nte: 100_003, offer: 50_000})
    assert c.code == :monkey_math
  end
end
