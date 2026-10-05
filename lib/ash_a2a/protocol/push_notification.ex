defmodule AshA2A.Protocol.PushNotification do
  @moduledoc false

  # Fans a task state change out to every webhook registered for that task.
  #
  # Delivery runs in a spawned process, never the agent's. A webhook that
  # hangs would otherwise stall the agent for every caller — and keep stalling
  # it after the original caller has already timed out, since the GenServer
  # goes on waiting.

  @doc """
  Delivers `task`'s current status to each of its registered webhooks.

  Returns `:ok` immediately; the POSTs happen off-process.
  """
  @spec deliver(AshA2A.Protocol.Agent.State.t(), AshA2A.Protocol.Task.t()) :: :ok
  def deliver(%{push_sender: nil}, _task), do: :ok

  def deliver(%{push_sender: {module, opts}} = state, task) do
    case AshA2A.Protocol.Agent.State.list_push_configs(state, task.id) do
      {:ok, []} ->
        :ok

      {:ok, configs} ->
        payload = status_payload(task)
        Enum.each(configs, &spawn_delivery(module, opts, &1, payload, task))
        :ok
    end
  end

  @doc """
  The sender used when an agent does not name one.

  `AshA2A.Protocol.PushNotificationSender.HTTP` when `:req` is available, otherwise no
  delivery at all — an agent cannot POST without an HTTP client.
  """
  @spec default_sender() :: {module(), keyword()} | nil
  def default_sender do
    if Code.ensure_loaded?(AshA2A.Protocol.PushNotificationSender.HTTP) do
      {AshA2A.Protocol.PushNotificationSender.HTTP, []}
    end
  end

  defp spawn_delivery(module, opts, config, payload, task) do
    Task.start(fn ->
      start = System.monotonic_time()
      result = module.deliver(config, payload, opts)

      :telemetry.execute(
        [:a2a, :push_notification, :delivery],
        %{duration: System.monotonic_time() - start},
        %{
          task_id: task.id,
          context_id: task.context_id,
          config_id: config.id,
          url: config.url,
          result: result
        }
      )
    end)
  end

  # The spec's push payload is a StreamResponse, the same shape the streaming
  # transport emits — a status update rather than a full task snapshot, so a
  # receiver can tell what changed without diffing.
  defp status_payload(task) do
    event =
      AshA2A.Protocol.Event.StatusUpdate.new(task.id, task.status,
        context_id: task.context_id,
        final: AshA2A.Protocol.Task.terminal?(task)
      )

    {:ok, payload} = AshA2A.Protocol.JSON.encode_stream_response(event)
    payload
  end
end
