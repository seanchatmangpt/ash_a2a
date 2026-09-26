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

  ## RFC-SA2A-001 S55 actuation identity

  The command claim above dedups *requests*. A client that retries by minting
  a fresh `command_id` defeats it and crosses the consequence boundary twice.
  S55 closes that with a second, effect-keyed index:

      ADMITTED
        -> CLAIMED                     (command_id, existing)
        -> ACTUATION_CLAIMED           (AshA2A.Actuation effect identity, S55)
        -> RECEIPT_ANCHORED
        -> EXECUTING
        -> ...
        -> ACTUATION_COMMITTED

  `ACTUATION_CLAIMED` runs only for `:change`/`:external_do`, and only when the
  configured store implements the optional
  `c:AshA2A.ReceiptStore.claim_actuation/3` (checked with
  `function_exported?/3`, the same idiom `mark_standing/2` already uses for
  `durable?/0`). A store without it behaves exactly as before. When the claim
  reports `{:duplicate, prior}`, the bus commits a *dedup receipt* under the
  new command id -- closing that claim rather than leaving it dangling at
  `receipt: nil` -- and returns the prior outcome without dispatching.

  Every receipt now also carries the S31 prepared-receipt fields (see
  `AshA2A.Receipt`), including the actuation and idempotency identities, for
  `:observe` commands too; only the *enforcement* is scoped to consequence.

  ## Boundary telemetry

  Each transition emits a real `[:ash_a2a, :command_bus, ...]` event at the
  boundary itself (RFC-SA2A-002 §18: evidence from a surface distinct from the
  actuator's return value). Metadata always carries `:command_id`,
  `:capability_id`, `:principal_id`; `:outcome` names what the boundary decided.

    * `[:target]` -- `:resolved | :refused` (+ `:code`, `:consequence`)
    * `[:preflight]` -- plan steps only (`opts[:plan]` / `opts[:preflight]`):
      `:verified | :refused` (+ `:code`, `:fields`, `:plan_digest`,
      `:preflight_digest`), see `AshA2A.Planning.Preflight.admit_step/3`
    * `[:admission]` -- `:admitted | :refused` (+ `:code`, `:consequence`)
    * `[:commitment]` -- deterministic `:authorized | :prepared | :refused` standing projection; observation only, never authority
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

  ## Sustained-load tail-latency SLO (v26.9.17, ticket b4p-f5-02)

  Under sustained concurrent dispatch, `run/4`'s late-half p99 latency must
  stay within **3.0x** of its early-half p99 (`degradation_ratio_p99 <= 3.0`,
  zero dispatch errors). The standing tripwire enforcing this is
  `AshA2A.Chicago.Stress.CommandBusTailLatencyTripwireTest` (excluded from
  the default suite like all `:benchmark` files; run explicitly with
  `--include benchmark`).

  The bound is 2x headroom over the worst non-pathological ratio measured
  for the default `AshA2A.ReceiptStore.Memory` backend (1.274x-1.515x,
  `docs/archive/reports/v26.9.17-commandbus-scale.md`), versus the pathological
  181x observed under heavy external host contention
  (`docs/archive/reports/v26.9.17-stress-report.md`). Mechanism: `Memory` is a
  single `GenServer` -- every claim/actuation-claim/commit funnels through
  one mailbox, so when the store process is descheduled under contention,
  queued calls pile up and the *tail* (p99) climbs; the tripwire samples the
  store's real mailbox length so a trip arrives with that evidence attached.
  Callers needing the tightest tail guarantee on contended hosts configure
  `config :ash_a2a, :receipt_store, AshA2A.ReceiptStore.Ekv` (measured
  0.812x-1.072x on the same metric, same scale document; a durability
  trade, not a free win -- read that document's absolute numbers first).

  """

  alias AshA2A.{
    Actuation,
    Authority,
    CapabilityRelease,
    Command,
    ConditionalCommitment,
    Identity,
    KillSwitch,
    Postcondition,
    Receipt,
    ReceiptOutbox
  }

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
         :ok <- enforce_release_closure(skill, opts),
         {:ok, opts} <- preflight_plan_step(command, opts),
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

  # v26.9.26 RACaP boundary: when strict release mode is enabled, a
  # capability is executable only if its exact A2A skill id is present in the
  # frozen released closure. Candidate/admitted/retired artifacts remain
  # powerless even if they are otherwise present in the compiled capability
  # index. The closure is evidence identity, not authority; normal BRCE
  # admission still follows this gate.
  defp enforce_release_closure(skill, opts) do
    case CapabilityRelease.guard(skill.id, opts) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error,
         %{
           code: :capability_release_refused,
           detail: "capability is outside the frozen released execution closure",
           reason: reason
         }}
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
    actuation = Actuation.identity(command, opts)
    receipt_opts = receipt_opts(actuation, opts)

    case claim_actuation(store, actuation, command, consequence, store_opts, opts) do
      :proceed ->
        dispatch_actuation_claimed(
          command,
          execution_id,
          consequence,
          skill,
          message,
          resource_or_domain,
          store,
          store_opts,
          opts,
          actuation,
          receipt_opts
        )

      {:duplicate, prior} ->
        close_claim_as_duplicate(
          store,
          command,
          execution_id,
          consequence,
          store_opts,
          receipt_opts,
          prior
        )

      {:error, reason}
      when reason in [:actuation_in_flight, :actuation_conflict, :actuation_store_unavailable] ->
        refuse_actuation(
          store,
          command,
          execution_id,
          consequence,
          store_opts,
          receipt_opts,
          reason
        )
    end
  end

  defp dispatch_actuation_claimed(
         command,
         execution_id,
         consequence,
         skill,
         message,
         resource_or_domain,
         store,
         store_opts,
         opts,
         actuation,
         receipt_opts
       ) do
    case observe_prepare(
           command,
           execution_id,
           consequence,
           prepare_receipt_anchor(command, execution_id, consequence, receipt_opts)
         ) do
      {:ok, anchor} ->
        reply =
          actuate(command, execution_id, anchor, consequence, fn ->
            safe_dispatch(skill, message, resource_or_domain, opts, anchor)
          end)

        postcondition =
          observe_postcondition(command, execution_id, anchor, consequence, reply, opts)

        receipt =
          case anchor do
            %Receipt{} ->
              Receipt.finalize(anchor, reply)

            nil ->
              Receipt.from_reply(command, execution_id, consequence, reply, receipt_opts)
          end
          |> Postcondition.apply_to_receipt(postcondition)
          |> mark_standing(store)

        commit_actuation(store, actuation, receipt, consequence, store_opts, opts)

        store
        |> commit_receipt(receipt, store_opts)
        |> Postcondition.consequence_result(postcondition)

      {:error, reason} ->
        release_actuation(store, actuation, consequence, store_opts, opts)

        refuse_unanchored_execution(
          store,
          command,
          execution_id,
          consequence,
          store_opts,
          receipt_opts,
          reason
        )
    end
  end

  # The command-id claim is already open (`receipt: nil`) by the time an
  # actuation duplicate is detected, so it must be closed with a real receipt
  # or a later retry of this same command id would hit a permanent
  # `{:error, :in_flight}`. The dedup receipt is a genuine receipt for THIS
  # command: same terminal status as the prior outcome, and metadata naming
  # the prior receipt it deduplicated against. It does NOT claim a second
  # execution occurred.
  defp close_claim_as_duplicate(
         store,
         command,
         execution_id,
         consequence,
         store_opts,
         receipt_opts,
         %Receipt{} = prior
       ) do
    receipt =
      command
      |> Receipt.from_reply(execution_id, consequence, prior.reply, receipt_opts)
      |> mark_standing(store)
      |> Map.put(:replayed?, true)
      |> then(fn receipt ->
        Receipt.Binding.transition(
          receipt,
          %{
            receipt
            | terminal_status: prior.terminal_status,
              status: prior.status,
              metadata:
                Map.merge(receipt.metadata, %{
                  outcome: :deduplicated,
                  deduplicated_from_receipt_id: Identity.external(prior.receipt_id),
                  deduplicated_from_command_id: Identity.external(prior.command_id)
                })
          },
          :deduplicated
        )
      end)

    case commit_with_retries(
           store,
           receipt,
           store_opts,
           Application.get_env(:ash_a2a, :receipt_commit_retry_delays_ms, [50, 150])
         ) do
      :ok ->
        emit_receipt(receipt)
        {:ok, receipt}

      {:error, _reason} ->
        {:ok, receipt}
    end
  end

  defp refuse_actuation(
         store,
         command,
         execution_id,
         consequence,
         store_opts,
         receipt_opts,
         reason
       ) do
    reply =
      {:error,
       %{
         code: reason,
         detail: actuation_refusal_detail(reason)
       }}

    receipt =
      command
      |> Receipt.from_reply(execution_id, consequence, reply, receipt_opts)
      |> mark_standing(store)

    commit_with_retries(
      store,
      receipt,
      store_opts,
      Application.get_env(:ash_a2a, :receipt_commit_retry_delays_ms, [50, 150])
    )

    {:error, %{code: reason, detail: actuation_refusal_detail(reason), receipt: receipt}}
  end

  defp actuation_refusal_detail(:actuation_store_unavailable),
    do: "actuation claim store is unavailable; refusing consequence before DO"

  defp actuation_refusal_detail(_reason),
    do:
      "actuation identity is already claimed for this effect; refusing to repeat the consequence"

  defp receipt_opts(%Actuation{} = actuation, opts) do
    [actuation: actuation]
    |> maybe_put(:plan_digest, Keyword.get(opts, :plan_digest))
    |> maybe_put(:evidence_class, Keyword.get(opts, :evidence_class))
    |> maybe_put(:intended_effect, Keyword.get(opts, :intended_effect))
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  @doc """
  The RFC-SA2A-001 S55 actuation dedup mode currently in force.

    * `:declared` (default) -- enforce only for a command that carries an
      explicit idempotency token (`metadata[:idempotency_key]`, the authority's
      `:external_idempotency_token` constraint, or `opts[:idempotency_key]`).
    * `:strict` -- enforce on the derived effect digest alone, so two distinct
      command ids naming the same effect deduplicate even with no declared
      token.
    * `:off` -- never actuation-claim; command-id claiming only.

  `:declared` is the default deliberately. With no client-declared key, "same
  capability, same principal, same input, again" is genuinely ambiguous between
  a dropped-response retry and a second intentional request -- creating two
  identically-labelled records is a real, legitimate operation. Silently
  collapsing those would refuse real work on the strength of a guess. S55's
  requirement is met the way S55 words it: the identities are always derived
  and always recorded on the receipt, and BRCE detects and refuses a repeat
  whenever the caller has actually declared the effect idempotent. `:strict` is
  available for a deployment whose capabilities are all genuinely idempotent.
  """
  @spec actuation_dedup_mode(keyword()) :: :declared | :strict | :off
  def actuation_dedup_mode(opts \\ []) do
    Keyword.get(opts, :actuation_dedup) ||
      Application.get_env(:ash_a2a, :actuation_dedup, :declared)
  end

  defp claim_actuation(store, actuation, command, consequence, store_opts, opts)
       when consequence in [:change, :external_do] do
    if enforce_actuation?(store, actuation, opts) do
      store.claim_actuation(actuation, command, store_opts)
    else
      :proceed
    end
  rescue
    _error -> {:error, :actuation_store_unavailable}
  catch
    :exit, _reason -> {:error, :actuation_store_unavailable}
  end

  defp claim_actuation(_store, _actuation, _command, _consequence, _store_opts, _opts),
    do: :proceed

  defp enforce_actuation?(store, %Actuation{} = actuation, opts) do
    actuation_aware?(store) and
      case actuation_dedup_mode(opts) do
        :strict -> true
        :declared -> actuation.external_token?
        _ -> false
      end
  end

  defp commit_actuation(store, actuation, receipt, consequence, store_opts, opts)
       when consequence in [:change, :external_do] do
    if enforce_actuation?(store, actuation, opts),
      do: store.commit_actuation(actuation, receipt, store_opts),
      else: :ok
  rescue
    _error -> :ok
  catch
    :exit, _reason -> :ok
  end

  defp commit_actuation(_store, _actuation, _receipt, _consequence, _store_opts, _opts), do: :ok

  defp release_actuation(store, actuation, consequence, store_opts, opts)
       when consequence in [:change, :external_do] do
    if enforce_actuation?(store, actuation, opts),
      do: store.release_actuation(actuation, store_opts),
      else: :ok
  rescue
    _error -> :ok
  catch
    :exit, _reason -> :ok
  end

  defp release_actuation(_store, _actuation, _consequence, _store_opts, _opts), do: :ok

  defp actuation_aware?(store) do
    Code.ensure_loaded?(store) and function_exported?(store, :claim_actuation, 3) and
      function_exported?(store, :commit_actuation, 3) and
      function_exported?(store, :release_actuation, 2)
  end

  defp prepare_receipt_anchor(command, execution_id, consequence, receipt_opts)
       when consequence in [:change, :external_do] do
    receipt = Receipt.pending(command, execution_id, consequence, receipt_opts)

    case ReceiptOutbox.append(receipt) do
      :ok -> {:ok, receipt}
      {:error, reason} -> {:error, reason}
    end
  end

  defp prepare_receipt_anchor(_command, _execution_id, :observe, _receipt_opts), do: {:ok, nil}

  defp refuse_unanchored_execution(
         store,
         command,
         execution_id,
         consequence,
         store_opts,
         receipt_opts,
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
      |> Receipt.from_reply(execution_id, consequence, reply, receipt_opts)
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
      {:error, {:ambiguous_skill, _selector}} -> {:error, refusal(:ambiguous_skill)}
      nil -> {:error, refusal(:action_not_found)}
    end
  end

  defp admit(_command, :observe), do: :ok

  # RFC-SA2A-001 S40 / RFC-SA2A-002 §81: an authority whose provenance is model
  # output is a candidate claim, never DO authority -- even when it names the
  # exact principal and capability (SA2A-LLM-010).
  defp admit(%Command{authority: %Authority{source: :model}}, consequence)
       when consequence in [:change, :external_do] do
    {:error, refusal(:model_authority_refused)}
  end

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

  # RFC-SA2A-002 §36 Gate 5. A command presented as a plan step (`opts[:plan]`
  # or `opts[:preflight]`) must carry the preflight identity issued for exactly
  # the executing `AshA2A.Planning.BoundedPlan`; a post-preflight mutation of
  # any bound field is refused here, before admission, claim, receipt
  # preparation or actuation. The verified plan digest is bound onto the
  # receipt. Commands that are not plan steps are untouched (no event).
  defp preflight_plan_step(command, opts) do
    if Keyword.has_key?(opts, :plan) or Keyword.has_key?(opts, :preflight) do
      plan = Keyword.get(opts, :plan)

      case AshA2A.Planning.Preflight.admit_step(Keyword.get(opts, :preflight), plan, command) do
        {:ok, preflight} ->
          emit_boundary([:preflight], command, %{
            outcome: :verified,
            plan_digest: preflight.plan_digest,
            preflight_digest: preflight.preflight_digest
          })

          {:ok, Keyword.put_new(opts, :plan_digest, preflight.plan_digest)}

        {:error, %{code: code, detail: detail} = reason} ->
          emit_boundary([:preflight], command, %{
            outcome: :refused,
            code: code,
            fields: AshA2A.Planning.Preflight.detail_fields(detail),
            preflight_digest: preflight_digest(Keyword.get(opts, :preflight))
          })

          {:error, reason}
      end
    else
      {:ok, opts}
    end
  end

  defp preflight_digest(%AshA2A.Planning.Preflight{preflight_digest: digest}), do: digest
  defp preflight_digest(_other), do: nil

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
    emit_commitment(command, nil, :admission, consequence)
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

  defp observe_prepare(command, execution_id, consequence, {:ok, anchor} = ok) do
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

    emit_commitment(command, anchor, :prepare, consequence)
    ok
  end

  defp observe_prepare(command, execution_id, consequence, {:error, reason} = error) do
    emit_boundary([:prepare], command, %{
      outcome: :failed,
      code: :receipt_anchor_unavailable,
      reason: inspect(reason),
      execution_id: identity_value(execution_id)
    })

    emit_commitment(command, nil, :prepare_failed, consequence)
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

  defp emit_commitment(command, receipt, transition, consequence)
       when consequence in [:change, :external_do] do
    metadata =
      command
      |> ConditionalCommitment.metadata(receipt)
      |> Map.put(:transition, transition)
      |> Map.put(:consequence, consequence)

    emit_boundary([:commitment], command, metadata)
  end

  defp emit_commitment(_command, _receipt, _transition, _consequence), do: :ok

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

  # `anchor` is the durably prepared `:pending` receipt (nil for `:observe`);
  # `AshA2A.BrceAnchor` hands it to exactly this one dispatch.
  defp dispatch_with_ocel_correlation(skill, message, resource_or_domain, opts, anchor) do
    Process.put(:ash_a2a_ocel_command_bus_dispatch, true)
    :ok = AshA2A.BrceAnchor.put(anchor)

    try do
      AshA2A.Dispatcher.dispatch(
        skill.name,
        message,
        resource_or_domain,
        Keyword.get(opts, :history, []),
        Keyword.get(opts, :auth_identity),
        # b4p-f5-10: the exact skill was resolved in `inspect_target/2`;
        # carrying it through prevents the re-dispatch from re-matching the
        # bare display name to an index-first namesake.
        resolved_skill: skill
      )
    after
      Process.delete(:ash_a2a_ocel_command_bus_dispatch)
      AshA2A.BrceAnchor.clear()
    end
  end

  defp safe_dispatch(skill, message, resource_or_domain, opts, anchor) do
    dispatch_with_ocel_correlation(skill, message, resource_or_domain, opts, anchor)
  rescue
    exception -> {:error, dispatch_crash_reason(:error, exception, __STACKTRACE__)}
  catch
    kind, reason -> {:error, dispatch_crash_reason(kind, reason, __STACKTRACE__)}
  end

  defp dispatch_crash_reason(kind, reason, stacktrace) do
    %{code: :dispatch_crashed, detail: Exception.format_banner(kind, reason, stacktrace)}
  end
end
