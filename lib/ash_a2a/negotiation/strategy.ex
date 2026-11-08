defmodule AshA2A.Negotiation.Strategy do
  @moduledoc """
  Behaviour for bilateral capability-negotiation strategies (desolate-market playbook).

  A strategy is a **pure function** of `{claim, market_context}`. It inspects the
  capability claim under negotiation and the market context and returns one of:

    * `{:counter, offer, leverage: terms}` — escalate with a counter-offer
      carrying named leverage terms.
    * `{:accept, offer}` — the quote is lawful and acceptable.
    * `{:escrow, reason}` — park the negotiation.

  ## Leverage = factual compliance status, never threats

  The `compliance_exposure` field of the market context is **factual compliance
  status** (permits current? EPA-608 refrigerant-handling certification status,
  audit findings, corrective-action status). Leverage terms may *cite* this
  status as the factual basis of a counter-offer term (e.g. "term contingent on
  permit #X being current, verified against the issuing authority"), never as a
  threat. Any term that is not the factual compliance status of a party is not
  lawful leverage under this behaviour.

  ## Market context

  * `:liquidity_zone` — `:thin` when `vendor_count <= 1` (monopoly/duopoly quote,
    no alternative supply), otherwise `:liquid`.
  * `:portfolio_leverage` — scheduled-maintenance volume available for
    cross-market trade.
  * `:compliance_exposure` — permits / EPA-608 / audit findings usable as
    lawful leverage (factual compliance status; see above).
  * `:vendor_count` — number of quoting vendors (drives `:thin` zone detection).
  """

  @callback evaluate_offers(claim :: map(), market_context :: map()) ::
              {:counter, offer :: map(), leverage: terms :: [term()]}
              | {:accept, offer :: map()}
              | {:escrow, reason :: term()}
end
