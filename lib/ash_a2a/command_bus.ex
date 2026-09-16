defmodule AshA2A.CommandBus do
  @moduledoc """
  Canonical receipted route from an admitted `AshA2A.Command` to the existing
  Ash dispatcher. Planning and provider adapters may call this module; they do
  not bypass its capability, identity, replay, or evidence checks.

  "Replay" is idempotent command re-submission / command dedup, not process
  mining trace replay.

  ## Consequence/receipt state machine

  Consequence-bearing work now crosses a receipt boundary before DO:

      ADMITTED
        -> CLAIMED
        -> RECEIPT_ANCHORED (:pending, same receipt identity)
        -> EXECUTING
        -> CONSEQUENCE_OBSERVED
        -> RECEIPT_DURABLE | RECEIPT_OUTBOXED

  `RECEIPT_ANCHORED` is mandatory for `:change` and `:external_do`. If the
  outbox cannot persist that anchor, dispatch is refused. The finalized receipt
  preserves the anchor's receipt id. If both primary commit and final outbox
  replacement fail after DO, the pending anchor remains as replay-blocking
  evidence without inventing an outcome.

  The configured retry delays are true retries: there is one immediate primary
  commit attempt plus one additional attempt after each configured delay.

  ## Boundary telemetry

  Each transition emits a real `[:ash_a2a, :command_bus, ...]` event at the
  boundary itself (RFC-SA2A-002 §18: evidence from a surface distinct from the
  actuator's return value). Metadata always carries `:command_id`,
  `:capability_id`, `:principal_id`; `:outcome` names what the boundary decided.

    * `[:target]` -- `:resolved | :refused` (+ `:code`, `:consequence`)
    * `[:admission]` -- `:admitted | :refused` (+ `:code`, `:consequence`)
    * `[:kill_switch]` -- `:clear | :tripped`
    * `[:claim]` -- `:execute | :replay | :refused` (+ `:execution_id`)
    * `[:prepare]` -- `:prepared | :not_required | :failed` (+ `:receipt_id`)
    * `[:actuate, :start]` / `[:actuate, :stop]` -- around the one dispatch
      (+ `:execution_id`, `:receipt_id`, stop `:outcome` `:ok | :error`)
    * `[:postcondition]` -- `:verified | :contradicted | :unverified` after DO
      (+ `:reason`, `:postcondition_id`, `:verifier`, `:independent`); not
      emitted for an `:observe` command with no `:postcondition` option
    * `[:commit]` -- `:committed | :outboxed | :failed` (+ `:receipt_id`)

  ## Independent postcondition

  `opts[:postcondition]` (an `AshA2A.Postcondition`) declares the intended
  effect. The observation lands in `receipt.metadata.postcondition`; a
  `:contradicted` one sets status `:postcondition_contradicted` and returns
  `{:error, %{code: :postcondition_contradicted}}`. See `AshA2A.Postcondition`.
  """

  alias AshA2A.{Authority, Command, Identity, KillSwitch, Postcondition, Receipt, ReceiptOutbox}

  @type result :: {:ok, Receipt.t()} | {:error, map()}

  @spec default_store() :: module()
  def default_store do
    Application.get_env(:ash_a2a, :receipt_store, AshA2A.ReceiptStore.Memory)
  end

  @doc "Drains the receipt outbox into the configured primary store."
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

    with {:ok, skill, _action, consequence} <-
           observe_target(command, inspect_target(command, resource_or_domain)),
         :ok <- observe_admission(command, consequence, admit(command, consequence)),
         :ok <- observe_kill_switch(command, check_kill_switch(opts)),
         claim <- observe_claim(command, claim_receipt(store, command, store_opts)) do
      case claim do
        {:replay, receipt} ->
          {:ok, receipt}

        {:execute, %Identity{kind: :execution} = execution_id} ->
          execute_claimed(
            command,
            execution_id,
            consequence,
            skill,
            message,
            resource_or_domain,
            store,
            store_opts,
            opts
          )

        {:error, reason} ->
          {:error, refusal(reason)}
      end
    end
  end

  defp execute_claimed(
         command,
         execution_id,
         consequence,
         skill,
         message,
         resource_or_domain,
         store,
         store_opts,
         opts
       ) do
    case observe_prepare(
           command,
           execution_id,
           prepare_receipt_anchor(command, execution_id, consequence)
         ) do
      {:ok, anchor} ->
        reply =
          actuate(command, execution_id, anchor, consequence, fn ->
            safe_dispatch(skill, message, resource_or_domain, opts)
          end)

        postcondition =
          observe_postcondition(command, execution_id, anchor, consequence, reply, opts)

        receipt =
          case anchor do
            %Receipt{} -> Receipt.finalize(anchor, reply)
            nil -> Receipt.from_reply(command, execution_id, consequence, reply)
          end
          |> Postcondition.apply_to_receipt(postcondition)
          |> mark_standing(store)

        store
        |> commit_receipt(receipt, store_opts)
        |> Postcondition.consequence_result(postcondition)

      {:error, reason} ->
        refuse_unanchored_execution(
          store,
          command,
          execution_id,
          consequence,
          store_opts,
          reason
        )
    end
  end

  defp prepare_receipt_anchor(command, execution_id, consequence)
       when consequence in [:change, :external_do] do
    receipt = Receipt.pending(command, execution_id, consequence)

    case ReceiptOutbox.append(receipt) do
      :ok -> {:ok, receipt}
      {:error, reason} -> {:error, reason}
    end
  end

  defp prepare_receipt_anchor(_command, _execution_id, :observe), do: {:ok, nil}

  defp refuse_unanchored_execution(
         store,
         command,
         execution_id,
         consequence,
         store_opts,
         anchor_reason
       ) do
    reply =
      {:error,
       %{
         code: :receipt_anchor_unavailable,
         detail: "consequence dispatch refused because receipt anchor could not be persisted",
         reason: anchor_reason
       }}

    receipt =
      command
      |> Receipt.from_reply(execution_id, consequence, reply)
      |> mark_standing(store)

    delays = Application.get_env(:ash_a2a, :receipt_commit_retry_delays_ms, [50, 150])

    commit_result = commit_with_retries(store, receipt, store_opts, delays)

    if commit_result == :ok do
      emit_receipt(receipt)
    end

    {:error,
     %{
       code: :receipt_anchor_unavailable,
       detail: "consequence dispatch refused before DO because receipt anchor is unavailable",
       anchor_reason: anchor_reason,
       receipt: receipt,
       primary_receipt_commit: commit_result
     }}
  end

  defp claim_receipt(store, command, store_opts) do
    store.claim(command, store_opts)
  rescue
    _error -> {:error, :receipt_store_unavailable}
  catch
    :exit, _reason -> {:error, :receipt_store_unavailable}
  end

  defp commit_receipt(store, receipt, store_opts) do
    delays = Application.get_env(:ash_a2a, :receipt_commit_retry_delays_ms, [50, 150])

    case commit_with_retries(store, receipt, store_opts, delays) do
      :ok ->
        ReceiptOutbox.remove(receipt)
        emit_receipt(receipt)

        emit_boundary([:commit], receipt, %{
          outcome: :committed,
          receipt_id: identity_value(receipt.receipt_id)
        })

        {:ok, receipt}

      {:error, reason} ->
        result = outbox_after_consequence(receipt, reason)

        outcome =
          case result do
            {:error, %{code: :receipt_commit_pending}} -> :outboxed
            _ -> :failed
          end

        emit_boundary([:commit], receipt, %{
          outcome: outcome,
          receipt_id: identity_value(receipt.receipt_id)
        })

        result
    end
  end

  defp commit_with_retries(store, receipt, store_opts, delays) do
    case commit_once(store, receipt, store_opts) do
      :ok -> :ok
      {:error, reason} -> retry_commit(store, receipt, store_opts, delays, reason)
    end
  end

  defp retry_commit(_store, _receipt, _store_opts, [], last_reason),
    do: {:error, last_reason}

  defp retry_commit(store, receipt, store_opts, [delay | rest], _last_reason) do
    Process.sleep(delay)

    case commit_once(store, receipt, store_opts) do
      :ok -> :ok
      {:error, reason} -> retry_commit(store, receipt, store_opts, rest, reason)
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
             "consequence observed; primary receipt commit failed and finalized receipt is outboxed",
           original_reason: reason,
           receipt: receipt
         }}

      {:error, outbox_reason} ->
        if ReceiptOutbox.anchored?(receipt) do
          {:error,
           %{
             code: :receipt_commit_pending,
             detail:
               "consequence observed; final receipt persistence failed but pre-dispatch pending receipt anchor remains",
             original_reason: reason,
             outbox_reason: outbox_reason,
             outcome_durable?: false,
             receipt: receipt
           }}
        else
          {:error,
           %{
             code: :receipt_commit_failed,
             detail:
               "receipt persistence failed and no receipt anchor remains; consequence outcome is not durably recorded",
             original_reason: reason,
             outbox_reason: outbox_reason,
             receipt: receipt
           }}
        end
    end
  end

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

  defp admit(_command, :unknown), do: {:error, refusal(:consequence_unclassified)}

  # Strictly opt-in: `opts[:kill_switch_class]` is absent (`nil`) for every
  # existing caller today, so this always short-circuits to `:ok` and `run/4`
  # is byte-for-byte unchanged for them. A caller that explicitly names a
  # class is checked against the real `AshA2A.KillSwitch.tripped?/1` state
  # for that class, refusing before `claim_receipt/3` (and therefore before
  # any receipt is claimed or DO ever runs) when it is tripped.
  defp check_kill_switch(opts) do
    case Keyword.get(opts, :kill_switch_class) do
      nil ->
        :ok

      class ->
        case KillSwitch.tripped?(class) do
          {true, reason} -> {:error, %{code: :kill_switch_tripped, detail: reason}}
          false -> :ok
        end
    end
  end

  defp refusal(reason), do: %{code: reason, detail: Atom.to_string(reason)}

  # --- boundary telemetry (see moduledoc) -----------------------------------

  defp observe_target(command, {:ok, _skill, _action, consequence} = ok) do
    emit_boundary([:target], command, %{outcome: :resolved, consequence: consequence})
    ok
  end

  defp observe_target(command, {:error, %{code: code}} = error) do
    emit_boundary([:target], command, %{outcome: :refused, code: code})
    error
  end

  defp observe_admission(command, consequence, :ok) do
    emit_boundary([:admission], command, %{outcome: :admitted, consequence: consequence})
    :ok
  end

  defp observe_admission(command, consequence, {:error, %{code: code}} = error) do
    emit_boundary([:admission], command, %{
      outcome: :refused,
      code: code,
      consequence: consequence
    })

    error
  end

  defp observe_kill_switch(command, :ok) do
    emit_boundary([:kill_switch], command, %{outcome: :clear})
    :ok
  end

  defp observe_kill_switch(command, {:error, %{code: code}} = error) do
    emit_boundary([:kill_switch], command, %{outcome: :tripped, code: code})
    error
  end

  defp observe_claim(command, {:execute, execution_id} = claim) do
    emit_boundary([:claim], command, %{
      outcome: :execute,
      execution_id: identity_value(execution_id)
    })

    claim
  end

  defp observe_claim(command, {:replay, receipt} = claim) do
    emit_boundary([:claim], command, %{
      outcome: :replay,
      receipt_id: identity_value(receipt.receipt_id)
    })

    claim
  end

  defp observe_claim(command, {:error, reason} = claim) do
    emit_boundary([:claim], command, %{outcome: :refused, code: reason})
    claim
  end

  defp observe_claim(_command, other), do: other

  defp observe_prepare(command, execution_id, {:ok, anchor} = ok) do
    {outcome, receipt_id} =
      case anchor do
        %Receipt{receipt_id: id} -> {:prepared, identity_value(id)}
        nil -> {:not_required, nil}
      end

    emit_boundary([:prepare], command, %{
      outcome: outcome,
      receipt_id: receipt_id,
      execution_id: identity_value(execution_id)
    })

    ok
  end

  defp observe_prepare(command, execution_id, {:error, reason} = error) do
    emit_boundary([:prepare], command, %{
      outcome: :failed,
      code: :receipt_anchor_unavailable,
      reason: inspect(reason),
      execution_id: identity_value(execution_id)
    })

    error
  end

  defp actuate(command, execution_id, anchor, consequence, fun) do
    meta = %{
      execution_id: identity_value(execution_id),
      receipt_id: anchor && identity_value(anchor.receipt_id),
      consequence: consequence
    }

    emit_boundary([:actuate, :start], command, meta)
    reply = fun.()

    outcome =
      case reply do
        {:error, _} -> :error
        _ -> :ok
      end

    emit_boundary([:actuate, :stop], command, Map.put(meta, :outcome, outcome))
    reply
  end

  # Independent postcondition observation (RFC-SA2A-002 §39, §73): evaluated
  # after DO by a verifier reading post-state through its own path, never by
  # trusting `reply`. See `AshA2A.Postcondition`.
  defp observe_postcondition(command, execution_id, anchor, consequence, reply, opts) do
    probe = %Postcondition.Probe{
      command_id: identity_value(command.command_id),
      capability_id: command.capability_id,
      execution_id: identity_value(execution_id),
      receipt_id: anchor && identity_value(anchor.receipt_id),
      consequence: consequence,
      command_input: command.input,
      actuator_report: reply
    }

    case Postcondition.evaluate(Keyword.get(opts, :postcondition), probe, opts) do
      nil ->
        nil

      observation ->
        emit_boundary(
          [:postcondition],
          command,
          observation
          |> Postcondition.telemetry_metadata()
          |> Map.merge(%{
            execution_id: probe.execution_id,
            receipt_id: probe.receipt_id,
            consequence: consequence
          })
        )

        observation
    end
  end

  defp emit_boundary(suffix, %{command_id: command_id} = subject, extra) do
    :telemetry.execute(
      [:ash_a2a, :command_bus | suffix],
      %{system_time: System.system_time()},
      Map.merge(
        %{
          command_id: identity_value(command_id),
          capability_id: Map.get(subject, :capability_id),
          principal_id: identity_value(Map.get(subject, :principal_id))
        },
        extra
      )
    )
  end

  defp identity_value(%Identity{value: value}), do: value
  defp identity_value(value), do: value

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
