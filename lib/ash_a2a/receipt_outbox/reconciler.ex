defmodule AshA2A.ReceiptOutbox.Reconciler do
  @moduledoc """
  Standing, opt-in periodic drain of `AshA2A.ReceiptOutbox`, with a real
  stuck-entry escalation signal.

  ## The gap this closes

  `AshA2A.ReceiptOutbox.reconcile/2` (the real drain path -- see that
  module) is only ever triggered two ways today: opportunistically, inline,
  at the top of the next `AshA2A.CommandBus.run/4` call when
  `ReceiptOutbox.count() > 0` (`command_bus.ex`'s `maybe_reconcile_outbox/2`),
  or by an explicit manual call to `AshA2A.Reconciliation.reconcile/4` /
  `AshA2A.ReceiptOutbox.reconcile/2`. A host that stops dispatching new
  commands through a given store has no standing mechanism to notice or
  drain a growing stuck-outbox backlog -- reconciliation itself is correct
  and heavily tested; only the *trigger* was missing a standing option.

  `Receipt.reconciliation.attempts` (see `receipt.ex`) is real, already
  incremented on every `AshA2A.Receipt.reconcile/2` call, but nothing reads
  it anywhere else in this codebase to bound retries or raise an alert. This
  module is the first consumer of that field.

  ## What this module is, precisely

  A real `GenServer` that, once started, wakes on a configurable interval
  and:

    1. Calls the existing, already-verified `AshA2A.ReceiptOutbox.reconcile/2`
       drain (adds no new drain logic of its own -- it only calls the real
       one) and emits `[:ash_a2a, :receipt_outbox, :reconciler, :tick]` with
       `:committed` and `:remaining` measurements.
    2. Reads `AshA2A.ReceiptOutbox.entries/0` (whatever is left after the
       drain) and, for any entry whose `reconciliation.attempts` meets or
       exceeds a configurable stuck-attempts threshold, emits one
       `[:ash_a2a, :receipt_outbox, :reconciler, :stuck]` event per stuck
       entry, naming its `command_id` and `receipt_id` and its real
       `attempts` count -- a real, standing, observable signal instead of
       silence.

  Both drain and read reuse `AshA2A.ReceiptOutbox`'s own real functions;
  this module owns no receipt-journal I/O itself.

  ## Deliberately not started by default

  Following `AshA2A.KillSwitch`'s own precedent (see its moduledoc's "Scope"
  section): `AshA2A.Application` does not start this GenServer. A host opts
  in by adding `{AshA2A.ReceiptOutbox.Reconciler, []}` (or with `:interval_ms`
  / `:stuck_attempts_threshold` / `:store` / `:store_opts` overrides) to its
  own supervision tree, or by configuring
  `config :ash_a2a, :outbox_reconciler_interval_ms, n` and letting a host
  supervisor start it under that config. This is purely additive: it does
  not touch `command_bus.ex`, `receipt_outbox.ex`, or `reconciliation.ex`.

  ## Telemetry

    * `[:ash_a2a, :receipt_outbox, :reconciler, :tick]` -- measurements
      `%{committed: non_neg_integer(), remaining: non_neg_integer()}`,
      metadata `%{}`.
    * `[:ash_a2a, :receipt_outbox, :reconciler, :stuck]` -- measurements
      `%{attempts: non_neg_integer()}`, metadata `%{command_id: String.t(),
      receipt_id: String.t() | nil, threshold: non_neg_integer()}`, one event
      per stuck entry found after a tick's drain.

  This module performs no commit/claim/authority decision of its own -- it
  is an observational scheduler over the existing reconciliation machinery,
  the same "does not change dispatch behavior" scope `AshA2A.KillSwitch`
  and `AshA2A.Telemetry.OcelForwarder` already keep for their own standing
  processes.
  """

  use GenServer

  alias AshA2A.{CommandBus, ReceiptOutbox}

  @default_interval_ms 60_000
  @default_stuck_attempts_threshold 5

  @type opts :: [
          name: GenServer.name(),
          interval_ms: pos_integer(),
          stuck_attempts_threshold: non_neg_integer(),
          store: module(),
          store_opts: keyword()
        ]

  @doc """
  Starts the reconciler.

  Options:

    * `:name` -- registered name (default `__MODULE__`).
    * `:interval_ms` -- tick period; falls back to
      `config :ash_a2a, :outbox_reconciler_interval_ms` then
      #{@default_interval_ms}ms.
    * `:stuck_attempts_threshold` -- `reconciliation.attempts` at or above
      which an entry emits a `:stuck` event; falls back to
      `config :ash_a2a, :outbox_stuck_attempts_threshold` then
      #{@default_stuck_attempts_threshold}.
    * `:store` / `:store_opts` -- passed through to
      `AshA2A.ReceiptOutbox.reconcile/2` exactly as `CommandBus` itself
      would (default `AshA2A.CommandBus.default_store()` / `[]`).
  """
  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Forces one immediate drain+stuck-check tick synchronously (does not wait
  for the next scheduled interval). Returns the same
  `{:ok, %{committed: _, remaining: _}}` shape `ReceiptOutbox.reconcile/2`
  returns. Intended for tests and for an operator-triggered "reconcile now"
  path that still emits the standing telemetry.
  """
  @spec tick(GenServer.name()) ::
          {:ok, %{committed: non_neg_integer(), remaining: non_neg_integer()}}
  def tick(name \\ __MODULE__) do
    GenServer.call(name, :tick)
  end

  @impl true
  def init(opts) do
    interval_ms =
      Keyword.get(
        opts,
        :interval_ms,
        Application.get_env(:ash_a2a, :outbox_reconciler_interval_ms, @default_interval_ms)
      )

    stuck_attempts_threshold =
      Keyword.get(
        opts,
        :stuck_attempts_threshold,
        Application.get_env(
          :ash_a2a,
          :outbox_stuck_attempts_threshold,
          @default_stuck_attempts_threshold
        )
      )

    store = Keyword.get(opts, :store, CommandBus.default_store())
    store_opts = Keyword.get(opts, :store_opts, [])

    state = %{
      interval_ms: interval_ms,
      stuck_attempts_threshold: stuck_attempts_threshold,
      store: store,
      store_opts: store_opts,
      timer_ref: nil
    }

    {:ok, schedule(state)}
  end

  @impl true
  def handle_info(:tick, state) do
    run_tick(state)
    {:noreply, schedule(state)}
  end

  @impl true
  def handle_call(:tick, _from, state) do
    result = run_tick(state)
    {:reply, result, state}
  end

  defp run_tick(%{store: store, store_opts: store_opts} = state) do
    {:ok, %{committed: committed, remaining: remaining} = result} =
      ReceiptOutbox.reconcile(store, store_opts)

    :telemetry.execute(
      [:ash_a2a, :receipt_outbox, :reconciler, :tick],
      %{committed: committed, remaining: remaining},
      %{}
    )

    emit_stuck_entries(state)

    {:ok, result}
  end

  defp emit_stuck_entries(%{stuck_attempts_threshold: threshold}) do
    ReceiptOutbox.entries()
    |> Enum.each(fn receipt ->
      attempts = Map.get(receipt.reconciliation || %{}, :attempts, 0)

      if attempts >= threshold do
        :telemetry.execute(
          [:ash_a2a, :receipt_outbox, :reconciler, :stuck],
          %{attempts: attempts},
          %{
            command_id: identity_value(receipt.command_id),
            receipt_id: identity_value(receipt.receipt_id),
            threshold: threshold
          }
        )
      end
    end)
  end

  defp identity_value(%{value: value}), do: value
  defp identity_value(other), do: other

  defp schedule(state) do
    ref = Process.send_after(self(), :tick, state.interval_ms)
    %{state | timer_ref: ref}
  end
end
