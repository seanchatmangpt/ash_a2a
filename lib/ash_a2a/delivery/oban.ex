defmodule AshA2A.Delivery.Oban do
  @moduledoc """
  Optional Oban delivery adapter.

  Queue insertion records delivery only. The Oban worker that eventually
  receives this payload must reconstruct an admitted command and call
  `AshA2A.CommandBus`; an Oban job id is never promoted to A2A TaskID or to an
  execution receipt.
  """

  alias AshA2A.{Authority, Command, Delivery, Identity}

  @spec available?() :: boolean()
  def available?, do: Code.ensure_loaded?(Oban) and Code.ensure_loaded?(Oban.Job)

  @spec payload(Command.t()) :: map()
  def payload(%Command{} = command) do
    %{
      "command_id" => Identity.external(command.command_id),
      "agent_id" => Identity.external(command.agent_id),
      "principal_id" => Identity.external(command.principal_id),
      "task_id" => external_or_nil(command.task_id),
      "capability_id" => command.capability_id,
      "fingerprint" => command.fingerprint,
      "input" => command.input,
      "authority_token_id" => authority_token(command.authority),
      "metadata" => command.metadata
    }
  end

  @spec enqueue(module(), Command.t(), keyword()) :: {:ok, Delivery.t()} | {:error, term()}
  def enqueue(worker, %Command{} = command, opts \\ []) when is_atom(worker) do
    if available?() do
      job_opts = Keyword.put(Keyword.get(opts, :job_opts, []), :worker, worker)
      changeset = apply(Oban.Job, :new, [payload(command), job_opts])

      result =
        case Keyword.get(opts, :name) do
          nil -> apply(Oban, :insert, [changeset])
          name -> apply(Oban, :insert, [name, changeset])
        end

      case result do
        {:ok, job} ->
          {:ok,
           Delivery.new(:oban, command,
             provider_ref: Map.get(job, :id),
             status: :scheduled,
             metadata: %{worker: worker}
           )}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, {:unsupported, :oban}}
    end
  end

  defp external_or_nil(nil), do: nil
  defp external_or_nil(%Identity{} = identity), do: Identity.external(identity)

  defp authority_token(%Authority{token_id: token_id}), do: Identity.external(token_id)
  defp authority_token(_), do: nil
end
