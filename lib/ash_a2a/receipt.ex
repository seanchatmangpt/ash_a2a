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
  """

  alias AshA2A.{Command, Identity}

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
    replayed?: false,
    metadata: %{}
  ]

  @type t :: %__MODULE__{}

  @doc """
  Builds the pre-dispatch receipt anchor for a consequence-bearing command.

  `:pending` means execution has been admitted and assigned an execution id,
  but no outcome is inferred yet. The same receipt id is retained by
  `finalize/2`, making the outbox entry an atomic replace rather than a second
  identity.
  """
  @spec pending(Command.t(), Identity.t(), atom()) :: t()
  def pending(
        %Command{} = command,
        %Identity{kind: :execution} = execution_id,
        consequence
      ) do
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
      metadata: %{outcome: :pending}
    }
  end

  @doc """
  Finalizes a pending receipt with the actually observed dispatcher reply while
  preserving receipt identity.
  """
  @spec finalize(t(), term()) :: t()
  def finalize(%__MODULE__{status: :pending} = receipt, reply) do
    %{
      receipt
      | status: status(reply),
        reply: summarize(reply),
        recorded_at: DateTime.utc_now(),
        metadata: Map.put(receipt.metadata, :outcome, :observed)
    }
  end

  @spec from_reply(Command.t(), Identity.t(), atom(), term()) :: t()
  def from_reply(
        %Command{} = command,
        %Identity{kind: :execution} = execution_id,
        consequence,
        reply
      ) do
    command
    |> pending(execution_id, consequence)
    |> finalize(reply)
  end

  @spec replay(t()) :: t()
  def replay(%__MODULE__{} = receipt), do: %{receipt | replayed?: true}

  defp status({:reply, _}), do: :completed
  defp status({:input_required, _}), do: :input_required
  defp status({:stream, _}), do: :stream_opened
  defp status({:error, _}), do: :failed
  defp status(_), do: :unknown

  defp summarize({:stream, _enumerable}), do: {:stream, :enumerable}
  defp summarize(reply), do: reply
end
