defmodule AshA2A.Strain.TensorTest do
  use ExUnit.Case, async: true

  alias AshA2A.Strain.Tensor

  describe "circadian decay curve (shift_hours_continuous)" do
    test "numerically asserted values: 0h, 4h, 8h" do
      t0 = Tensor.new(%{shift_hours_continuous: 0})
      t4 = Tensor.new(%{shift_hours_continuous: 4})
      t8 = Tensor.new(%{shift_hours_continuous: 8})

      assert Tensor.strain(t0, :shift_hours_continuous) == 0.0
      # 1 - exp(-4/4) = 0.6321...
      assert_in_delta Tensor.strain(t4, :shift_hours_continuous), 0.6321, 0.0005
      # 1 - exp(-8/4) = 0.8646...
      assert_in_delta Tensor.strain(t8, :shift_hours_continuous), 0.8646, 0.0005
    end

    test "monotonic within shift" do
      strains =
        for half_hour <- 0..16 do
          h = half_hour * 0.5

          h
          |> then(&Tensor.new(%{shift_hours_continuous: &1}))
          |> Tensor.strain(:shift_hours_continuous)
        end

      assert strains == Enum.sort(strains)
    end

    test "reset at shift boundary via caller passing 0" do
      mid_shift = Tensor.new(%{shift_hours_continuous: 10})
      reset = Tensor.update(mid_shift, %{shift_hours_continuous: 0})

      assert Tensor.strain(mid_shift, :shift_hours_continuous) > 0.9
      assert Tensor.strain(reset, :shift_hours_continuous) == 0.0
    end
  end

  describe "per-dimension normalization" do
    test "active_leases: count/12, capped" do
      assert Tensor.new(%{active_leases: 6}) |> Tensor.strain(:active_leases) == 0.5
      assert Tensor.new(%{active_leases: 24}) |> Tensor.strain(:active_leases) == 1.0
    end

    test "error_rate: identity, clamped" do
      assert Tensor.new(%{error_rate: 0.17}) |> Tensor.strain(:error_rate) == 0.17
      assert Tensor.new(%{error_rate: 1.5}) |> Tensor.strain(:error_rate) == 1.0
    end

    test "heuristic_frequency: count/10" do
      assert Tensor.new(%{heuristic_frequency: 5}) |> Tensor.strain(:heuristic_frequency) == 0.5
      assert Tensor.new(%{heuristic_frequency: 10}) |> Tensor.strain(:heuristic_frequency) == 1.0
    end

    test "attestation_age_sec: age/3600" do
      assert Tensor.new(%{attestation_age_sec: 1800}) |> Tensor.strain(:attestation_age_sec) ==
               0.5

      assert Tensor.new(%{attestation_age_sec: 7200}) |> Tensor.strain(:attestation_age_sec) ==
               1.0
    end

    test "financial_risk_exposure: exposure/50_000" do
      assert Tensor.new(%{financial_risk_exposure: 25_000})
             |> Tensor.strain(:financial_risk_exposure) == 0.5

      assert Tensor.new(%{financial_risk_exposure: 100_000})
             |> Tensor.strain(:financial_risk_exposure) == 1.0
    end

    test "unknown dimension raises" do
      assert_raise ArgumentError, ~r/unknown strain dimension/, fn ->
        Tensor.new(%{vibes: 1})
      end
    end
  end

  describe "hyperplane_check/2 (saturation gate)" do
    test "zero tensor is :ok" do
      assert Tensor.new(%{}) |> Tensor.hyperplane_check() == :ok
    end

    test "weighted sum above 0.7 breaches with reason" do
      # 0.30*0.865 (8h) + 0.25*1.0 (12+ leases) + 0.20*0.5 = 0.2595+0.25+0.10 = 0.6095 < 0.7
      below =
        Tensor.new(%{
          shift_hours_continuous: 8,
          active_leases: 12,
          error_rate: 0.5,
          heuristic_frequency: 0,
          attestation_age_sec: 0,
          financial_risk_exposure: 0
        })

      assert Tensor.hyperplane_check(below) == :ok

      above =
        Tensor.update(below, %{error_rate: 0.9})
        # +0.30*0.15 more -> 0.6545... push leases to saturation too
        |> Tensor.update(%{active_leases: 24})

      # leases strain still 1.0; error now 0.9*0.20=0.18 -> 0.2595+0.25+0.18=0.6895 < 0.7

      assert Tensor.hyperplane_check(above) == :ok

      breach =
        Tensor.update(above, %{heuristic_frequency: 10})

      # +0.10*1.0 -> 0.7895 > 0.7

      assert {:breach, {:saturation_gate, total, 0.7}} = Tensor.hyperplane_check(breach)
      assert_in_delta total, 0.7895, 0.0005
    end

    test "gate list halts on first breach" do
      saturated = Tensor.new(%{heuristic_frequency: 10, attestation_age_sec: 7200})
      # 0.10*1.0 + 0.05*1.0 = 0.15 -> saturation ok, but gate list works mechanically
      assert Tensor.hyperplane_check(saturated, [:saturation_gate]) == :ok
    end
  end

  describe "validation and typed errors" do
    test "new/update reject negative and non-number values" do
      for bad <- [-1, "3", nil, :x] do
        assert_raise ArgumentError, ~r/non-negative number/, fn ->
          Tensor.new(%{active_leases: bad})
        end

        assert_raise ArgumentError, ~r/non-negative number/, fn ->
          Tensor.update(Tensor.new(%{}), %{error_rate: bad})
        end
      end
    end

    test "update rejects unknown dimension" do
      assert_raise ArgumentError, ~r/unknown strain dimension/, fn ->
        Tensor.update(Tensor.new(%{}), %{vibes: 1})
      end
    end

    test "strain/2 on unknown dimension is a typed ArgumentError" do
      assert_raise ArgumentError, ~r/unknown strain dimension: :vibes/, fn ->
        Tensor.strain(Tensor.new(%{}), :vibes)
      end
    end

    test "strain/2 on a corrupted stored value raises typed" do
      assert_raise ArgumentError, ~r/non-negative number/, fn ->
        Tensor.strain(%{active_leases: -4}, :active_leases)
      end
    end

    test "unknown gate raises typed; gate list halts on a real breach before reaching it" do
      t = Tensor.new(%{shift_hours_continuous: 100, active_leases: 24, error_rate: 1.0})

      assert_raise ArgumentError, ~r/unknown strain gate/, fn ->
        Tensor.hyperplane_check(t, :nope)
      end

      assert {:breach, {:saturation_gate, total, 0.7}} = Tensor.hyperplane_check(t)
      assert total > 0.7
      # :bogus is never consulted: the first gate already breached
      assert {:breach, {:saturation_gate, ^total, 0.7}} =
               Tensor.hyperplane_check(t, [:saturation_gate, :bogus])

      # whereas a non-breaching tensor reaches the bogus gate
      assert_raise ArgumentError, fn ->
        Tensor.hyperplane_check(Tensor.new(%{}), [:saturation_gate, :bogus])
      end

      assert Tensor.hyperplane_check(t, []) == :ok
    end

    test "partial tensor map reads missing dimensions as zero-observation defaults" do
      assert Tensor.strain(%{}, :active_leases) == 0.0
      assert Tensor.strain(%{active_leases: 6}, :active_leases) == 0.5
      assert Tensor.hyperplane_check(%{}) == :ok

      assert {:breach, _} =
               Tensor.hyperplane_check(%{
                 shift_hours_continuous: 1000,
                 active_leases: 100,
                 error_rate: 1.0
               })
    end
  end
end
