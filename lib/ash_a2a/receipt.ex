defmodule AshA2A.Receipt do
  @moduledoc """
  Replayable evidence for one AshA2A command attempt.

  Receipt identity is distinct from command, task, agent, and execution
  identity. The receipt records what was attempted and what reply shape was
  observed; it does not infer success beyond the returned outcome.
  """

  alias AshA2A.{Command, Identity}

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
  def from_reply(%Command{} = command, %Identity{kind: :execution} = execution_id, consequence, reply) do
    %__MODULE__{
      receipt_id: Identity.runtime(Ash.UUIDv7.generate()),
      command_id: command.command_id,
      execution_id: execution_id,
      task_id: command.task_id,
      agent_id: command.agent_id,
      principal_id: command.principal_id,
      capability_id: command.capability_id,
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
