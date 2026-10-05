# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.A2ATransport.SSE do
  @moduledoc """
  SSE side of `message/stream` and `tasks/resubscribe`.

  `message/stream` no longer consumes the agent's stream on the HTTP
  connection. `stream_message/5` obtains `{task, enum}` from the agent,
  publishes the task snapshot, and hands `enum` to a supervised *pump*
  (`AshA2A.A2ATransport` `Task.Supervisor`) that publishes one
  `TaskArtifactUpdateEvent` per part and a final `TaskStatusUpdateEvent`
  carrying the agent's real terminal state. The HTTP connection is only a
  subscriber (`AshA2A.A2ATransport.TaskEvents`), exactly like a later
  `tasks/resubscribe` connection. Consequences:

    * any number of subscribers see the same events in the same order;
    * a client disconnect never halts the task's stream;
    * a resubscriber receives the current task snapshot, the logged backlog
      (after the SSE `Last-Event-ID`, if sent), then live events until the
      final event.

  Every SSE frame carries `id: <seq>` (the task-local event sequence) and a
  JSON-RPC success envelope as `data:` whose `result` is a v1.0 `StreamResponse`
  wrapper (`{"task" | "statusUpdate" | "artifactUpdate" => ...}`). Idle
  connections get a `: keepalive` comment every `:heartbeat_ms` and are closed
  after `:max_idle_ms` without events.
  """

  import Plug.Conn

  alias AshA2A.Protocol.JSONRPC.{Error, Response}
  alias AshA2A.A2ATransport
  alias AshA2A.A2ATransport.{Ownership, TaskEvents}

  @doc "Handles `message/stream` through the transport."
  @spec stream_message(
          Plug.Conn.t(),
          atom(),
          GenServer.server(),
          AshA2A.Protocol.Message.t(),
          term(),
          keyword(),
          keyword()
        ) ::
          Plug.Conn.t()
  def stream_message(conn, transport, agent, message, id, call_opts, sse_opts) do
    with {:ok, task, enum} <- AshA2A.Protocol.stream(agent, message, call_opts),
         _ = run_on_task(Keyword.get(sse_opts, :on_task), task),
         snapshot = encode_task(task),
         _seq = TaskEvents.publish(transport, task.id, "task", snapshot),
         {:ok, _pid} <- start_pump(transport, agent, task, enum) do
      backlog = TaskEvents.subscribe(transport, task.id)

      conn
      |> start_sse()
      |> replay_and_follow(transport, task.id, id, backlog, 0, sse_opts)
    else
      {:error, reason} ->
        # SEC-08/credential hygiene: `reason` can carry the task struct with
        # metadata["a2a.auth"] (e.g. {:not_streaming, task}) — inspect/1 here
        # streamed raw bearer tokens into the -32603 data. The wire gets the
        # redacted class as a STRING (redact/1 returns tagged tuples, which
        # are not JSON-encodable); detail stays server-side.
        send_json(
          conn,
          Response.error(
            id,
            Error.internal_error(inspect(AshA2A.Transport.SafeError.redact(reason)))
          )
        )
    end
  end

  @doc "Handles `tasks/resubscribe` through the transport."
  @spec resubscribe(Plug.Conn.t(), atom(), GenServer.server(), map(), term(), keyword()) ::
          Plug.Conn.t()
  def resubscribe(conn, transport, agent, params, id, sse_opts) do
    task_id = params["id"]

    with true <- is_binary(task_id) || {:error, Error.invalid_params("\"id\" is required")},
         {:ok, task} <- get_task(agent, task_id, Keyword.get(sse_opts, :principal, :anonymous)) do
      backlog = TaskEvents.subscribe(transport, task_id)
      after_seq = last_event_id(conn)
      conn = conn |> start_sse() |> write_frame(id, 0, encode_task(task))

      # The snapshot above replaces logged "task" events.
      backlog = Enum.reject(backlog, fn {_, kind, _, _} -> kind == "task" end)

      if closed_state?(task) and not Enum.any?(backlog, fn {_, _, _, final?} -> final? end) do
        TaskEvents.unsubscribe(transport, task_id)
        write_frame(conn, id, 0, final_status(task))
      else
        replay_and_follow(conn, transport, task_id, id, backlog, after_seq, sse_opts)
      end
    else
      {:error, %Error{} = error} -> send_json(conn, Response.error(id, error))
    end
  end

  defp run_on_task(nil, _task), do: :ok
  defp run_on_task(fun, task) when is_function(fun, 1), do: fun.(task)

  # Owner-scoped: a foreign task is -32001, indistinguishable from a missing one.
  defp get_task(agent, task_id, principal) do
    case Ownership.fetch(agent, task_id, principal) do
      {:ok, task} -> {:ok, task}
      {:error, _} -> {:error, Error.task_not_found()}
    end
  end

  # -- pump ---------------------------------------------------------------------

  defp start_pump(transport, agent, task, enum) do
    Task.Supervisor.start_child(A2ATransport.task_sup_name(transport), fn ->
      pump(transport, agent, task, enum)
    end)
  end

  @doc false
  def pump(transport, agent, task, enum) do
    try do
      Enum.each(enum, fn part ->
        event =
          AshA2A.Protocol.Event.ArtifactUpdate.new(task.id, AshA2A.Protocol.Artifact.new([part]),
            context_id: task.context_id
          )

        TaskEvents.publish(transport, task.id, "artifact-update", encode_event(event))
      end)

      # The agent's stream wrapper casts {:stream_done, ...} from this process
      # when the enum ends; this call is ordered after it, so it observes the
      # task's real post-stream state.
      final =
        case GenServer.call(agent, {:get_task, task.id}) do
          {:ok, done} -> final_status(done)
          {:error, _} -> status_event(task, :completed, nil)
        end

      TaskEvents.publish(transport, task.id, "status-update", final, true)
    rescue
      e ->
        TaskEvents.publish(
          transport,
          task.id,
          "status-update",
          status_event(task, :failed, Exception.message(e)),
          true
        )
    end
  end

  # -- following ----------------------------------------------------------------

  defp replay_and_follow(conn, transport, task_id, id, backlog, after_seq, opts) do
    Enum.reduce_while(backlog, {conn, after_seq}, fn {seq, _kind, payload, final?},
                                                     {conn, last} ->
      cond do
        seq <= last and final? ->
          {:halt, {:final, conn}}

        seq <= last ->
          {:cont, {conn, last}}

        true ->
          case chunk_frame(conn, id, seq, payload) do
            {:ok, conn} when final? -> {:halt, {:final, conn}}
            {:ok, conn} -> {:cont, {conn, seq}}
            {:error, conn} -> {:halt, {:closed, conn}}
          end
      end
    end)
    |> case do
      {:final, conn} -> done(conn, transport, task_id)
      {:closed, conn} -> done(conn, transport, task_id)
      {conn, last} -> follow(conn, transport, task_id, id, last, opts, 0)
    end
  end

  defp follow(conn, transport, task_id, id, last, opts, idle) do
    heartbeat = Keyword.get(opts, :heartbeat_ms, 15_000)
    max_idle = Keyword.get(opts, :max_idle_ms, 300_000)

    receive do
      {:a2a_task_event, ^task_id, seq, _kind, _payload, _final?} when seq <= last ->
        follow(conn, transport, task_id, id, last, opts, idle)

      {:a2a_task_event, ^task_id, seq, _kind, payload, final?} ->
        case chunk_frame(conn, id, seq, payload) do
          {:ok, conn} when final? -> done(conn, transport, task_id)
          {:ok, conn} -> follow(conn, transport, task_id, id, seq, opts, 0)
          {:error, conn} -> done(conn, transport, task_id)
        end
    after
      heartbeat ->
        idle = idle + heartbeat

        cond do
          idle >= max_idle ->
            done(conn, transport, task_id)

          true ->
            case chunk(conn, ": keepalive\n\n") do
              {:ok, conn} -> follow(conn, transport, task_id, id, last, opts, idle)
              {:error, _} -> done(conn, transport, task_id)
            end
        end
    end
  end

  defp done(conn, transport, task_id) do
    TaskEvents.unsubscribe(transport, task_id)
    conn
  end

  # -- framing ------------------------------------------------------------------

  defp start_sse(conn) do
    conn
    |> put_resp_header("content-type", "text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    |> send_chunked(200)
  end

  defp write_frame(conn, id, seq, payload) do
    case chunk_frame(conn, id, seq, payload) do
      {:ok, conn} -> conn
      {:error, conn} -> conn
    end
  end

  defp chunk_frame(conn, id, seq, payload) do
    data = "id: #{seq}\ndata: #{Jason.encode!(Response.success(id, payload))}\n\n"

    case chunk(conn, data) do
      {:ok, conn} -> {:ok, conn}
      {:error, _} -> {:error, conn}
    end
  end

  defp send_json(conn, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(body))
  end

  defp last_event_id(conn) do
    with [value | _] <- get_req_header(conn, "last-event-id"),
         {n, ""} <- Integer.parse(value) do
      n
    else
      _ -> 0
    end
  end

  # -- payloads -----------------------------------------------------------------

  @doc false
  def encode_task(task) do
    {:ok, wrapped} = task |> Ownership.strip_task() |> AshA2A.Protocol.JSON.encode_stream_response()
    wrapped
  end

  # A stream closes for a resubscriber when the task is terminal or paused for input.
  defp closed_state?(task), do: AshA2A.Protocol.Task.terminal?(task) or task.status.state == :input_required

  @doc false
  def final_status(task), do: status_event(task, task.status.state, task.status.message)

  defp status_event(task, state, message) do
    message =
      case message do
        nil -> nil
        text when is_binary(text) -> AshA2A.Protocol.Message.new_agent(text)
        %AshA2A.Protocol.Message{} = m -> m
      end

    AshA2A.Protocol.Event.StatusUpdate.new(task.id, AshA2A.Protocol.Task.Status.new(state, message),
      context_id: task.context_id,
      final: true
    )
    |> encode_event()
  end

  # Every logged/published payload is a v1.0 `StreamResponse` wrapper
  # (`{"task" | "statusUpdate" | "artifactUpdate" => ...}`): the SSE frame and
  # the webhook body are both the payload encoded as-is.
  defp encode_event(event) do
    {:ok, wrapped} = AshA2A.Protocol.JSON.encode_stream_response(event)
    wrapped
  end
end
