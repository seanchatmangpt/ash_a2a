defmodule AshA2A.Marketplace.GCP.EntitlementLifecycle do
  @moduledoc """
  Manages Google Cloud Marketplace account & entitlement lifecycle.

  Governs state transitions triggered by GCP Pub/Sub events:
    - `ENTITLEMENT_CREATION_REQUESTED` -> `:pending_approval` -> `:active`
    - `ENTITLEMENT_PLAN_CHANGE_REQUESTED` -> `:plan_change_pending`
    - `ENTITLEMENT_CANCELLED` -> `:cancelled`

  Integrates with committed cloud spend (EDP/drawdown) accounting:
  entitlements carry dedicated spend lease allocations.
  """

  defstruct [
    :account_id,
    :entitlement_id,
    :product_id,
    :plan_id,
    :state,
    :committed_spend_eligible,
    :allocated_spend_usd,
    :updated_at
  ]

  @type state :: :pending_creation | :active | :plan_change_pending | :cancelled | :suspended

  @type t :: %__MODULE__{
          account_id: String.t(),
          entitlement_id: String.t(),
          product_id: String.t(),
          plan_id: String.t(),
          state: state(),
          committed_spend_eligible: boolean(),
          allocated_spend_usd: number(),
          updated_at: DateTime.t()
        }

  @doc "Initializes an entitlement record from an incoming GCP event or JWT."
  @spec from_event(map()) :: t()
  def from_event(attrs) do
    %__MODULE__{
      account_id: attrs[:account_id] || attrs["account_id"],
      entitlement_id: attrs[:entitlement_id] || attrs["entitlement_id"],
      product_id: attrs[:product_id] || attrs["product_id"] || "ecosystem-enterprise-bundle",
      plan_id: attrs[:plan_id] || attrs["plan_id"] || "edp-committed-tier-1",
      state: :pending_creation,
      committed_spend_eligible: Map.get(attrs, :committed_spend_eligible, true),
      allocated_spend_usd: Map.get(attrs, :allocated_spend_usd, 0.0),
      updated_at: DateTime.utc_now()
    }
  end

  @doc "Approves an entitlement, marking it active and eligible for committed cloud spend drawdown."
  @spec approve(t(), keyword()) :: {:ok, t()} | {:error, term()}
  def approve(ent, opts \\ [])
  def approve(%__MODULE__{state: :pending_creation} = ent, opts) do
    spend = Keyword.get(opts, :allocated_spend_usd, 50_000.0)

    {:ok,
     %{
       ent
       | state: :active,
         allocated_spend_usd: spend,
         committed_spend_eligible: true,
         updated_at: DateTime.utc_now()
     }}
  end

  def approve(%__MODULE__{state: other}, _opts) do
    {:error, %{code: :invalid_transition, detail: "Cannot approve entitlement in #{other} state"}}
  end

  @doc "Cancels an active entitlement, stopping spend drawdown."
  @spec cancel(t()) :: {:ok, t()}
  def cancel(%__MODULE__{} = ent) do
    {:ok, %{ent | state: :cancelled, updated_at: DateTime.utc_now()}}
  end
end
