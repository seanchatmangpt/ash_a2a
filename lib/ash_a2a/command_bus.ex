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

  ## Production hardening (v26.9.27)

    * **Dispatch deadline (R9).** DO runs in a monitored child process that
      inherits the caller's process dictionary (Ash/Logger/OTel context and
      the `$callers` chain) and is killed after `opts[:dispatch_timeout_ms]`
      / `config :ash_a2a, :dispatch_timeout_ms` (default 30_000;
      `:infinity` runs DO in the caller, the pre-R9 behavior). A timed-out
      consequence-bearing command is refused `:dispatch_timeout`: its receipt
      is marked `terminal_status: :unknown_outcome`, the pending anchor is
      KEPT (DO may have partially run), and the actuation claim is neither
      committed nor released -- a retry replays the unknown outcome; it never
      re-executes. The child is linked, so a caller death still takes DO
      down with it and a signal death of DO still takes the caller down (the
      pre-R9 crash semantics); a caller that traps exits instead gets
      `:dispatch_lost`, closed the same way as a timeout.
    * **Execution fencing (R4).** After the anchor is prepared and before DO,
      a store exporting `confirm_claim/3` must confirm this execution still
      owns the claim; otherwise the anchor is removed, the actuation claim
      released, and the command refused (`:stale_execution` /
      `:receipt_store_unavailable`) without DO.
    * **Actuation commit (R1).** `commit_actuation/3` is retried with the
      receipt-commit delays and its failure is observable
      (`[:ash_a2a, :command_bus, :actuation_commit]`, `outcome: :failed`);
      the stores answer a later claim of that effect from the claimant's
      committed primary receipt, so a lost actuation commit can no longer
      re-open the effect.
    * **Kill switch fails closed (R6).** A kill switch that cannot be
      consulted refuses with `:kill_switch_unavailable` instead of crashing
      the calling agent process.
    * **OCEL correlation hygiene (OBS-04).** The pending-dispatch stash is
      deleted after every consequence path, including outbox and error
      paths, so it can never merge into a later command's receipt event.
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

  @ocel_pending_key :ash_a2a_ocel_pending_dispatch
  @default_dispatch_timeout_ms 30_000

  @doc false
  # S42 totality for the typed codes this module introduces.
  def __sa2a_refusal_codes__ do
    %{
      kill_switch_unavailable: :blocked_resource,
      authority_revoked: :refused_authority,
      authority_expired: :refused_authority,
      authority_constraint_mismatch: :refused_authority,
      authority_revalidation_unavailable: :blocked_resource,
      stale_execution: :refused_identity,
      dispatch_timeout: :blocked_resource,
      dispatch_lost: :blocked_resource
    }
  end

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

    with {:ok, opts} <- hilt_work_order(command, opts),
         {:ok, skill, _action, consequence} <-
           observe_target(command, inspect_target(command, resource_or_domain)),
         {:ok, opts} <- bind_release_closure(skill, opts),
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
  defp bind_release_closure(skill, opts) do
    case CapabilityRelease.binding(skill.id, opts) do
      {:ok, nil} ->
        {:ok, opts}

      {:ok, binding} ->
        {:ok, Keyword.put(opts, :capability_release_binding, binding)}

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
        with :ok <- confirm_execution(store, command, execution_id, anchor, store_opts),
             :ok <- pre_do_gate(command, consequence, opts) do
          # OBS-04: the OCEL forwarder stashes dispatch correlation in this
          # process; it is consumed only when a receipt event is emitted.
          # Clear it on every exit from the consequence path (outbox,
          # error, timeout), never only on the happy path.
          try do
            execute_anchored(
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
              receipt_opts,
              anchor
            )
          after
            Process.delete(@ocel_pending_key)
          end
        else
          {:gate_refused, error} ->
            refuse_before_do(
              store,
              command,
              execution_id,
              consequence,
              store_opts,
              receipt_opts,
              actuation,
              anchor,
              opts,
              error
            )

          {:error, reason} ->
            # Superseded (or unverifiable) before DO: nothing crossed the
            # consequence boundary, so the anchor and the actuation claim
            # are released and the command is refused.
            ReceiptOutbox.remove(anchor)
            release_actuation(store, actuation, consequence, store_opts, opts)
            refuse_unconfirmed_execution(command, execution_id, anchor, reason)
        end

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

  defp execute_anchored(
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
         receipt_opts,
         anchor
       ) do
    reply =
      actuate(command, execution_id, anchor, consequence, fn ->
        safe_dispatch(skill, message, resource_or_domain, opts, anchor)
      end)

    case {reply, anchor} do
      {{:error, %{code: code}}, %Receipt{}} when code in [:dispatch_timeout, :dispatch_lost] ->
        close_timed_out(store, command, anchor, reply, store_opts)

      _completed ->
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

        _ = commit_actuation(store, actuation, receipt, consequence, store_opts, opts)

        store
        |> commit_receipt(receipt, store_opts)
        |> Postcondition.consequence_result(postcondition)
    end
  end

  # R9: DO exceeded its deadline and was killed, or its process died without
  # replying (`:dispatch_lost`). Whether it crossed the
  # consequence boundary is genuinely unknown, so the receipt says exactly
  # that (S31 UNKNOWN_OUTCOME), the pending anchor is kept as replay-blocking
  # evidence, and the actuation claim is left in flight (never committed as
  # an outcome, never released for re-actuation).
  defp close_timed_out(store, command, %Receipt{} = anchor, reply, store_opts) do
    {:error, %{code: code}} = reply

    receipt =
      anchor
      |> Receipt.mark_unknown_outcome(code)
      |> mark_standing(store)

    delays = Application.get_env(:ash_a2a, :receipt_commit_retry_delays_ms, [50, 150])
    commit_result = commit_with_retries(store, receipt, store_opts, delays)

    emit_boundary([:commit], command, %{
      outcome: :unknown_outcome,
      receipt_id: identity_value(receipt.receipt_id),
      primary_receipt_commit: commit_result
    })

    {:error, detail} = reply

    {:error,
     Map.merge(detail, %{
       receipt: receipt,
       outcome_known?: false,
       primary_receipt_commit: commit_result
     })}
  end

  defp confirm_execution(_store, _command, _execution_id, nil, _store_opts), do: :ok

  defp confirm_execution(store, command, execution_id, %Receipt{}, store_opts) do
    if Code.ensure_loaded?(store) and function_exported?(store, :confirm_claim, 3) do
      case store.confirm_claim(command.command_id, execution_id, store_opts) do
        :ok -> :ok
        {:error, :stale_execution} -> {:error, :stale_execution}
        {:error, _other} -> {:error, :receipt_store_unavailable}
      end
    else
      :ok
    end
  rescue
    _error -> {:error, :receipt_store_unavailable}
  catch
    :exit, _reason -> {:error, :receipt_store_unavailable}
  end

  defp refuse_unconfirmed_execution(command, execution_id, anchor, reason) do
    emit_boundary([:claim], command, %{
      outcome: :refused,
      code: reason,
      execution_id: identity_value(execution_id),
      receipt_id: identity_value(anchor.receipt_id)
    })

    {:error,
     %{
       code: reason,
       detail:
         "this execution no longer holds (or could not confirm) the command claim; " <>
           "refused before DO"
     }}
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
    release_attributes =
      opts
      |> Keyword.get(:capability_release_binding)
      |> CapabilityRelease.attributes()

    intended_effect =
      opts
      |> Keyword.get(:intended_effect, %{})
      |> Map.new()
      |> Map.merge(release_attributes)
      |> Map.merge(dedup_compat(opts))

    [actuation: actuation]
    |> maybe_put(:plan_digest, Keyword.get(opts, :plan_digest))
    |> maybe_put(:evidence_class, Keyword.get(opts, :evidence_class))
    |> maybe_put(:intended_effect, nonempty_map(intended_effect))
  end

  defp dedup_mode_normalized(opts) do
    case actuation_dedup_mode(opts) do
      :declared -> :declared
      :off -> :off
      _strict -> :strict
    end
  end

  defp dedup_compat(opts) do
    case dedup_mode_normalized(opts) do
      :declared -> %{actuation_dedup_compat: :declared_legacy}
      :off -> %{actuation_dedup_compat: :off_legacy}
      :strict -> %{}
    end
  end

  defp nonempty_map(map) when map_size(map) == 0, do: nil
  defp nonempty_map(map), do: map

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  @doc """
  The RFC-SA2A-001 S55 / RFC-SA2A-004 S11 actuation dedup mode currently in force.

    * `:strict` (default) -- the effect claim is mandatory for `:change` and
      `:external_do`: it is enforced on the derived effect digest, so two
      distinct command ids (fresh requests) naming the same effect cannot cross
      DO twice, with or without a declared idempotency token.
    * `:declared` -- LEGACY opt-in. Enforce only for a command that carries an
      explicit idempotency token. Receipts record
      `intended_effect.actuation_dedup_compat == :declared_legacy`.
    * `:off` -- LEGACY opt-in. Never actuation-claim; command-id claiming only.
      Receipts record `intended_effect.actuation_dedup_compat == :off_legacy`.
  """
  @spec actuation_dedup_mode(keyword()) :: :strict | :declared | :off
  def actuation_dedup_mode(opts \\ []) do
    Keyword.get(opts, :actuation_dedup) ||
      Application.get_env(:ash_a2a, :actuation_dedup, :strict)
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
        :declared -> actuation.external_token?
        :off -> false
        _strict -> true
      end
  end

  # R1: the actuation commit is no longer silently discarded. It is retried
  # with the receipt-commit delays and a final failure is observable; the
  # stores independently answer later claims of this effect from the
  # claimant's committed primary receipt (ActuationClaimLease.decide/3), so a
  # lost actuation commit cannot re-open a completed effect.
  defp commit_actuation(store, actuation, receipt, consequence, store_opts, opts)
       when consequence in [:change, :external_do] do
    if enforce_actuation?(store, actuation, opts) do
      delays = Application.get_env(:ash_a2a, :receipt_commit_retry_delays_ms, [50, 150])
      result = commit_actuation_with_retries(store, actuation, receipt, store_opts, delays)

      if result != :ok do
        emit_boundary([:actuation_commit], receipt, %{
          outcome: :failed,
          reason: inspect(result),
          receipt_id: identity_value(receipt.receipt_id)
        })
      end

      result
    else
      :ok
    end
  end

  defp commit_actuation(_store, _actuation, _receipt, _consequence, _store_opts, _opts), do: :ok

  defp commit_actuation_with_retries(store, actuation, receipt, store_opts, delays) do
    case commit_actuation_once(store, actuation, receipt, store_opts) do
      :ok ->
        :ok

      error ->
        case delays do
          [] ->
            error

          [delay | rest] ->
            Process.sleep(delay)
            commit_actuation_with_retries(store, actuation, receipt, store_opts, rest)
        end
    end
  end

  defp commit_actuation_once(store, actuation, receipt, store_opts) do
    case store.commit_actuation(actuation, receipt, store_opts) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected, other}}
    end
  rescue
    _error -> {:error, :actuation_store_unavailable}
  catch
    :exit, _reason -> {:error, :actuation_store_unavailable}
  end

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
      # Fenced out by a newer execution (R4): retrying cannot succeed.
      {:error, :stale_execution} -> {:error, :stale_execution}
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
  #
  # R6: a kill switch that cannot be consulted (not started, crashed before
  # publishing its state) refuses -- fail closed -- instead of letting the
  # exit propagate into, and kill, the calling agent process.
  defp check_kill_switch(opts) do
    case kill_switch_class(opts) do
      nil ->
        :ok

      class ->
        case KillSwitch.tripped?(class, Keyword.get(opts, :kill_switch, KillSwitch)) do
          {true, reason} -> {:error, %{code: :kill_switch_tripped, detail: reason}}
          false -> :ok
        end
    end
  rescue
    _error -> kill_switch_unavailable()
  catch
    :exit, _reason -> kill_switch_unavailable()
  end

  # RFC-SA2A-004 S11: the class may be named per call or host-wide
  # (`config :ash_a2a, :kill_switch_class`); the per-call opt wins.
  defp kill_switch_class(opts) do
    Keyword.get(opts, :kill_switch_class) || Application.get_env(:ash_a2a, :kill_switch_class)
  end

  # RFC-SA2A-004 S10/S11: AUTHORITY_REVALIDATED. Immediately before DO --
  # after the anchor is persisted and the claim confirmed -- authority is
  # re-checked against the authoritative broker (when one is configured) and
  # the kill switch is consulted again. Either failing means no DO.
  defp pre_do_gate(command, consequence, opts) do
    with :ok <- revalidate_release_standing(opts),
         :ok <- revalidate_authority(command, consequence, opts),
         :ok <- gate_result(check_kill_switch(opts)) do
      :ok
    end
  end

  # Standing is evidence, never runtime authority, but strict execution must
  # still possess that evidence at the last reversible boundary before DO.
  # Re-resolve the exact frozen member so mutable/deleted durable evidence
  # cannot pass on an admission observed earlier in CommandBus.run/4.
  defp revalidate_release_standing(opts) do
    case Keyword.get(opts, :capability_release_binding) do
      nil ->
        :ok

      prior ->
        case CapabilityRelease.binding(prior.capability_id, opts) do
          {:ok, current}
          when current.binding_digest == prior.binding_digest and
                 current.standing_binding_identity == prior.standing_binding_identity and
                 current.standing_receipt_digest == prior.standing_receipt_digest ->
            :ok

          {:ok, _changed} ->
            {:gate_refused,
             %{
               code: :capability_release_refused,
               detail: "standing evidence changed after release binding; refusing before DO",
               reason: :standing_replay_changed
             }}

          {:error, reason} ->
            {:gate_refused,
             %{
               code: :capability_release_refused,
               detail: "standing evidence could not be re-admitted immediately before DO",
               reason: reason
             }}
        end
    end
  end

  defp gate_result(:ok), do: :ok
  defp gate_result({:error, error}), do: {:gate_refused, error}

  defp revalidate_authority(_command, :observe, _opts), do: :ok

  defp revalidate_authority(%Command{authority: %Authority{} = authority} = command, _c, opts) do
    with :ok <- constraints_gate(authority, command) do
      case resolve_authority_broker(authority, opts) do
        :none ->
          if Authority.expired?(authority),
            do: {:gate_refused, refusal(:authority_expired)},
            else: :ok

        {module, broker_opts} ->
          if standing_grant?(authority) do
            standing_with_broker(module, broker_opts, authority)
          else
            verify_with_broker(module, broker_opts, authority)
          end
      end
    end
  end

  # No authority struct means `admit/2` already had to refuse (authority is
  # required for every consequential capability). There is nothing to
  # revalidate here, and this gate deliberately does not become a second,
  # masking copy of `admit/2`'s presence check: a mutant of that single guard
  # must stay observable to the mutation courts (CHI-SELFTEST / CHI-MUTGUARD).
  defp revalidate_authority(_command, _consequence, _opts), do: :ok

  # An authority synthesized on the dispatch path (`from_verified_identity/3`)
  # is a STANDING claim keyed by `Authority.grant_token_id/2`, admitted under
  # policy `:broker` by `Broker.granted?/3`; the broker never issued it as an
  # individual token, so revalidation asks the same question admission asked.
  defp standing_grant?(%Authority{admitted_by: {_module, _opts}}), do: true

  defp standing_grant?(%Authority{source: :transport_verified} = authority) do
    Application.get_env(:ash_a2a, :authority_policy, :broker) == :broker and
      authority.token_id.value ==
        Authority.grant_token_id(authority.subject, authority.capability_id)
  end

  defp standing_grant?(_authority), do: false

  defp standing_with_broker(module, broker_opts, authority) do
    cond do
      Authority.expired?(authority) ->
        {:gate_refused, refusal(:authority_expired)}

      Code.ensure_loaded?(module) and function_exported?(module, :granted?, 3) ->
        if module.granted?(authority.subject, authority.capability_id, broker_opts),
          do: :ok,
          else: {:gate_refused, refusal(:authority_revoked)}

      true ->
        {:gate_refused, revalidation_unavailable()}
    end
  rescue
    _error -> {:gate_refused, revalidation_unavailable()}
  catch
    :exit, _reason -> {:gate_refused, revalidation_unavailable()}
  end

  defp constraints_gate(authority, command) do
    if Authority.constraints_satisfied?(authority, command),
      do: :ok,
      else: {:gate_refused, refusal(:authority_constraint_mismatch)}
  end

  # The per-call opt wins; otherwise the broker that ADMITTED this standing
  # authority (`Authority.admitted_by`, set by `Grant.authorize/3`), so the
  # revalidation asks the same broker admission asked; otherwise the host-wide
  # configured broker.
  defp resolve_authority_broker(%Authority{admitted_by: admitted_by}, opts) do
    case Keyword.get(opts, :authority_broker) || admitted_by ||
           Application.get_env(:ash_a2a, :authority_broker) do
      {module, broker_opts} when is_atom(module) and is_list(broker_opts) -> {module, broker_opts}
      module when is_atom(module) and not is_nil(module) -> {module, []}
      _none -> :none
    end
  end

  defp verify_with_broker(module, broker_opts, authority) do
    if Code.ensure_loaded?(module) and function_exported?(module, :verify, 2) do
      case module.verify(authority, broker_opts) do
        {:ok, _authority} ->
          :ok

        {:error, %{reason: :expired}} ->
          {:gate_refused, refusal(:authority_expired)}

        {:error, _revoked_or_mismatch} ->
          {:gate_refused, refusal(:authority_revoked)}

        _other ->
          {:gate_refused, revalidation_unavailable()}
      end
    else
      {:gate_refused, revalidation_unavailable()}
    end
  rescue
    _error -> {:gate_refused, revalidation_unavailable()}
  catch
    :exit, _reason -> {:gate_refused, revalidation_unavailable()}
  end

  defp revalidation_unavailable do
    %{
      code: :authority_revalidation_unavailable,
      detail: "authoritative broker could not be consulted immediately before DO (fail closed)"
    }
  end

  # Pre-DO refusal after the anchor was persisted: nothing crossed the
  # consequence boundary, so the anchor and the actuation claim are released
  # and the still-open command claim is closed with a real refusal receipt.
  defp refuse_before_do(
         store,
         command,
         execution_id,
         consequence,
         store_opts,
         receipt_opts,
         actuation,
         anchor,
         opts,
         %{code: code} = error
       ) do
    if anchor, do: ReceiptOutbox.remove(anchor)
    release_actuation(store, actuation, consequence, store_opts, opts)

    receipt =
      command
      |> Receipt.from_reply(execution_id, consequence, {:error, error}, receipt_opts)
      |> mark_standing(store)

    delays = Application.get_env(:ash_a2a, :receipt_commit_retry_delays_ms, [50, 150])
    _ = commit_with_retries(store, receipt, store_opts, delays)
    emit_boundary([:pre_do_gate], command, %{outcome: :refused, code: code})

    {:error, Map.put(error, :receipt, receipt)}
  end

  defp kill_switch_unavailable do
    {:error,
     %{
       code: :kill_switch_unavailable,
       detail: "kill switch could not be consulted; refusing before claim (fail closed)"
     }}
  end

  defp refusal(reason), do: %{code: reason, detail: Atom.to_string(reason)}

  # v26.9.25 HILT admission. A work order is an optional executable contract,
  # not a new actuation path. It must already be bound into Command.fingerprint/1
  # via AshA2A.Hilt.WorkOrder.bind_command/2. Verification happens before
  # capability resolution, release-closure gating, claim, receipt preparation,
  # or DO. Provider and transport selection are absent from the contract.
  defp hilt_work_order(command, opts) do
    case Keyword.get(opts, :work_order) do
      nil ->
        {:ok, opts}

      %AshA2A.Hilt.WorkOrder{} = work_order ->
        case AshA2A.Hilt.WorkOrder.admit_command(work_order, command) do
          :ok ->
            emit_boundary([:work_order], command, %{
              outcome: :verified,
              work_order_digest: AshA2A.Hilt.WorkOrder.identity_digest(work_order)
            })

            {:ok, opts}

          {:error, code} ->
            emit_boundary([:work_order], command, %{outcome: :refused, code: code})
            {:error, refusal(code)}
        end

      _other ->
        emit_boundary([:work_order], command, %{outcome: :refused, code: :invalid_command_input})
        {:error, refusal(:invalid_command_input)}
    end
  end

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

  # W4: consequence-bearing dispatch crosses the portable kernel boundary.
  # The legacy BRCE anchor remains correlation evidence during migration; it is
  # not authority and cannot independently admit Dispatcher DO.
  defp dispatch_with_ocel_correlation(skill, message, resource_or_domain, opts, anchor) do
    Process.put(:ash_a2a_ocel_command_bus_dispatch, true)
    :ok = AshA2A.BrceAnchor.put(anchor)

    try do
      request = %AshA2A.ConsequenceKernel.W4.EffectRequest{
        skill: skill,
        message: message,
        resource_or_domain: resource_or_domain,
        consequence: if(anchor, do: anchor.consequence, else: :observe),
        history: Keyword.get(opts, :history, []),
        auth_identity: Keyword.get(opts, :auth_identity)
      }

      case AshA2A.ConsequenceKernel.W4.DispatchInversion.execute(request, opts) do
        {:error, _reason} = error -> error
        {outcome, reply} when outcome in [:completed, :failed, :unknown_outcome] -> reply
      end
    after
      Process.delete(:ash_a2a_ocel_command_bus_dispatch)
      AshA2A.BrceAnchor.clear()
    end
  end

  @doc """
  The dispatch deadline in force: `opts[:dispatch_timeout_ms]`, else
  `config :ash_a2a, :dispatch_timeout_ms`, else #{@default_dispatch_timeout_ms}.
  `:infinity` runs DO in the calling process with no deadline.
  """
  @spec dispatch_timeout_ms(keyword()) :: pos_integer() | :infinity
  def dispatch_timeout_ms(opts \\ []) do
    Keyword.get(opts, :dispatch_timeout_ms) ||
      Application.get_env(:ash_a2a, :dispatch_timeout_ms, @default_dispatch_timeout_ms)
  end

  defp safe_dispatch(skill, message, resource_or_domain, opts, anchor) do
    case dispatch_timeout_ms(opts) do
      :infinity ->
        guarded_dispatch(skill, message, resource_or_domain, opts, anchor)

      timeout when is_integer(timeout) and timeout > 0 ->
        bounded_dispatch(skill, message, resource_or_domain, opts, anchor, timeout)
    end
  end

  defp guarded_dispatch(skill, message, resource_or_domain, opts, anchor) do
    dispatch_with_ocel_correlation(skill, message, resource_or_domain, opts, anchor)
  rescue
    exception -> {:error, dispatch_crash_reason(:error, exception, __STACKTRACE__)}
  catch
    kind, reason -> {:error, dispatch_crash_reason(kind, reason, __STACKTRACE__)}
  end

  # R9: DO runs in a LINKED, monitored child that inherits this process's
  # dictionary -- Ash actor/tenant context, Logger metadata, OTel context --
  # and a `$callers` chain (so Ecto sandbox allowances resolve exactly as
  # they do for `Task`). The link keeps the pre-R9 crash semantics: if the
  # caller dies, DO dies with it (no orphaned consequence), and if DO is
  # killed by a signal, the caller dies too, exactly as when DO ran
  # in-process. The OCEL pending-dispatch stash the child's dispatch
  # telemetry produces is carried back so receipt correlation is unchanged.
  # On deadline the child is unlinked, killed, and the reply is
  # `:dispatch_timeout`; a reply racing the kill is flushed. A caller that
  # traps exits sees a signal death as `:dispatch_lost` instead of dying.
  defp bounded_dispatch(skill, message, resource_or_domain, opts, anchor, timeout) do
    parent = self()
    ref = make_ref()
    inherited = inheritable_dictionary()
    callers = [parent | List.wrap(Process.get(:"$callers"))]

    pid =
      spawn_link(fn ->
        Enum.each(inherited, fn {key, value} -> Process.put(key, value) end)
        Process.put(:"$callers", callers)
        reply = guarded_dispatch(skill, message, resource_or_domain, opts, anchor)
        send(parent, {ref, reply, Process.get(@ocel_pending_key)})
      end)

    monitor = Process.monitor(pid)

    receive do
      {^ref, reply, pending} ->
        release_child(pid, monitor)
        if pending != nil, do: Process.put(@ocel_pending_key, pending)
        reply

      # Reached only when this process traps exits (otherwise the link has
      # already taken it down): DO died without replying, so whether it
      # crossed the consequence boundary is unknown, exactly like a timeout.
      {:DOWN, ^monitor, :process, ^pid, reason} ->
        release_child(pid, nil)

        {:error,
         %{
           code: :dispatch_lost,
           detail: "dispatch process died without replying; outcome unknown",
           reason: inspect(reason, limit: 5)
         }}
    after
      timeout ->
        Process.unlink(pid)
        Process.exit(pid, :kill)
        release_child(pid, monitor)

        receive do
          {^ref, _late_reply, _pending} -> :ok
        after
          0 -> :ok
        end

        {:error,
         %{
           code: :dispatch_timeout,
           detail: "dispatch exceeded #{timeout}ms and was killed; outcome unknown",
           timeout_ms: timeout
         }}
    end
  end

  # Drops the link and monitor and flushes any `{:EXIT, pid, _}` a
  # trapping caller already received, so the child leaves no stray message
  # in a long-lived agent's mailbox.
  defp release_child(pid, monitor) do
    Process.unlink(pid)
    if monitor, do: Process.demonitor(monitor, [:flush])

    receive do
      {:EXIT, ^pid, _reason} -> :ok
    after
      0 -> :ok
    end
  end

  @uninherited [:"$ancestors", :"$initial_call", :"$callers"]

  defp inheritable_dictionary do
    Enum.reject(Process.get(), fn {key, _value} -> key in @uninherited end)
  end

  defp dispatch_crash_reason(kind, reason, stacktrace) do
    %{code: :dispatch_crashed, detail: Exception.format_banner(kind, reason, stacktrace)}
  end
end
