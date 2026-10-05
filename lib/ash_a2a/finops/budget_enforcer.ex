# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.FinOps.BudgetEnforcer do
  @moduledoc """
  The FR-05 pre-dispatch budget gate (PRD §4.5, ARD §3.5).

  `authorize/3` runs BEFORE dispatch and is the only thing standing
  between a wire request and downstream LLM spend:

    1. **Attribution (FR-05.1)** -- resolves the organizational
       `cost_center` and `budget_account_id` for the request: explicit
       request metadata first (`:cost_center` / `"cost_center"` /
       `"x-cost-center"` header forms, same three shapes for
       `budget_account_id`), then the configured defaults under
       `Application.get_env(:ash_a2a, :finops)`
       (`default_cost_center:` / `default_budget_account_id:`).
       Unresolvable attribution is a typed refusal (`:invalid_request`,
       S42 `:refused_structure`) -- never a silent default.
    2. **Hard-ceiling reservation (FR-05.2/05.3)** -- reserves the
       request's estimated token cost against the account's ceiling via
       `AshA2A.FinOps.BudgetStore.record/3`. A request that would push
       the billing window past 100% of quota is refused with
       `:budget_exceeded` (S42 `:refused_bounds`, the PRD's
       `:REFUSED_BUDGET_EXCEEDED`) **before any downstream execution** --
       the caller dispatches only on `{:ok, tag}`, so a breach consumes
       zero downstream LLM tokens. An account with no configured ceiling
       is also refused fail-closed (`:missing_evidence`,
       S42 `:refused_provenance`): no ceiling is not unlimited.
    3. **Chargeback tagging** -- on every verdict (admit or refuse) a
       `[:ash_a2a, :finops, :chargeback]` telemetry event fires carrying
       the billing metadata (`cost_center`, `budget_account_id`,
       `ceiling`, `window_started_at`, `admitted`, `code`) for FinOps
       chargeback ingestion (ARD §3.5: "Tags all outbound telemetry with
       billing metadata").

  `settle/3` records post-dispatch actual consumption: when the real
  token count exceeds the estimate reserved at authorization, the delta
  is charged to the same account/window (chargeback accuracy).

  The refusal shape is the CommandBus `%{code: ..., detail: ...}` shape,
  liftable via `AshA2A.Semantic.Refusal.from_error/2`.
  """

  @chargeback_event [:ash_a2a, :finops, :chargeback]

  @typedoc "Any request-ish term carrying metadata: a map (atom or string keys)."
  @type request :: map()

  alias AshA2A.FinOps.BudgetStore
  alias AshA2A.FinOps.Chargeback

  @doc "The chargeback telemetry event name."
  @spec chargeback_event() :: [:ash_a2a | :finops | :chargeback, ...]
  def chargeback_event, do: @chargeback_event

  @doc """
  Resolves attribution, reserves the estimated cost against the hard
  ceiling, and -- on admission -- returns the `AshA2A.FinOps.Chargeback`
  tag to carry on the dispatch. Refuses typed before any downstream
  effect on breach, unconfigured budget, or unresolvable attribution.

  Opts:

    * `:estimated_tokens` -- the reservation used when the request itself
      carries no `:estimated_tokens` / `:tokens` metadata (default `0`).
  """
  @spec authorize(BudgetStore.store(), request(), keyword()) ::
          {:ok, Chargeback.t()} | {:error, %{code: atom(), detail: term()}}
  def authorize(store, request, opts \\ []) do
    now = System.system_time(:millisecond)

    case resolve_attribution(request) do
      {:ok, {cost_center, budget_account_id}} ->
        case reserve(store, request, budget_account_id, opts) do
          {:ok, reservation} ->
            tag = %Chargeback{
              cost_center: cost_center,
              budget_account_id: budget_account_id,
              ceiling: reservation.ceiling,
              window_started_at: reservation.window_started_at,
              window_ms: reservation.window_ms,
              requested: reservation.requested,
              consumed: reservation.consumed
            }

            emit(tag, now, true, nil)
            {:ok, tag}

          {:error, refusal} ->
            emit_partial(refusal, now, false, cost_center)
            {:error, refusal}
        end

      {:error, refusal} ->
        emit_partial(refusal, now, false, nil)
        {:error, refusal}
    end
  end

  @doc """
  Records post-dispatch actual consumption. Charges only the delta above
  what `authorize/3` already reserved; returns the store's record result
  or `:ok` when the actual came in at or under the estimate.
  """
  @spec settle(BudgetStore.store(), Chargeback.t(), non_neg_integer()) ::
          :ok | {:ok, map()} | {:error, map()}
  def settle(store, %Chargeback{} = tag, actual_tokens)
      when is_integer(actual_tokens) and actual_tokens >= 0 do
    reserved = tag.requested || 0
    delta = actual_tokens - reserved

    if delta > 0 do
      BudgetStore.record(store, tag.budget_account_id, delta)
    else
      :ok
    end
  end

  # -- attribution (FR-05.1) --

  defp resolve_attribution(request) do
    with {:ok, cost_center} <- fetch_field(request, :cost_center, ["x-cost-center"]),
         {:ok, budget_account_id} <- fetch_field(request, :budget_account_id, ["x-budget-account-id"]) do
      {:ok, {cost_center, budget_account_id}}
    else
      {:error, field} ->
        {:error,
         %{
           code: :invalid_request,
           detail: %{
             missing: field,
             reason:
               "FR-05.1: no organizational cost attribution on the request and no default configured"
           }
         }}
    end
  end

  defp fetch_field(request, key, header_forms) do
    cond do
      value = fetch_any(request, [key, Atom.to_string(key)]) ->
        {:ok, value}

      value = fetch_any(request, header_forms) ->
        {:ok, value}

      value = default_for(key) ->
        {:ok, value}

      true ->
        {:error, key}
    end
  end

  defp fetch_any(request, keys) do
    Enum.find_value(keys, fn key -> fetch_key(request, key) end)
  end

  defp fetch_key(request, key) when is_map(request) do
    case Map.fetch(request, key) do
      {:ok, value} when not is_nil(value) -> value
      _ -> nil
    end
  end

  defp fetch_key(_request, _key), do: nil

  defp default_for(key) do
    case Application.get_env(:ash_a2a, :finops, []) do
      conf when is_list(conf) ->
        default_key = if key == :cost_center, do: :default_cost_center, else: :default_budget_account_id
        conf[default_key]

      %{} = conf ->
        default_key = if key == :cost_center, do: :default_cost_center, else: :default_budget_account_id
        conf[default_key]

      _other ->
        nil
    end
  end

  # -- reservation (FR-05.2/05.3) --

  defp reserve(store, request, budget_account_id, opts) do
    estimated = estimated_tokens(request, opts)

    case BudgetStore.record(store, budget_account_id, estimated) do
      {:ok, reservation} ->
        {:ok, Map.put(reservation, :requested, estimated)}

      {:error, %{code: :missing_evidence, detail: detail}} ->
        {:error,
         %{
           code: :missing_evidence,
           detail: Map.merge(detail, %{reason: "no hard budget ceiling configured for this account"})
         }}

      {:error, %{code: :budget_exceeded, detail: detail}} ->
        {:error, %{code: :budget_exceeded, detail: Map.put(detail, :requested, estimated)}}
    end
  end

  defp estimated_tokens(request, opts) do
    cond do
      value = fetch_key(request, :estimated_tokens) -> normalize_amount(value)
      value = fetch_key(request, :tokens) -> normalize_amount(value)
      value = fetch_key(request, "estimated_tokens") -> normalize_amount(value)
      value = fetch_key(request, "tokens") -> normalize_amount(value)
      true -> normalize_amount(Keyword.get(opts, :estimated_tokens, 0))
    end
  end

  defp normalize_amount(value) when is_integer(value) and value >= 0, do: value

  defp normalize_amount(value) when is_integer(value),
    do: raise(ArgumentError, "estimated tokens must be non-negative, got: #{inspect(value)}")

  defp normalize_amount(value) do
    raise ArgumentError, "estimated tokens must be a non-negative integer, got: #{inspect(value)}"
  end

  # -- telemetry (chargeback tagging) --

  defp emit(%Chargeback{} = tag, now, admitted, code) do
    :telemetry.execute(@chargeback_event, %{tokens: tag.requested || 0, system_time: now}, %{
      cost_center: tag.cost_center,
      budget_account_id: tag.budget_account_id,
      ceiling: tag.ceiling,
      window_started_at: tag.window_started_at,
      window_ms: tag.window_ms,
      consumed: tag.consumed,
      admitted: admitted,
      code: code
    })
  end

  # A refusal that carries no tag (attribution or budget unresolvable):
  # still chargeback-tagged with whatever attribution resolved.
  defp emit_partial(%{code: code, detail: detail}, now, admitted, cost_center) do
    account = detail[:budget_account_id] || detail[:missing]

    :telemetry.execute(@chargeback_event, %{tokens: detail[:requested] || 0, system_time: now}, %{
      cost_center: cost_center,
      budget_account_id: account,
      ceiling: detail[:ceiling],
      window_started_at: detail[:window_started_at],
      window_ms: nil,
      consumed: detail[:consumed],
      admitted: admitted,
      code: code
    })
  end
end
