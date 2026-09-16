defmodule AshA2A.Reconciliation do
  @moduledoc """
  Durable-evidence classifier and reconciliation reader for CommandBus
  consequences (RFC-SA2A-002 §70, §71, §94).

  After a crash anywhere on the BRCE path the only admissible evidence is what
  survived the crashed process: the primary `AshA2A.ReceiptStore` and the
  filesystem `AshA2A.ReceiptOutbox`. `classify/3` reads exactly that evidence
  -- never a process return value, never process memory -- and names one of:

    * `:not_attempted` -- no receipt for the command anywhere and no
      unreadable outbox entry that could be its anchor. BRCE requires a
      durable anchor before DO, so no consequence can have begun.
    * `:prepared_unknown_outcome` -- the most final evidence is the pending
      pre-DO anchor (or a receipt whose status carries no outcome), or an
      unreadable outbox entry exists and the command has no other receipt.
      The consequence may or may not have happened; nothing is inferred.
    * `:executed` -- a finalized receipt with an observed non-error reply.
    * `:failed` -- a finalized receipt with an observed error reply.
    * `:reconciled` -- a pending outcome later resolved by `reconcile/4`
      against the external domain (`resolved_as: :executed | :not_executed`).
    * `:compensated` -- an executed consequence undone by a separately
      receipted compensation (`compensate/4`).

  When both stores hold evidence for one command the more final one wins
  (compensated/reconciled > finalized > pending): a finalized outboxed receipt
  is never masked by a pending anchor already drained into the primary store.

  ## Fail-closed

  An unavailable primary store is `{:error, :receipt_store_unavailable}`,
  never a guessed state. An unreadable (partially written / corrupted) outbox
  entry can never be attributed to a command id, so it forbids
  `:not_attempted` for every command without other evidence.

  ## Telemetry

    * `[:ash_a2a, :reconciliation, :classified]` -- `:command_id`, `:state`,
      `:source` (`:primary | :outbox | :none`), `:receipt_id`,
      `:receipt_status`, `:unreadable_outbox_entries`, `:label`
    * `[:ash_a2a, :reconciliation, :reconciled]` -- `:command_id`,
      `:before_state`, `:state`, `:resolved_as`, `:drained_committed`,
      `:drained_remaining`, `:outcome` (`:resolved | :unresolved | :unchanged
      | :refused`), `:label`
    * `[:ash_a2a, :reconciliation, :compensated]` -- `:command_id`,
      `:outcome` (`:compensated | :refused`), `:compensation_receipt_id`,
      `:code`, `:label`
  """

  alias AshA2A.{CommandBus, Identity, Receipt, ReceiptOutbox}

  @states [
    :not_attempted,
    :prepared_unknown_outcome,
    :executed,
    :failed,
    :reconciled,
    :compensated
  ]

  @executed_statuses [:completed, :input_required, :stream_opened]

  @type state ::
          :not_attempted
          | :prepared_unknown_outcome
          | :executed
          | :failed
          | :reconciled
          | :compensated

  @type classification :: %{
          command_id: String.t(),
          state: state(),
          source: :primary | :outbox | :none,
          receipt: Receipt.t() | nil,
          receipt_id: String.t() | nil,
          receipt_status: atom() | nil,
          durable_in_primary?: boolean(),
          outbox_entries: non_neg_integer(),
          unreadable_outbox_entries: non_neg_integer(),
          resolved_as: :executed | :not_executed | nil
        }

  @type probe_result :: {:executed, map()} | {:not_executed, map()} | :unknown

  @doc "The six durable-evidence states, in RFC-SA2A-002 §70 order."
  @spec states() :: [state()]
  def states, do: @states

  @doc false
  def __sa2a_refusal_codes__ do
    %{
      compensation_not_applicable: :refused_consequence,
      compensation_unconfirmed: :refused_receipt
    }
  end

  @doc """
  Classifies the durable evidence for `command_id`.

  Options: `:label` (opaque observation label carried in telemetry).
  """
  @spec classify(Identity.t(), module(), keyword(), keyword()) ::
          {:ok, classification()} | {:error, :receipt_store_unavailable}
  def classify(
        %Identity{kind: :command} = command_id,
        store \\ CommandBus.default_store(),
        store_opts \\ [],
        opts \\ []
      ) do
    case fetch_primary(store, command_id, store_opts) do
      {:error, reason} ->
        {:error, reason}

      primary ->
        classification = build_classification(command_id, primary)
        emit(:classified, classification_meta(classification, opts))
        {:ok, classification}
    end
  end

  @doc """
  Drains the outbox into the primary store (`CommandBus.reconcile_outboxed_receipts/2`),
  then, when the command is still `:prepared_unknown_outcome` in the primary
  store and a `:probe` is given, resolves the outcome against the external
  domain.

  `:probe` is `(Receipt.t() -> {:executed, evidence} | {:not_executed,
  evidence} | :unknown)`; it must read the external system by the command's
  actuation identity and must not actuate. Precondition for a resolving
  probe: no live executor for this command remains (e.g. after a restart);
  an `:unknown` probe leaves the pending anchor untouched.

  The resolved receipt keeps its receipt id and replaces the pending anchor in
  the primary store, so a later duplicate submission replays it and never
  actuates again.
  """
  @spec reconcile(Identity.t(), module(), keyword(), keyword()) ::
          {:ok, map()} | {:error, :receipt_store_unavailable}
  def reconcile(
        %Identity{kind: :command} = command_id,
        store \\ CommandBus.default_store(),
        store_opts \\ [],
        opts \\ []
      ) do
    label = Keyword.get(opts, :label)

    with {:ok, before} <-
           classify(command_id, store, store_opts, label: label && "#{label}.before"),
         {:ok, drain} <- CommandBus.reconcile_outboxed_receipts(store, store_opts),
         {:ok, drained} <-
           classify(command_id, store, store_opts, label: label && "#{label}.drained") do
      {outcome, final} = resolve(drained, store, store_opts, Keyword.get(opts, :probe))

      emit(:reconciled, %{
        command_id: command_id.value,
        before_state: before.state,
        state: final.state,
        resolved_as: final.resolved_as,
        drained_committed: drain.committed,
        drained_remaining: drain.remaining,
        outcome: outcome,
        label: label
      })

      {:ok, %{before: before, after: final, drain: drain, outcome: outcome}}
    end
  end

  @doc """
  Records a compensation of an executed consequence.

  `compensation` runs the compensating consequence (it must itself cross the
  BRCE boundary, e.g. `CommandBus.run/4` of a compensating capability) and
  return `{:ok, %Receipt{status: :completed}}`. Only an `:executed` or
  `:reconciled`-as-executed command can be compensated; the original receipt
  keeps its identity and gains `metadata.outcome: :compensated` plus the
  compensation receipt id.
  """
  @spec compensate(Identity.t(), module(), keyword(), (Receipt.t() -> term()), keyword()) ::
          {:ok, classification()} | {:error, map()}
  def compensate(
        %Identity{kind: :command} = command_id,
        store,
        store_opts,
        compensation,
        opts \\ []
      )
      when is_function(compensation, 1) do
    label = Keyword.get(opts, :label)

    with {:ok, current} <- classify(command_id, store, store_opts, label: label),
         :ok <- compensable(current),
         {:ok, comp} <- run_compensation(compensation, current),
         compensated = mark_compensated(current.receipt, comp),
         :ok <- safe_commit(store, compensated, store_opts),
         {:ok, final} <- classify(command_id, store, store_opts, label: label) do
      emit(:compensated, %{
        command_id: command_id.value,
        outcome: :compensated,
        compensation_receipt_id: identity_value(comp.receipt_id),
        label: label
      })

      {:ok, final}
    else
      {:error, :receipt_store_unavailable} = error ->
        refuse_compensation(command_id, :receipt_store_unavailable, label)
        error

      {:error, %{code: code}} = error ->
        refuse_compensation(command_id, code, label)
        error

      other ->
        refuse_compensation(command_id, :compensation_unconfirmed, label)
        {:error, %{code: :compensation_unconfirmed, detail: inspect(other, limit: 10)}}
    end
  end

  # --- classification -------------------------------------------------------

  defp build_classification(%Identity{} = command_id, primary) do
    readable = ReceiptOutbox.entries()
    unreadable = max(ReceiptOutbox.count() - length(readable), 0)
    outboxed = Enum.filter(readable, &(&1.command_id == command_id))

    primary_receipt =
      case primary do
        {:ok, %Receipt{} = receipt} -> receipt
        _ -> nil
      end

    # Primary first: `Enum.max_by/3` keeps the first maximal element, so on
    # equal finality the durable primary copy is the one reported.
    candidates =
      Enum.map(List.wrap(primary_receipt), &{:primary, &1}) ++
        Enum.map(outboxed, &{:outbox, &1})

    {source, receipt} = Enum.max_by(candidates, fn {_s, r} -> rank(r) end, fn -> {:none, nil} end)

    %{
      command_id: command_id.value,
      state: state(receipt, unreadable),
      source: source,
      receipt: receipt,
      receipt_id: receipt && identity_value(receipt.receipt_id),
      receipt_status: receipt && receipt.status,
      durable_in_primary?: source == :primary,
      outbox_entries: length(outboxed),
      unreadable_outbox_entries: unreadable,
      resolved_as: resolved_as(receipt)
    }
  end

  defp resolved_as(%Receipt{metadata: %{reconciliation: %{resolved_as: resolved}}}), do: resolved
  defp resolved_as(_), do: nil

  defp rank(nil), do: -1

  defp rank(%Receipt{} = receipt) do
    case {outcome(receipt), receipt.status} do
      {:compensated, _} -> 3
      {:reconciled, _} -> 2
      {_, status} when status in [:pending, :unknown] -> 0
      _ -> 1
    end
  end

  defp state(nil, 0), do: :not_attempted
  defp state(nil, _unreadable), do: :prepared_unknown_outcome

  defp state(%Receipt{} = receipt, _unreadable) do
    case {outcome(receipt), receipt.status} do
      {:compensated, _} -> :compensated
      {:reconciled, _} -> :reconciled
      {_, :failed} -> :failed
      {_, status} when status in @executed_statuses -> :executed
      _ -> :prepared_unknown_outcome
    end
  end

  defp outcome(%Receipt{metadata: metadata}) when is_map(metadata),
    do: Map.get(metadata, :outcome)

  defp outcome(_), do: nil

  # --- reconciliation -------------------------------------------------------

  defp resolve(
         %{state: :prepared_unknown_outcome, source: :primary} = c,
         store,
         store_opts,
         probe
       )
       when is_function(probe, 1) do
    case safe_probe(probe, c.receipt) do
      {resolved_as, evidence}
      when resolved_as in [:executed, :not_executed] and is_map(evidence) ->
        receipt = mark_reconciled(c.receipt, resolved_as, evidence)

        with :ok <- safe_commit(store, receipt, store_opts),
             {:ok, final} <- classify_quiet(c, store, store_opts) do
          {:resolved, final}
        else
          _ -> {:unresolved, c}
        end

      _unknown ->
        {:unresolved, c}
    end
  end

  defp resolve(%{state: :prepared_unknown_outcome} = c, _store, _store_opts, _probe),
    do: {:unresolved, c}

  defp resolve(c, _store, _store_opts, _probe), do: {:unchanged, c}

  defp classify_quiet(c, store, store_opts) do
    command_id = Identity.command(c.command_id)

    case fetch_primary(store, command_id, store_opts) do
      {:error, reason} -> {:error, reason}
      primary -> {:ok, build_classification(command_id, primary)}
    end
  end

  defp mark_reconciled(%Receipt{} = receipt, resolved_as, evidence) do
    %{
      receipt
      | status: if(resolved_as == :executed, do: :completed, else: :failed),
        recorded_at: DateTime.utc_now(),
        metadata:
          receipt.metadata
          |> Map.put(:outcome, :reconciled)
          |> Map.put(:reconciliation, %{
            resolved_as: resolved_as,
            prior_status: receipt.status,
            evidence: evidence,
            reconciled_at: DateTime.utc_now()
          })
    }
  end

  defp safe_probe(probe, receipt) do
    probe.(receipt)
  rescue
    _ -> :unknown
  catch
    _kind, _reason -> :unknown
  end

  # --- compensation ---------------------------------------------------------

  defp compensable(%{state: :executed}), do: :ok
  defp compensable(%{state: :reconciled, resolved_as: :executed}), do: :ok

  defp compensable(%{state: state}),
    do:
      {:error,
       %{code: :compensation_not_applicable, detail: "cannot compensate a #{state} consequence"}}

  defp run_compensation(compensation, %{receipt: receipt}) do
    case compensation.(receipt) do
      {:ok, %Receipt{status: :completed} = comp} ->
        {:ok, comp}

      other ->
        {:error,
         %{
           code: :compensation_unconfirmed,
           detail:
             "compensation did not return a completed receipt: " <> inspect(other, limit: 10)
         }}
    end
  rescue
    exception ->
      {:error, %{code: :compensation_unconfirmed, detail: Exception.message(exception)}}
  catch
    kind, reason -> {:error, %{code: :compensation_unconfirmed, detail: inspect({kind, reason})}}
  end

  defp mark_compensated(%Receipt{} = receipt, %Receipt{} = compensation) do
    %{
      receipt
      | status: :compensated,
        recorded_at: DateTime.utc_now(),
        metadata:
          receipt.metadata
          |> Map.put(:outcome, :compensated)
          |> Map.put(:compensation, %{
            receipt_id: compensation.receipt_id,
            command_id: compensation.command_id,
            prior_status: receipt.status,
            compensated_at: DateTime.utc_now()
          })
    }
  end

  defp refuse_compensation(command_id, code, label) do
    emit(:compensated, %{
      command_id: command_id.value,
      outcome: :refused,
      code: code,
      label: label
    })
  end

  # --- store access -----------------------------------------------------------

  defp fetch_primary(store, command_id, store_opts) do
    case store.fetch(command_id, store_opts) do
      {:ok, %Receipt{}} = ok -> ok
      _ -> :error
    end
  rescue
    _ -> {:error, :receipt_store_unavailable}
  catch
    :exit, _ -> {:error, :receipt_store_unavailable}
  end

  defp safe_commit(store, receipt, store_opts) do
    case store.commit(receipt, store_opts) do
      :ok -> :ok
      _ -> {:error, :receipt_store_unavailable}
    end
  rescue
    _ -> {:error, :receipt_store_unavailable}
  catch
    :exit, _ -> {:error, :receipt_store_unavailable}
  end

  # --- telemetry --------------------------------------------------------------

  defp classification_meta(c, opts) do
    %{
      command_id: c.command_id,
      state: c.state,
      source: c.source,
      receipt_id: c.receipt_id,
      receipt_status: c.receipt_status,
      durable_in_primary: c.durable_in_primary?,
      unreadable_outbox_entries: c.unreadable_outbox_entries,
      resolved_as: c.resolved_as,
      label: Keyword.get(opts, :label)
    }
  end

  defp emit(event, metadata) do
    :telemetry.execute(
      [:ash_a2a, :reconciliation, event],
      %{system_time: System.system_time()},
      metadata
    )
  end

  defp identity_value(%Identity{value: value}), do: value
  defp identity_value(value), do: value
end
