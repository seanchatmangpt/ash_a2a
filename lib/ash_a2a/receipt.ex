defmodule AshA2A.Receipt do
  @moduledoc """
  Replayable evidence for one AshA2A command attempt.

  Receipt identity is distinct from command, task, agent, semantic subject, and
  execution identity. The receipt records what was attempted and what reply
  shape was observed; it does not infer success beyond the returned outcome.

  Consequence-bearing commands may create a `:pending` receipt before DO. That
  receipt is the durable execution anchor used by `AshA2A.CommandBus`: once
  persisted by `AshA2A.ReceiptOutbox`, dispatch may proceed. `finalize/2`
  preserves the same receipt identity while replacing the pending outcome with
  the reply actually observed. If finalization cannot be persisted after DO,
  the pending receipt remains as replay-blocking evidence that the execution
  crossed the consequence boundary without inventing an outcome.

  ## Standing

  `:standing` (see `t:standing/0`) records how durably this receipt has
  actually been persisted -- it is evidence about the *store*, not about the
  underlying command's own consequence/status. `from_reply/4` and `pending/3`
  set it to `:observed`; only `AshA2A.CommandBus.run/4` ever upgrades it to
  `:durable`, and only when the configured `AshA2A.ReceiptStore` declares
  itself durable (see `AshA2A.ReceiptStore.Ekv.durable?/0`).

  ## RFC-SA2A-001 S31 prepared-receipt fields

  S31 ("zero unreceipted actuation") enumerates what a prepared receipt must
  carry *before* the consequence boundary is crossed. Those fields are all
  populated by `pending/4`, which is what `AshA2A.CommandBus` anchors:

  | S31 field | Receipt field | Source |
  |---|---|---|
  | actuation identifier | `:actuation_id` | `AshA2A.Actuation.identity/2` (effect-derived, not command-derived) |
  | idempotency identifier | `:idempotency_key` | external token when supplied, else effect digest |
  | actor | `:actor` | the acting principal (`:agent_id` is recorded separately as the carrier) |
  | authority grant | `:authority_grant` | bounded descriptor of `AshA2A.Authority`, never the raw transport evidence |
  | semantic subject | `:semantic_subject` | `AshA2A.SemanticSubject` |
  | intended effect | `:intended_effect` | capability + consequence + action intent, recorded *before* DO |
  | input digest | `:input_digest` | SHA-256 of `command.input` |
  | plan digest | `:plan_digest` | supplied by the planner, `nil` when no plan selected a route |
  | projection digest | `:projection_digest` | from the semantic subject |
  | timestamp / logical clock | `:recorded_at` + `:logical_clock` | wall clock plus a strictly monotonic per-node integer |
  | reconciliation metadata | `:reconciliation` | state machine for outbox drain / compensation |

  `:plan_digest` is the one field that is legitimately `nil` for an unplanned
  command; `missing_required_fields/1` reports it as absent rather than
  inventing one, which is the honest reading of S31 (a receipt may not claim a
  plan that never existed).

  ## Terminal status (RFC-SA2A-001 S31)

  `:status` remains the *reply-shape* status it has always been
  (`:pending`/`:completed`/`:input_required`/`:stream_opened`/`:failed`/`:unknown`).
  S31's terminal set is a separate, coarser axis recorded in
  `:terminal_status`:

    * `:executed` -- the consequence boundary was crossed and an outcome was observed
    * `:refused` -- admission/authority/kill-switch/anchor refused *before* DO
    * `:failed` -- DO ran and failed
    * `:reconciled` -- a previously non-durable outcome was later drained to the primary store
    * `:compensated` -- a real compensating action was recorded against this actuation
    * `:unknown_outcome` -- DO may or may not have crossed the boundary; nothing is inferred

  A `:pending` receipt has `terminal_status: nil`. That is not a missing value:
  it is the statement that no terminal status has been observed yet.
  """

  alias AshA2A.{Actuation, Authority, Command, Evidence, Identity, SemanticSubject}
  alias AshA2A.Receipt.Binding

  @typedoc """
  How durably a receipt has actually been persisted.

    * `:observed` -- the default set by receipt construction, regardless of
      which store ultimately commits it. Reflects only that the receipt exists
      in the current execution; it does not mean the configured primary store
      is durable. `AshA2A.ReceiptStore.Memory`-committed receipts always stay
      `:observed` -- an in-process `Map` is lost on restart.
    * `:durable` -- set by `AshA2A.CommandBus.run/4` only when the configured
      primary store module exports a real `durable?/0` function returning
      `true` (e.g. `AshA2A.ReceiptStore.Ekv.durable?/0`).
  """
  @type standing :: :observed | :durable

  @typedoc "RFC-SA2A-001 S31 terminal status set. `nil` while still `:pending`."
  @type terminal_status ::
          :executed | :refused | :failed | :reconciled | :compensated | :unknown_outcome | nil

  @terminal_statuses [:executed, :refused, :failed, :reconciled, :compensated, :unknown_outcome]

  # Refusal codes produced *before* the consequence boundary is crossed. A
  # receipt carrying one of these is `:refused`, not `:failed` -- the
  # distinction is load-bearing for S31, because `:failed` asserts DO ran.
  @pre_do_refusal_codes [
    :receipt_anchor_unavailable,
    :kill_switch_tripped,
    :authority_required,
    :authority_mismatch,
    :consequence_unclassified,
    :capability_not_found,
    :action_not_found,
    :command_conflict,
    :actuation_conflict,
    :actuation_in_flight,
    :actuation_store_unavailable
  ]

  @enforce_keys [
    :receipt_id,
    :command_id,
    :execution_id,
    :agent_id,
    :principal_id,
    :capability_id,
    :fingerprint,
    :consequence,
    :status,
    :standing,
    :recorded_at
  ]
  defstruct [
    :receipt_id,
    :command_id,
    :execution_id,
    :task_id,
    :agent_id,
    :principal_id,
    :capability_id,
    :semantic_subject,
    :fingerprint,
    :consequence,
    :status,
    :standing,
    :reply,
    :recorded_at,
    # RFC-SA2A-001 S31 prepared-receipt fields (additive; every one defaults,
    # so every pre-existing `%AshA2A.Receipt{...}` literal still compiles).
    :actuation_id,
    :idempotency_key,
    :actor,
    :authority_grant,
    :intended_effect,
    :input_digest,
    :plan_digest,
    :projection_digest,
    :logical_clock,
    :terminal_status,
    :evidence_class,
    # RFC-SA2A-002 §40 identity binding (`AshA2A.Receipt.Binding`); `nil` on
    # literals, which therefore carry no binding standing.
    :binding,
    reconciliation: %{state: :not_required, attempts: 0},
    replayed?: false,
    metadata: %{}
  ]

  @type t :: %__MODULE__{}

  @doc "The RFC-SA2A-001 S31 prepared-receipt field list, in RFC order."
  @spec required_fields() :: [atom()]
  def required_fields do
    [
      :actuation_id,
      :idempotency_key,
      :actor,
      :authority_grant,
      :semantic_subject,
      :intended_effect,
      :input_digest,
      :plan_digest,
      :projection_digest,
      :recorded_at,
      :logical_clock,
      :reconciliation
    ]
  end

  @doc """
  Which S31 prepared-receipt fields this receipt does not carry.

  Reports absence; it does not manufacture a value. An unplanned command
  legitimately reports `[:plan_digest]`, and a command with no semantic
  subject legitimately reports `[:semantic_subject, :projection_digest]`.
  """
  @spec missing_required_fields(t()) :: [atom()]
  def missing_required_fields(%__MODULE__{} = receipt) do
    Enum.filter(required_fields(), &is_nil(Map.fetch!(receipt, &1)))
  end

  @doc "The allowed terminal statuses."
  @spec terminal_statuses() :: [atom()]
  def terminal_statuses, do: @terminal_statuses

  @doc """
  Builds the pre-dispatch receipt anchor for a consequence-bearing command.

  `:pending` means execution has been admitted and assigned an execution id,
  but no outcome is inferred yet. The same receipt id is retained by
  `finalize/2`, making the outbox entry an atomic replace rather than a second
  identity.

  ## Options

    * `:actuation` -- a precomputed `AshA2A.Actuation.t()`. Derived from the
      command when absent, so callers that do not care never have to.
    * `:plan_digest` -- the digest of the plan that selected this route.
    * `:evidence_class` -- an `AshA2A.Evidence.Class` value. Defaults to
      `AshA2A.Evidence.Class.default/0`, which is the *weakest* class.
    * `:intended_effect` -- extra intent recorded before DO; merged over the
      capability/consequence pair this function always records.
    * `:chain_predecessor` -- the receipt chain predecessor digest bound into
      the prepared link (`AshA2A.Receipt.Binding.bind/2`).
  """
  @spec pending(Command.t(), Identity.t(), atom(), keyword()) :: t()
  def pending(command, execution_id, consequence, opts \\ [])

  def pending(
        %Command{} = command,
        %Identity{kind: :execution} = execution_id,
        consequence,
        opts
      ) do
    actuation = Keyword.get_lazy(opts, :actuation, fn -> Actuation.identity(command) end)

    %__MODULE__{
      receipt_id: Identity.runtime(Ash.UUIDv7.generate()),
      command_id: command.command_id,
      execution_id: execution_id,
      task_id: command.task_id,
      agent_id: command.agent_id,
      principal_id: command.principal_id,
      capability_id: command.capability_id,
      semantic_subject: command.semantic_subject,
      fingerprint: command.fingerprint,
      consequence: consequence,
      status: :pending,
      standing: :observed,
      reply: nil,
      recorded_at: DateTime.utc_now(),
      actuation_id: actuation.actuation_id,
      idempotency_key: actuation.idempotency_key,
      actor: command.principal_id,
      authority_grant: authority_grant(command.authority),
      intended_effect: intended_effect(command, consequence, opts),
      input_digest: actuation.input_digest,
      plan_digest: plan_digest(command, opts),
      projection_digest: projection_digest(command.semantic_subject),
      logical_clock: logical_clock(),
      terminal_status: nil,
      evidence_class: Keyword.get_lazy(opts, :evidence_class, &default_evidence_class/0),
      reconciliation: %{state: reconciliation_state(consequence), attempts: 0},
      metadata: prepared_metadata(command)
    }
    |> Binding.bind(predecessor: Keyword.get(opts, :chain_predecessor))
  end

  @doc """
  Finalizes a pending receipt with the actually observed dispatcher reply while
  preserving receipt identity.

  Sets `:terminal_status` from the observed reply -- `:refused` for a refusal
  raised before DO, `:failed` for a real dispatch failure, `:executed` for any
  reply shape that proves DO ran.
  """
  @spec finalize(t(), term()) :: t()
  def finalize(%__MODULE__{status: :pending} = receipt, reply) do
    Binding.transition(
      receipt,
      %{
        receipt
        | status: status(reply),
          terminal_status: terminal_status(reply),
          reply: summarize(reply),
          recorded_at: DateTime.utc_now(),
          logical_clock: logical_clock(),
          metadata: Map.put(receipt.metadata, :outcome, :observed)
      },
      :final
    )
  end

  @spec from_reply(Command.t(), Identity.t(), atom(), term(), keyword()) :: t()
  def from_reply(command, execution_id, consequence, reply, opts \\ [])

  def from_reply(
        %Command{} = command,
        %Identity{kind: :execution} = execution_id,
        consequence,
        reply,
        opts
      ) do
    command
    |> pending(execution_id, consequence, opts)
    |> finalize(reply)
  end

  @spec replay(t()) :: t()
  def replay(%__MODULE__{} = receipt), do: %{receipt | replayed?: true}

  @doc """
  Records that a previously non-durable outcome has been drained to the
  primary store.

  This is the S31 `RECONCILED` terminal status. It does not change `:status`
  (the observed reply shape is unchanged by where the evidence now lives) and
  it never upgrades `:standing` -- `AshA2A.CommandBus` owns that, and only
  against a store that really declares itself durable.
  """
  @spec reconcile(t(), map()) :: t()
  def reconcile(%__MODULE__{} = receipt, detail \\ %{}) do
    attempts = Map.get(receipt.reconciliation || %{}, :attempts, 0)

    receipt
    |> Binding.transition(
      %{
        receipt
        | terminal_status: :reconciled,
          reconciliation:
            Map.merge(receipt.reconciliation || %{}, %{
              state: :reconciled,
              attempts: attempts + 1,
              reconciled_at: DateTime.utc_now(),
              detail: detail
            })
      },
      :reconciled
    )
  end

  @doc """
  Records that a real compensating action closed this actuation.

  `detail` must describe the compensation that actually ran (its own receipt
  id, the external reversal reference). This function records the claim; it
  performs no compensating effect itself.
  """
  @spec compensate(t(), map()) :: t()
  def compensate(%__MODULE__{} = receipt, detail) when is_map(detail) do
    receipt
    |> Binding.transition(
      %{
        receipt
        | terminal_status: :compensated,
          reconciliation:
            Map.merge(receipt.reconciliation || %{}, %{
              state: :compensated,
              compensated_at: DateTime.utc_now(),
              detail: detail
            })
      },
      :compensated
    )
  end

  @doc """
  Records that whether DO crossed the consequence boundary is genuinely not
  known -- the S31 `UNKNOWN_OUTCOME` terminal status.

  This is the honest terminal state for a post-DO crash window: it asserts
  neither execution nor non-execution.
  """
  @spec mark_unknown_outcome(t(), term()) :: t()
  def mark_unknown_outcome(%__MODULE__{} = receipt, reason \\ nil) do
    receipt
    |> Binding.transition(
      %{
        receipt
        | terminal_status: :unknown_outcome,
          reconciliation:
            Map.merge(receipt.reconciliation || %{}, %{
              state: :unknown_outcome,
              reason: reason
            })
      },
      :unknown_outcome
    )
  end

  @doc "Whether this receipt has reached a terminal status."
  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{terminal_status: status}), do: status in @terminal_statuses

  @doc """
  The S31 terminal status implied by a dispatcher reply.

      iex> AshA2A.Receipt.terminal_status({:reply, :ok})
      :executed
      iex> AshA2A.Receipt.terminal_status({:error, %{code: :authority_required}})
      :refused
      iex> AshA2A.Receipt.terminal_status({:error, %{code: :dispatch_crashed}})
      :failed
  """
  @spec terminal_status(term()) :: terminal_status()
  def terminal_status({:error, %{code: code}}) when code in @pre_do_refusal_codes, do: :refused
  def terminal_status({:error, _}), do: :failed
  def terminal_status({:reply, _}), do: :executed
  def terminal_status({:input_required, _}), do: :executed
  def terminal_status({:stream, _}), do: :executed
  def terminal_status(_), do: :unknown_outcome

  @doc "A bounded, evidence-only descriptor of an authority grant."
  @spec authority_grant(Authority.t() | nil) :: map() | nil
  def authority_grant(nil), do: nil

  def authority_grant(%Authority{} = authority) do
    %{
      token_id: Identity.external(authority.token_id),
      subject: Identity.external(authority.subject),
      capability_id: authority.capability_id,
      source: authority.source,
      issued_at: authority.issued_at,
      expires_at: authority.expires_at,
      constraints: authority.constraints,
      # The raw `:evidence` field can carry a whole transport identity. Record
      # its digest, not its contents -- a receipt is durable and replayable,
      # and S31 asks for the grant, not the caller's credentials.
      evidence_digest: Actuation.digest(authority.evidence)
    }
  end

  defp prepared_metadata(%Command{metadata: metadata}) do
    work_order_digest =
      if is_map(metadata) do
        Map.get(metadata, :work_order_digest) || Map.get(metadata, "work_order_digest")
      end

    %{outcome: :pending}
    |> maybe_put_metadata(:work_order_digest, work_order_digest)
  end

  defp maybe_put_metadata(metadata, _key, nil), do: metadata
  defp maybe_put_metadata(metadata, key, value), do: Map.put(metadata, key, value)

  defp intended_effect(%Command{} = command, consequence, opts) do
    base = %{
      capability_id: command.capability_id,
      consequence: consequence,
      target: Keyword.get(opts, :target)
    }

    Map.merge(base, Map.new(Keyword.get(opts, :intended_effect, %{})))
  end

  defp plan_digest(%Command{metadata: metadata}, opts) do
    Keyword.get(opts, :plan_digest) ||
      (is_map(metadata) &&
         (Map.get(metadata, :plan_digest) || Map.get(metadata, "plan_digest"))) || nil
  end

  defp projection_digest(%SemanticSubject{projection_digest: digest}), do: digest
  defp projection_digest(_), do: nil

  # Wall-clock `recorded_at` is not orderable under clock skew or two receipts
  # in the same microsecond. `:erlang.unique_integer([:monotonic, :positive])`
  # is a real strictly-increasing per-node integer, which is what S31's
  # "logical clock" asks for alongside the timestamp.
  defp logical_clock, do: :erlang.unique_integer([:monotonic, :positive])

  defp reconciliation_state(consequence) when consequence in [:change, :external_do], do: :pending
  defp reconciliation_state(_), do: :not_required

  defp default_evidence_class do
    Evidence.Class.default().new(%{source: :command_bus})
  end

  defp status({:reply, _}), do: :completed
  defp status({:input_required, _}), do: :input_required
  defp status({:stream, _}), do: :stream_opened
  defp status({:error, _}), do: :failed
  defp status(_), do: :unknown

  defp summarize({:stream, _enumerable}), do: {:stream, :enumerable}
  defp summarize(reply), do: reply
end
