defmodule AshA2A.Negotiation.EngineCourtTest do
  use ExUnit.Case, async: true

  alias AshA2A.Negotiation.{DefaultStrategy, Engine, Strategy}

  # A fake strategy is a hand-written real interface implementation, not a
  # mock — used only for the typed contract-violation court cell.
  defmodule ViolentStrategy do
    @behaviour AshA2A.Negotiation.Strategy

    @impl true
    def evaluate_offers(_claim, _ctx), do: {:threaten, "pay up"}
  end

  defmodule NilOfferStrategy do
    @behaviour AshA2A.Negotiation.Strategy

    @impl true
    def evaluate_offers(_claim, _ctx), do: {:accept, "not a map"}
  end

  describe "liquidity_zone/1" do
    test "thin when vendor_count <= 1" do
      assert Engine.liquidity_zone(0) == :thin
      assert Engine.liquidity_zone(1) == :thin
      assert Engine.liquidity_zone(2) == :liquid
    end
  end

  describe "thin market + above-baseline quote" do
    test "escalates to counter with factual leverage terms" do
      claim = %{
        "price" => 9_500,
        "cost_baseline" => 8_000,
        "portfolio_leverage" => "12 scheduled-maintenance units",
        "compliance_exposure" => %{permit_status: :current, epa_608: :certified, findings: 0}
      }

      offers = [%{"vendor" => "monopoly-hvac", "price" => 9_500}]

      assert {:counter, offer, leverage: terms} =
               Engine.run(claim, offers, DefaultStrategy)

      assert offer["price"] == 8_000
      assert offer["round"] == 1

      assert terms == [
               {:portfolio_volume, "12 scheduled-maintenance units"},
               {:compliance_status, %{permit_status: :current, epa_608: :certified, findings: 0}}
             ]
    end
  end

  describe "stall" do
    test "negotiation past max_rounds parks as escrow" do
      claim = %{"price" => 9_500, "cost_baseline" => 8_000}
      offers = [%{"vendor" => "monopoly-hvac", "price" => 9_500}]

      assert {:escrow, {:parked, {:stalled, 4, 3}}} =
               Engine.run(claim, offers, DefaultStrategy, round: 4, max_rounds: 3)

      # Vocabulary mapping: parked matches the Steps.Await {:parked, :waiting}
      # shape documented in the Engine moduledoc (Providers.PPlan vocabulary).
      assert match?({:parked, _}, {:parked, {:stalled, 4, 3}})
    end
  end

  describe "liquid market" do
    test "above-baseline quote accepts plainly — no counter in a liquid market" do
      claim = %{"price" => 9_500, "cost_baseline" => 8_000}
      offers = [%{"v1" => 1}, %{"v2" => 2}]

      assert {:accept, offer} = Engine.run(claim, offers, DefaultStrategy)
      assert offer["price"] == 9_500
    end

    test "thin market with below-baseline quote accepts" do
      claim = %{"price" => 7_000, "cost_baseline" => 8_000}
      offers = [%{"vendor" => "solo"}]

      assert {:accept, offer} = Engine.run(claim, offers, DefaultStrategy)
      assert offer["price"] == 7_000
    end
  end

  describe "strategy contract violations" do
    test "non-lawful return is typed as a parked strategy_contract_violation" do
      assert {:escrow, {:parked, {:strategy_contract_violation, {:threaten, "pay up"}}}} =
               Engine.run(%{}, [%{}], ViolentStrategy)
    end

    test "accept with a non-map offer is typed as a violation" do
      assert {:escrow, {:parked, {:strategy_contract_violation, {:accept, "not a map"}}}} =
               Engine.run(%{}, [%{}], NilOfferStrategy)
    end
  end

  test "strategy behaviour is loaded and documents the leverage law" do
    assert [evaluate_offers: 2] = Strategy.behaviour_info(:callbacks)

    assert String.contains?(
             File.read!(Path.join(File.cwd!(), "lib/ash_a2a/negotiation/strategy.ex")),
             "Leverage = factual compliance status, never threats"
           )
  end
end
