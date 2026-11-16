# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.A2ATransport.DetachedWatch do
  @moduledoc false

  # A send that answers while the task is still running (`returnImmediately`)
  # leaves nobody on the request path to publish what happens next, so the
  # task's push-notification configs would never hear that it finished. This
  # watcher follows the agent's task notifications after such an answer and
  # publishes each later state through the transport's `TaskEvents`, the same
  # `{"task": ...}` event the request path publishes, until the task reaches a
  # state that ends a stream.

  alias AshA2A.A2ATransport
  alias AshA2A.A2ATransport.{Ownership, TaskEvents}
  alias AshA2A.Protocol.Task.Generation

  @running [:submitted, :working]
  @idle_ms 600_000

  @doc """
  Starts a watcher when `task` is still running and `transport` is up.
  Returns `:ok` either way.
  """
  @spec start(GenServer.server(), atom() | nil, AshA2A.Protocol.Task.t()) :: :ok
  def start(_agent, nil, _task), do: :ok

  def start(agent, transport, %AshA2A.Protocol.Task{status: %{state: state}} = task)
      when state in @running do
    if A2ATransport.running?(transport) do
      {:ok, _pid} =
        Task.start(fn ->
          # The task the caller was answered with: the baseline the first
          # snapshot's mutations are derived from (`publish_events/3`).
          Process.put(:ash_a2a_detached_baseline, task)
          watch(agent, transport, task.id, Generation.generation_of(task))
        end)
    end

    :ok
  end

  def start(_agent, _transport, _task), do: :ok

  @doc "As `start/3`, for a caller that holds only the task id."
  @spec start_id(GenServer.server(), atom() | nil, String.t()) :: :ok
  def start_id(agent, transport, task_id) do
    case GenServer.call(agent, {:get_task, task_id}) do
      {:ok, %AshA2A.Protocol.Task{} = task} -> start(agent, transport, task)
      _ -> :ok
    end
  catch
    :exit, _ -> :ok
  end

  defp watch(agent, transport, task_id, seen) do
    case GenServer.call(agent, {:subscribe, task_id}) do
      {:ok, snapshot} -> seen |> publish(transport, snapshot) |> follow(transport, task_id)
      _terminal_or_missing -> final(agent, transport, task_id, seen)
    end
  catch
    :exit, _ -> :ok
  end

  defp follow(:done, _transport, _task_id), do: :ok

  defp follow(seen, transport, task_id) do
    receive do
      {:a2a_task_event, ^task_id, snapshot} ->
        seen |> publish(transport, snapshot) |> follow(transport, task_id)
    after
      @idle_ms -> :ok
    end
  end

  # The task ended between the answer and the subscription: publish its
  # final state once.
  defp final(agent, transport, task_id, seen) do
    case GenServer.call(agent, {:get_task, task_id}) do
      {:ok, task} -> publish(seen, transport, task)
      _ -> :ok
    end
  end

  defp publish(seen, transport, task) do
    generation = Generation.generation_of(task)
    closed? = task.status.state not in @running

    if generation > seen or closed? do
      publish_events(transport, task)

      wire =
        task
        |> AshA2A.Transport.Runtime.wire_task()
        |> AshA2A.Protocol.JSON.encode!()
        |> Ownership.strip_wire()

      if A2ATransport.running?(transport),
        do: TaskEvents.publish(transport, task.id, "task", %{"task" => wire}, closed?)
    end

    if closed?, do: :done, else: max(seen, generation)
  end

  # Every mutation since the previous snapshot is logged as its own event, at
  # the task's generation after it (A2A v1.1 3.2.7), BEFORE the snapshot that
  # restates them: a subscriber then receives the artifact and status events
  # in order. `once` keeps one event per generation when a subscriber riding
  # the agent fan-out reports the same mutation; `push: false` because the
  # snapshot published next is what the webhook receives.
  defp publish_events(transport, task) do
    baseline = Process.get(:ash_a2a_detached_baseline)
    Process.put(:ash_a2a_detached_baseline, task)

    if match?(%AshA2A.Protocol.Task{}, baseline) and A2ATransport.running?(transport) do
      for {gen, event} <- AshA2A.Protocol.Task.Delta.events(baseline, task) do
        {:ok, wrapped} = AshA2A.Protocol.JSON.encode_stream_response(event)

        kind =
          case event do
            %AshA2A.Protocol.Event.StatusUpdate{} -> "status-update"
            %AshA2A.Protocol.Event.ArtifactUpdate{} -> "artifact-update"
            %AshA2A.Protocol.Event.MessageUpdate{} -> "message-update"
          end

        TaskEvents.publish(
          transport,
          task.id,
          kind,
          Ownership.strip_wire(wrapped),
          Map.get(event, :final, false) == true,
          generation: gen,
          once: true,
          push: false
        )
      end
    end

    :ok
  end
end
