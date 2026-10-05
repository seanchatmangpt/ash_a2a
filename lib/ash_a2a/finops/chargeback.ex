# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.FinOps.Chargeback do
  @moduledoc """
  The billing/chargeback tag attached to a single admitted (or refused)
  dispatch: the organizational attribution (PRD FR-05.1) plus the budget
  state the dispatch was admitted against.

  Returned as the ok-tag of `AshA2A.FinOps.BudgetEnforcer.authorize/3`
  and carried on `[:ash_a2a, :finops, :chargeback]` telemetry metadata so
  every downstream telemetry emission for the dispatch can be correlated
  to a `cost_center` for FinOps chargeback ingestion (ARD §3.5).
  """

  @enforce_keys [:cost_center, :budget_account_id]
  defstruct [
    :cost_center,
    :budget_account_id,
    :ceiling,
    :window_started_at,
    :window_ms,
    :requested,
    :consumed
  ]

  @type t :: %__MODULE__{
          cost_center: String.t() | atom(),
          budget_account_id: String.t() | atom(),
          ceiling: pos_integer() | nil,
          window_started_at: integer() | nil,
          window_ms: pos_integer() | nil,
          requested: non_neg_integer() | nil,
          consumed: non_neg_integer() | nil
        }

  @doc """
  Flattens the tag to the billing metadata map used on telemetry events
  and transport headers. All values are JSON-encodable (strings, integers).
  """
  @spec metadata(t()) :: %{
          required(:cost_center) => String.t() | atom(),
          required(:budget_account_id) => String.t() | atom(),
          optional(atom()) => term()
        }
  def metadata(%__MODULE__{} = tag) do
    tag
    |> Map.from_struct()
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end
