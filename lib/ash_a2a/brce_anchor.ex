defmodule AshA2A.BrceAnchor do
  @moduledoc """
  The sole-DO fence between `AshA2A.CommandBus` and `AshA2A.Dispatcher`
  (RFC-SA2A-001 BRCE; RFC-SA2A-002 §38 Gate 7, §68, §69).

      Attempted(a) ⇒ PreparedReceipt(a)

  `AshA2A.Dispatcher.dispatch/6` is the one function that invokes a real Ash
  action for a skill. Before this fence it actuated any skill it was handed,
  so every caller able to reach it -- a host, a planner adapter, a hook
  handler, a hand-rolled agent -- could produce a `:change`/`:external_do`
  consequence with no admission, no claim, and no durable prepared receipt.
  The `CHI-BRCE` court (`AshA2A.Chicago.Courts.Brce`) observed exactly that.

  The fence:

    1. `AshA2A.CommandBus` durably appends the `:pending` receipt anchor to
       `AshA2A.ReceiptOutbox` (`brce.prepare`), then hands the anchor to the
       dispatcher for exactly one dispatch via `put/1`.
    2. `AshA2A.Dispatcher` `take/0`s it first thing (single use: a nested or
       later dispatch in the same process never inherits it) and, once the
       skill is resolved, asks `admit/2`.
    3. `admit/2` lets `:observe` skills through (no consequence, no receipt
       required) and requires, for every other consequence class -- including
       `:unknown`, which is never admitted -- a `:pending` receipt anchor bound
       to this exact capability and consequence class. Anything else is
       refused with `:brce_prepared_receipt_required` before any Ash action
       runs.

  Durability is established where it is decided: `CommandBus` only hands over
  an anchor after `ReceiptOutbox.append/1` returned `:ok`. The dispatcher does
  not re-stat the journal file, because `ReceiptOutbox.reconcile/2` run by a
  concurrent `CommandBus.run/4` may legitimately commit and remove an
  in-flight anchor between preparation and dispatch.

  Scope, stated exactly: the anchor lives in the dispatching process's
  dictionary, so it fences *paths* (callers that reach the dispatcher without
  crossing BRCE), not arbitrary code already running inside the BEAM, which
  could call `Ash.create/2` directly regardless.

  ## Telemetry

    * `[:ash_a2a, :dispatch, :brce_gate]` -- the decision: `:outcome`
      `:not_required | :anchored | :refused` (+ `:reason` when refused).
    * `[:ash_a2a, :dispatch, :actuate]` -- emitted immediately before the
      real Ash action is invoked, carrying the anchor's `:command_id` /
      `:receipt_id` when one was admitted.

  Both carry `:skill_name`, `:capability_id`, `:consequence`.
  """

  alias AshA2A.{Identity, Receipt}

  @key :ash_a2a_brce_anchor
  @gate_event [:ash_a2a, :dispatch, :brce_gate]
  @actuate_event [:ash_a2a, :dispatch, :actuate]

  @doc false
  def __sa2a_refusal_codes__, do: %{brce_prepared_receipt_required: :refused_receipt}

  @doc "Telemetry events this module emits."
  @spec events() :: [[atom()]]
  def events, do: [@gate_event, @actuate_event]

  @doc "Hands `anchor` to the next dispatch in this process (`nil` clears)."
  @spec put(Receipt.t() | nil) :: :ok
  def put(nil), do: clear()

  def put(%Receipt{} = anchor) do
    Process.put(@key, anchor)
    :ok
  end

  @doc "Removes any anchor from this process."
  @spec clear() :: :ok
  def clear do
    Process.delete(@key)
    :ok
  end

  @doc "Takes (and removes) the anchor for this dispatch. Single use."
  @spec take() :: Receipt.t() | nil
  def take, do: Process.delete(@key)

  @doc """
  Decides whether `skill` may actuate under `anchor`. `skill` is the
  capability-index skill (`:id`, `:name`, `:consequence`).
  """
  @spec admit(map(), Receipt.t() | nil) :: {:ok, Receipt.t() | nil} | {:error, map()}
  def admit(skill, anchor) do
    consequence = Map.get(skill, :consequence)

    case decide(skill, consequence, anchor) do
      :not_required ->
        emit_gate(skill, consequence, :not_required, nil, nil)
        {:ok, nil}

      :anchored ->
        emit_gate(skill, consequence, :anchored, nil, anchor)
        {:ok, anchor}

      {:refused, reason} ->
        emit_gate(skill, consequence, :refused, reason, anchor)

        {:error,
         %{
           code: :brce_prepared_receipt_required,
           reason: reason,
           capability_id: Map.get(skill, :id),
           consequence: consequence,
           detail:
             "consequence-bearing dispatch refused: no durable prepared receipt anchor " <>
               "from AshA2A.CommandBus is bound to this capability"
         }}
    end
  end

  @doc "Emits `[:ash_a2a, :dispatch, :actuate]` for `skill` under `anchor`."
  @spec actuating(map(), Receipt.t() | nil) :: :ok
  def actuating(skill, anchor) do
    :telemetry.execute(
      @actuate_event,
      %{system_time: System.system_time()},
      skill
      |> base_meta(Map.get(skill, :consequence), anchor)
      |> Map.put(:anchored, anchor != nil)
    )
  end

  defp decide(_skill, :observe, _anchor), do: :not_required
  defp decide(_skill, _consequence, nil), do: {:refused, :no_prepared_receipt}

  defp decide(skill, consequence, %Receipt{status: :pending} = anchor) do
    cond do
      not capability_bound?(skill, anchor.capability_id) -> {:refused, :capability_mismatch}
      anchor.consequence != consequence -> {:refused, :consequence_mismatch}
      true -> :anchored
    end
  end

  defp decide(_skill, _consequence, _other), do: {:refused, :anchor_not_pending}

  defp capability_bound?(skill, capability_id) when is_binary(capability_id) do
    capability_id == Map.get(skill, :id) or capability_id == to_string(Map.get(skill, :name))
  end

  defp capability_bound?(_skill, _capability_id), do: false

  defp emit_gate(skill, consequence, outcome, reason, anchor) do
    meta =
      skill
      |> base_meta(consequence, anchor)
      |> Map.put(:outcome, outcome)
      |> then(&if(reason, do: Map.put(&1, :reason, reason), else: &1))

    :telemetry.execute(@gate_event, %{system_time: System.system_time()}, meta)
  end

  defp base_meta(skill, consequence, anchor) do
    %{
      skill_name: Map.get(skill, :name),
      capability_id: Map.get(skill, :id),
      consequence: consequence,
      command_id: anchor_value(anchor, :command_id),
      receipt_id: anchor_value(anchor, :receipt_id)
    }
  end

  defp anchor_value(%Receipt{} = anchor, field) do
    case Map.get(anchor, field) do
      %Identity{value: value} -> value
      value -> value
    end
  end

  defp anchor_value(_anchor, _field), do: nil
end
