defmodule AshA2A.Receipt do
  @moduledoc """
  Replayable evidence for one AshA2A command attempt.

  Receipt identity is distinct from command, task, agent, semantic subject, and
  execution identity. The receipt records what was attempted and what reply
  shape was observed; it does not infer success beyond the returned outcome.

  ## Standing

  `:standing` (see `t:standing/0`) records how durably this receipt has
  actually been persisted -- it is evidence about the *store*, not about the
  underlying command's own consequence/status. `from_reply/4` always sets it
  to `:observed`; only `AshA2A.CommandBus.run/4` ever upgrades it to
  `:durable`, and only when the configured `AshA2A.ReceiptStore` declares
  itself durable (see `AshA2A.ReceiptStore.Ekv.durable?/0`).
  """

  alias AshA2A.{Command, Identity}

  @typedoc """
  How durably a receipt has actually been persisted.

    * `:observed` -- the default set by `from_reply/4` for every receipt,
      regardless of which store ultimately commits it. Reflects only that a
      reply was observed; it does not mean the receipt has reached durable
      storage. `AshA2A.ReceiptStore.Memory`-committed receipts always stay
      `:observed` -- an in-process `Map` is lost on restart.
    * `:durable` -- set by `AshA2A.CommandBus.run/4` (never by `from_reply/4`
      itself) only when the configured store module exports a real
      `durable?/0` function returning `true` (e.g.
      `AshA2A.ReceiptStore.Ekv.durable?/0`), checked via
      `Code.ensure_loaded?/1` + `function_exported?/3` rather than a
      hardcoded list of "known-durable" modules.
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

  @spec from_reply(Command.t(), Identity.t(), atom(), term()) :: t()
  def from_reply(
        %Command{} = command,
        %Identity{kind: :execution} = execution_id,
        consequence,
        reply
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
      status: status(reply),
      standing: :observed,
      reply: summarize(reply),
      recorded_at: DateTime.utc_now()
    }
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
