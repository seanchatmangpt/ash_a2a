defmodule AshA2A.Negotiation.Engine do
  @moduledoc """
  Pure bilateral-negotiation engine (skeleton, desolate-market playbook).

  `run/4` takes a claim, a list of vendor offers, and a strategy module. It
  builds the market context (thin-market detection from `vendor_count`),
  enforces the stall rule, and delegates the decision to the strategy.

  Cost baselines are optionally loaded from a reticle pack. When no pack is
  loadable, the baseline comes from the claim (`claim["cost_baseline"]` or
  `claim[:cost_baseline]`) or an explicit `:cost_baseline` opt. When neither
  exists, no above-baseline escalation is possible and the strategy is
  consulted on a baseline-less context.

  ## Escrow mapping (documented; no durable call from this pure module)

  `{:escrow, {:parked, reason}}` maps to the engine's `Steps.Await` vocabulary:
  a stalled negotiation parks like an `Await` step with `:waiting` status — the
  same shape AshA2A.Providers.PPlan reports as `{:parked, :waiting}`
  (`lib/ash_a2a/providers/pplan.ex:159`). The durable resume (signal the parked
  waiter with a fresh quote) belongs to the durable engine, never this pure
  module; it only emits the vocabulary-mapped value.

  ## Strategy contract violations are typed

  A strategy returning anything outside the behaviour's three lawful results
  comes back as `{:escrow, {:parked, {:strategy_contract_violation, value}}}`.
  """

  @default_max_rounds 3

  @doc """
  Runs one negotiation round.

  ## Options

    * `:max_rounds` — stall threshold (default #{@default_max_rounds}).
    * `:round` — current round number (default 1).
    * `:cost_baseline` — explicit baseline override; otherwise from the claim.
  """
  @spec run(map(), [map()], module(), keyword()) ::
          {:counter, map(), leverage: [term()]}
          | {:accept, map()}
          | {:escrow, {:parked, term()}}
  def run(claim, offers, strategy, opts \\ []) when is_map(claim) and is_list(offers) do
    context = %{
      liquidity_zone: liquidity_zone(length(offers)),
      portfolio_leverage: fetch(claim, :portfolio_leverage),
      compliance_exposure: fetch(claim, :compliance_exposure),
      vendor_count: length(offers),
      round: Keyword.get(opts, :round, 1),
      max_rounds: Keyword.get(opts, :max_rounds, @default_max_rounds),
      cost_baseline: cost_baseline(claim, opts),
      price: fetch(claim, :price)
    }

    case strategy.evaluate_offers(claim, context) do
      {:counter, offer, leverage: terms} when is_map(offer) and is_list(terms) ->
        {:counter, offer, leverage: terms}

      {:accept, offer} when is_map(offer) ->
        {:accept, offer}

      {:escrow, reason} ->
        {:escrow, {:parked, reason}}

      other ->
        {:escrow, {:parked, {:strategy_contract_violation, other}}}
    end
  end

  @doc """
  Thin-market detection: `:thin` when `vendor_count <= 1` (monopoly quote, no
  alternative supply), `:liquid` otherwise.
  """
  @spec liquidity_zone(non_neg_integer()) :: :thin | :liquid
  def liquidity_zone(vendor_count) when is_integer(vendor_count) and vendor_count >= 0 do
    if vendor_count <= 1, do: :thin, else: :liquid
  end

  defp cost_baseline(claim, opts) do
    case Keyword.fetch(opts, :cost_baseline) do
      {:ok, baseline} -> baseline
      :error -> fetch(claim, :cost_baseline)
    end
  end

  defp fetch(claim, key) when is_atom(key) do
    Map.get(claim, key) || Map.get(claim, to_string(key))
  end
end
