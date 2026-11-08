defmodule AshA2A.Negotiation.DefaultStrategy do
  @moduledoc """
  Default `AshA2A.Negotiation.Strategy`: accept-if-below-baseline,
  counter-with-leverage-if-thin-and-above, escrow-after-rounds.

  Leverage terms cite factual compliance status and portfolio volume only —
  never threats (see `AshA2A.Negotiation.Strategy` moduledoc).
  """

  @behaviour AshA2A.Negotiation.Strategy

  @impl true
  def evaluate_offers(_claim, context) do
    cond do
      stalled?(context) ->
        {:escrow, {:stalled, context.round, context.max_rounds}}

      thin_and_above_baseline?(context) ->
        {:counter, counter_offer(context), leverage: leverage_terms(context)}

      true ->
        # Below baseline (or no baseline / no price to escalate on):
        # plain accept at the quoted price.
        {:accept, accept_offer(context)}
    end
  end

  # Stall rule: round has exhausted max_rounds -> park the negotiation.
  defp stalled?(%{round: round, max_rounds: max_rounds}), do: round > max_rounds

  defp thin_and_above_baseline?(%{liquidity_zone: :thin, cost_baseline: baseline, price: price})
       when is_number(baseline) and is_number(price),
       do: price > baseline

  defp thin_and_above_baseline?(_context), do: false

  # Counter-offer caps at the cost baseline — that is the escalation.
  defp counter_offer(context), do: offer_at(context, context.cost_baseline)

  # Accept echoes the quoted price, never a clamped one.
  defp accept_offer(context), do: offer_at(context, price_value(context))

  defp offer_at(context, price), do: %{"price" => price, "round" => context.round}

  defp price_value(%{price: price}) when is_number(price), do: price
  defp price_value(_), do: nil

  defp leverage_terms(context) do
    [
      {:portfolio_volume, context.portfolio_leverage},
      {:compliance_status, context.compliance_exposure}
    ]
  end
end
