defmodule AshA2A.CommandBus do
  @moduledoc """
  Canonical receipted route from an admitted `AshA2A.Command` to the existing
  Ash dispatcher. Planning and provider adapters may call this module; they do
  not bypass its capability, identity, replay, or evidence checks.

  "Replay" is idempotent command re-submission / command dedup (see
  `AshA2A.ReceiptStore`'s moduledoc), not process-mining trace
  replay/conformance checking -- no ordered event trace or reference process
  model is involved.

  ## Consequence/receipt state machine (A2A-2601)

  `run/4` advances one command through an explicit outbox-shaped sequence:

      ADMITTED -> INTENT_DURABLE -> EXECUTING -> CONSEQUENCE_OBSERVED
                                                          |
                                     RECEIPT_DURABLE <----+----> RECEIPT_OUTBOXED
                                     (store.commit ok)          (commit failed after
                                                                   the consequence; the
                                                                   receipt is journaled
                                                                   durably by
                                                                   `AshA2A.ReceiptOutbox`
                                                                   and the caller gets a
                                                                   typed
                                                                   `:receipt_commit_pending`
                                                                   error CARRYING the
                                                                   receipt)

  ADMITTED is `inspect_target/2` + `admit/2`. INTENT_DURABLE is the store's
  own claim entry. EXECUTING crashes are already converted to `:failed`
  receipts by `safe_dispatch/4`. The CONSEQUENCE_OBSERVED ->
  RECEIPT_DURABLE edge is the one this state machine closes: a commit that
  keeps failing after bounded retries (`:receipt_commit_retry_delays_ms`,
  default `[50, 150]`) lands the receipt in the outbox instead of
  discarding the outcome, and a later `reconcile_outboxed_receipts/2` (or
  the opportunistic drain `run/4` performs before every claim, when the
  journal is non-empty) repairs the store once it recovers.
  """

  alias AshA2A.{Authority, Command, Identity, Receipt, ReceiptOutbox}

  @type result :: {:ok, Receipt.t()} | {:error, map()}

  @doc """
  The real, configured default `AshA2A.ReceiptStore` implementation --
  `Application.get_env(:ash_a2a, :receipt_store, AshA2A.ReceiptStore.Memory)`,
  the exact same resolution `run/4` below uses when a caller passes no
  `:store` opt. Exposed so any other real caller needing the SAME default
  store `run/4` itself would have used (e.g. `AshA2A.Agent`'s
  receipt-driven-replanning continuation lookup, GAP B) resolves it identically
  rather than re-deriving or drifting from this one real source of truth.
  """
  @spec default_store() :: module()
  def default_store, do: Application.get_env(:ash_a2a, :receipt_store, AshA2A.ReceiptStore.Memory)

  @doc """
  Drains the `AshA2A.ReceiptOutbox` journal into `store` (default:
  `default_store/0`) -- the crash-recovery/reconciliation half of the
  consequence/receipt state machine above. Operators call this after a store
  outage; `run/4` also calls it opportunistically (best-effort, never
  blocking) whenever the journal is non-empty, so the next command through
  the bus repairs the previous one's pending receipt.
  """
  @spec reconcile_outboxed_receipts(module(), keyword()) ::
          {:ok, %{committed: non_neg_integer(), remaining: non_neg_integer()}}
  def reconcile_outboxed_receipts(store \\ default_store(), store_opts \\ []) do
    ReceiptOutbox.reconcile(store, store_opts)
  end

  @spec run(Command.t(), A2A.Message.t(), module(), keyword()) :: result()
  def run(%Command{} = command, %A2A.Message{} = message, resource_or_domain, opts \\ []) do
    store = Keyword.get(opts, :store, default_store())
    store_opts = Keyword.get(opts, :store_opts, [])

    maybe_reconcile_outbox(store, store_opts)

    with {:ok, skill, _action, consequence} <- inspect_target(command, resource_or_domain),
         :ok <- admit(command, consequence),
         claim <- claim_receipt(store, command, store_opts) do
      case claim do
        {:replay, receipt} ->
          {:ok, receipt}

        {:execute, %Identity{kind: :execution} = execution_id} ->
          reply = safe_dispatch(skill, message, resource_or_domain, opts)

          receipt =
            command
            |> Receipt.from_reply(execution_id, consequence, reply)
            |> mark_standing(store)

          commit_receipt(store, receipt, store_opts)

        {:error, reason} ->
          {:error, refusal(reason)}
      end
    end
  end

  # Both concrete `AshA2A.ReceiptStore` implementations resolve their backing
  # process/config fresh by name on every call -- `GenServer.call` to a
  # registered name for `AshA2A.ReceiptStore.Memory`, `:persistent_term.get/1`
  # (via `EKV.get/2`) for `AshA2A.ReceiptStore.Ekv`. If that name/config is
  # momentarily gone (a restart window), the resulting crash (`:noproc` exit,
  # or `ArgumentError`) would otherwise propagate uncaught through `run/4`
  # into the calling `A2A.Agent` GenServer's `handle_call`, killing it and
  # discarding every task/history it held for that resource. Fail closed
  # instead, through the SAME `refusal/1`-shaped `{:error, reason}` path
  # ordinary store claim errors (`:command_conflict`, `:in_flight`) already
  # flow through in `run/4`'s `case` above -- rather than inventing a new
  # error shape. Mirrors the identical no-raise contract
  # `AshA2A.Agent.replan/2` already holds its own external (LLM-role) call
  # to, for the identical availability reason.
  defp claim_receipt(store, command, store_opts) do
    store.claim(command, store_opts)
  rescue
    _error -> {:error, :receipt_store_unavailable}
  catch
    :exit, _reason -> {:error, :receipt_store_unavailable}
  end

  # Same fail-closed contract as `claim_receipt/3` above, for the identical
  # reason: `store.commit/2` also resolves its backing process/config fresh
  # by name on every call and can crash the same two ways.
  #
  # A2A-2601: this is no longer the end of the line for a commit failure.
  # By the time `commit_receipt/3` runs, the consequence has ALREADY
  # happened (`safe_dispatch/4` returned) -- returning a bare
  # `:receipt_store_unavailable` error here used to discard the observed
  # outcome entirely, leaving a real consequence with no durable receipt
  # anywhere (the zero-unreceipted-DO break). Now: bounded retries for
  # transient restart windows, then a durable `AshA2A.ReceiptOutbox.append/1`
  # and a typed `:receipt_commit_pending` error that CARRIES the receipt,
  # with reconciliation (`reconcile_outboxed_receipts/2`) repairing the
  # store later. Only a simultaneous outbox failure returns the terminal
  # `:receipt_commit_failed` error (still carrying the receipt).
  defp commit_receipt(store, receipt, store_opts) do
    delays = Application.get_env(:ash_a2a, :receipt_commit_retry_delays_ms, [50, 150])

    case commit_with_retries(store, receipt, store_opts, delays) do
      :ok ->
        emit_receipt(receipt)
        {:ok, receipt}

      {:error, reason} ->
        outbox_after_consequence(receipt, reason)
    end
  end

  defp commit_with_retries(store, receipt, store_opts, delays, last_reason \\ nil)

  defp commit_with_retries(_store, _receipt, _store_opts, [], last_reason), do: {:error, last_reason}

  defp commit_with_retries(store, receipt, store_opts, [delay | rest], _last_reason) do
    case commit_once(store, receipt, store_opts) do
      :ok ->
        :ok

      {:error, reason} ->
        Process.sleep(delay)
        commit_with_retries(store, receipt, store_opts, rest, reason)
    end
  end

  defp commit_once(store, receipt, store_opts) do
    case store.commit(receipt, store_opts) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    _error -> {:error, :receipt_store_unavailable}
  catch
    :exit, _reason -> {:error, :receipt_store_unavailable}
  end

  # RECEIPT_OUTBOXED: the consequence is observed, the store is not taking
  # the receipt, so the receipt itself becomes the durable evidence. The
  # `[:ash_a2a, :receipt, :outboxed]` telemetry event carries the same
  # `%{receipt: receipt}` metadata `emit_receipt/1` uses, so observational
  # consumers (e.g. the OCEL forwarder) keep their evidence for a
  # consequence whose primary receipt commit is still pending.
  defp outbox_after_consequence(receipt, reason) do
    case ReceiptOutbox.append(receipt) do
      :ok ->
        :telemetry.execute(
          [:ash_a2a, :receipt, :outboxed],
          %{},
          %{receipt: receipt}
        )

        {:error,
         %{
           code: :receipt_commit_pending,
           detail:
             "consequence observed but store commit failed (#{inspect(reason)}); " <>
               "receipt durably outboxed pending reconciliation",
           original_reason: reason,
           receipt: receipt
         }}

      {:error, outbox_reason} ->
        {:error,
         %{
           code: :receipt_commit_failed,
           detail:
             "consequence observed; store commit failed (#{inspect(reason)}) AND outbox " <>
               "append failed (#{inspect(outbox_reason)}) -- receipt NOT durably recorded",
           original_reason: reason,
           outbox_reason: outbox_reason,
           receipt: receipt
         }}
    end
  end

  # Opportunistic reconciliation: when the outbox holds receipts, the next
  # `run/4` drains them into the (possibly recovered) store before claiming.
  # Best-effort by construction -- every `ReceiptOutbox` store call is
  # no-raise, and this wrapper guards even unexpected crashes so a broken
  # reconciliation can never block new commands from flowing.
  defp maybe_reconcile_outbox(store, store_opts) do
    if ReceiptOutbox.count() > 0 do
      ReceiptOutbox.reconcile(store, store_opts)
    end

    :ok
  rescue
    _error -> :ok
  catch
    :exit, _reason -> :ok
  end

  # `skill.consequence` -- computed once at compile time
  # (`AshA2A.CapabilityIndex.Compiler.project/3`) and carried as real
  # capability truth -- is the single source of consequence classification,
  # never recomputed here from `action.type` (see `AshA2A.Skill`'s
  # @moduledoc: `action.type` alone cannot distinguish a pure generic
  # `:action` from a real consequence-bearing one).
  defp inspect_target(command, resource_or_domain) do
    with {:ok, skill} <- AshA2A.Info.skill(resource_or_domain, command.capability_id),
         action when not is_nil(action) <- Ash.Resource.Info.action(skill.resource, skill.action) do
      {:ok, skill, action, skill.consequence}
    else
      {:error, :skill_not_found} -> {:error, refusal(:capability_not_found)}
      nil -> {:error, refusal(:action_not_found)}
    end
  end

  defp admit(_command, :observe), do: :ok

  defp admit(%Command{authority: %Authority{} = authority} = command, consequence)
       when consequence in [:change, :external_do] do
    if Authority.admits?(authority, command),
      do: :ok,
      else: {:error, refusal(:authority_mismatch)}
  end

  defp admit(_command, consequence) when consequence in [:change, :external_do] do
    {:error, refusal(:authority_required)}
  end

  # An unclassified generic `:action` skill must never bypass this DO
  # boundary by defaulting to either "safe to skip" (`:observe`) or "safe to
  # execute" (`:change`) -- it fails closed with a distinct, typed code
  # until a resource author explicitly classifies it
  # (`a2a do skill ..., consequence: :observe | :change | :external_do end`).
  defp admit(_command, :unknown), do: {:error, refusal(:consequence_unclassified)}

  defp refusal(reason), do: %{code: reason, detail: Atom.to_string(reason)}

  # `Receipt.from_reply/4` always sets `standing: :observed`. This upgrades
  # it to `:durable` only when the configured `store` module itself declares
  # real durability via a `durable?/0` function returning `true` -- checked
  # with `Code.ensure_loaded?/1` + `function_exported?/3`, the exact idiom
  # already used by `AshA2A.Durability.DurableServer`'s provider dispatch
  # and `AshA2A.Execution.FLAME.available?/0` -- rather than a hardcoded
  # allowlist of "known-durable" store modules. `AshA2A.ReceiptStore.Memory`
  # exports no such function, so its receipts are unaffected and stay
  # `:observed`.
  defp mark_standing(%Receipt{} = receipt, store) do
    if Code.ensure_loaded?(store) and function_exported?(store, :durable?, 0) and store.durable?() do
      %{receipt | standing: :durable}
    else
      receipt
    end
  end

  defp emit_receipt(receipt) do
    :telemetry.execute([:ash_a2a, :receipt, :committed], %{}, %{receipt: receipt})
  end

  # Marks this process, for the duration of the synchronous internal
  # `AshA2A.Dispatcher.dispatch/5` call below, so
  # `AshA2A.Telemetry.OcelForwarder`'s `[:ash_a2a, :dispatch, :stop]` handler
  # can tell a CommandBus-routed dispatch apart from a direct
  # `AshA2A.Dispatcher.dispatch/5` call and defer its OCEL POST until the
  # single `[:ash_a2a, :receipt, :committed]` event fires (via `emit_receipt/1`
  # above) instead of independently POSTing its own separate OCEL v2 event --
  # otherwise every CommandBus-routed dispatch produced two OCEL events for
  # one logical command.
  #
  # A plain process-dictionary flag (rather than an explicit argument threaded
  # through `AshA2A.Dispatcher.dispatch/5`, which would change that module's
  # public, already-consumed signature) is safe here because `:telemetry.span/3`
  # (`dispatcher.ex:137`) executes its function synchronously in the calling
  # process, per `:telemetry`'s own documented contract, and `run/4` is not
  # currently reentrant on the same process.
  defp dispatch_with_ocel_correlation(skill, message, resource_or_domain, opts) do
    Process.put(:ash_a2a_ocel_command_bus_dispatch, true)

    try do
      AshA2A.Dispatcher.dispatch(
        skill.name,
        message,
        resource_or_domain,
        Keyword.get(opts, :history, []),
        Keyword.get(opts, :auth_identity)
      )
    after
      Process.delete(:ash_a2a_ocel_command_bus_dispatch)
    end
  end

  # Same fail-closed, no-raise contract `claim_receipt/3` and
  # `commit_receipt/3` above already hold for the receipt store, applied to
  # the real dispatch path instead: an exception, throw, or exit raised
  # anywhere inside `dispatch_with_ocel_correlation/4` (resource-owned
  # action code, a data-layer failure, `AshA2A.Dispatcher` itself, ...)
  # must never propagate uncaught through `run/4` into the calling
  # `A2A.Agent` GenServer's `handle_call`. Left unguarded, such a crash
  # would both kill that GenServer AND leave the pre-dispatch claim
  # `claim_receipt/3` already wrote (a `%{fingerprint, execution_id,
  # receipt: nil}` reservation, `AshA2A.ReceiptStore.Memory.handle_call/3`'s
  # `{:claim, _}` clause) stuck at `receipt: nil` forever -- any retry with
  # the same fingerprint then matches that nil-receipt entry and returns
  # `{:error, :in_flight}` permanently, with no receipt ever committed for
  # the crash.
  #
  # Converts the crash into an ordinary `{:error, reason}` reply instead,
  # so it flows through the exact same `Receipt.from_reply/4` ->
  # `status/1` `{:error, _} -> :failed` clause every other dispatch error
  # reply already uses (no new receipt vocabulary needed) -- `run/4`'s
  # `{:execute, _}` branch then commits that receipt through the normal
  # commit path exactly as the success path does, closing the claim with a
  # typed, receipted `:failed` outcome instead of leaving it in-flight.
  defp safe_dispatch(skill, message, resource_or_domain, opts) do
    dispatch_with_ocel_correlation(skill, message, resource_or_domain, opts)
  rescue
    exception -> {:error, dispatch_crash_reason(:error, exception, __STACKTRACE__)}
  catch
    kind, reason -> {:error, dispatch_crash_reason(kind, reason, __STACKTRACE__)}
  end

  defp dispatch_crash_reason(kind, reason, stacktrace) do
    %{code: :dispatch_crashed, detail: Exception.format_banner(kind, reason, stacktrace)}
  end
end
