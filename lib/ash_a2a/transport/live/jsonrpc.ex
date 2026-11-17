# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Transport.Live.JSONRPC do
  @moduledoc """
  `SendLiveMessage` for the JSON-RPC binding (A2A v1.1, spec 3.1.12 and 5.3).

  `params` is a `StreamRequest` (`{"sendMessage": ...}` or
  `{"subscribe": ...}`). The first call opens the downlink: an SSE stream of
  JSON-RPC responses whose `result` is a `StreamResponse`, as
  `SendStreamingMessage` answers. While a downlink is open, a further call
  that sends a message to the same task is an uplink: it answers one JSON-RPC
  response whose `result` is `{"task": ...}`, the current task, and the task's
  events keep arriving on the downlink only.

  Both JSON-RPC plugs (`AshA2A.Transport.Plug` and
  `AshA2A.A2ATransport.Plug`) route the method here. It shares
  `AshA2A.Transport.Live` with `POST /message:live` of the HTTP+JSON binding,
  so a session opened on one binding accepts uplink calls from the other.
  """

  import Plug.Conn

  alias AshA2A.Protocol.JSONRPC.{Error, Response}
  alias AshA2A.Protocol.{StreamError, StreamRequest}
  alias AshA2A.Transport.Live

  @method "SendLiveMessage"
  @heartbeat_ms 15_000
  @max_idle_ms 300_000

  @doc "The JSON-RPC method name, `\"SendLiveMessage\"`."
  @spec method() :: String.t()
  def method, do: @method

  @doc """
  Serves one `SendLiveMessage` call. `ctx` holds `:metadata` (the call
  metadata, with `"a2a.auth"` when the caller is authenticated) and
  `:principal` (the owner key of the caller).
  """
  @spec serve(Plug.Conn.t(), term(), term(), GenServer.server(), map()) :: Plug.Conn.t()
  def serve(conn, id, request, agent, ctx) when is_map(request) do
    card = GenServer.call(agent, :get_agent_card)

    cond do
      not Live.capability?(card, :streaming) ->
        reply(conn, id, {:error, unsupported()})

      uplink?(agent, ctx, request) ->
        uplink(conn, id, request, agent, ctx)

      true ->
        downlink(conn, id, request, agent, ctx)
    end
  end

  def serve(conn, id, _request, _agent, _ctx),
    do: reply(conn, id, {:error, Error.invalid_params("params must be a StreamRequest object")})

  defp unsupported,
    do: Error.unsupported_operation("SendLiveMessage requires capabilities.streaming")

  # An uplink sends a message to a task that an open session of this caller
  # is bound to.
  defp uplink?(agent, ctx, %{"sendMessage" => %{"message" => %{"taskId" => task_id}}})
       when is_binary(task_id) and task_id != "" do
    registry = Live.registry()

    with pid when is_pid(pid) <- Process.whereis(registry),
         [_ | _] = entries <- Registry.lookup(registry, {:task, agent, task_id}) do
      Enum.any?(entries, fn {_pid, owner} -> owner == ctx.principal end)
    else
      _ -> false
    end
  end

  defp uplink?(_agent, _ctx, _request), do: false

  defp uplink(conn, id, request, agent, ctx) do
    case Live.uplink_call(agent, ctx, request, []) do
      {:ack, %AshA2A.Protocol.Task{} = task} ->
        reply(conn, id, {:ok, %{"task" => AshA2A.Protocol.JSON.encode!(task)}})

      {:ack, %AshA2A.Protocol.Message{} = message} ->
        reply(conn, id, {:ok, %{"message" => AshA2A.Protocol.JSON.encode!(message)}})

      {:ack, _none} ->
        reply(conn, id, {:ok, %{}})

      {:error, %StreamError{} = error} ->
        reply(conn, id, {:error, stream_error(error)})

      {:error, :not_found} ->
        reply(conn, id, {:error, Error.task_not_found()})

      {:error, :unsupported_operation} ->
        reply(conn, id, {:error, unsupported()})

      {:error, _other} ->
        reply(conn, id, {:error, Error.invalid_params("invalid live request")})
    end
  end

  defp stream_error(%StreamError{code: code, message: message}) do
    case code do
      "ABORTED" -> Error.task_generation_mismatch()
      "NOT_FOUND" -> Error.task_not_found()
      "FAILED_PRECONDITION" -> Error.unsupported_operation(message || "unsupported operation")
      _other -> Error.invalid_params(message || "invalid live request")
    end
  end

  defp downlink(conn, id, request, agent, ctx) do
    with {:ok, %{payload: payload}} <- decode(request),
         :ok <- known_task(agent, ctx, request, payload),
         {:ok, session} <- Live.open(agent, ctx, self()) do
      conn =
        conn
        |> put_resp_header("a2a-live-session-id", Live.session_id(session))
        |> put_resp_header("content-type", "text/event-stream")
        |> put_resp_header("cache-control", "no-cache")
        |> send_chunked(200)

      try do
        case Live.uplink(session, request) do
          :ok ->
            loop(conn, id, v11?(conn), 0)

          {:error, :not_found} ->
            frame(conn, id, %StreamError{
              code: "NOT_FOUND",
              task_id: Map.get(payload, :task_id),
              message: "Task not found"
            })

          {:error, _other} ->
            frame(conn, id, %StreamError{code: "INTERNAL", message: "live session closed"})
        end
      after
        Live.close(session)
      end
    else
      {:error, %Error{} = error} -> reply(conn, id, {:error, error})
      {:error, :unsupported_operation} -> reply(conn, id, {:error, unsupported()})
      {:error, _other} -> reply(conn, id, {:error, Error.invalid_params("invalid StreamRequest")})
    end
  end

  defp decode(request) do
    case StreamRequest.decode(request) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, {:invalid, detail, _ref}} -> {:error, Error.invalid_params(detail)}
      {:error, _reason} -> {:error, Error.invalid_params("unrecognized StreamRequest payload")}
    end
  end

  # Opening with `subscribe` on a task that does not exist, or that the
  # caller does not own, is TaskNotFoundError (3.1.12 Errors) before any
  # stream starts.
  defp known_task(agent, ctx, %{"subscribe" => %{}}, payload) do
    with id when is_binary(id) <- Map.get(payload, :task_id) || Map.get(payload, :id),
         {:ok, _task} <- GenServer.call(agent, {:ash_a2a_get_task, ctx.principal, id}) do
      :ok
    else
      _ -> {:error, Error.task_not_found()}
    end
  catch
    :exit, _ -> {:error, Error.task_not_found()}
  end

  defp known_task(_agent, _ctx, _request, _payload), do: :ok

  defp v11?(conn) do
    version = AshA2A.Protocol.Version.from_conn(conn)
    AshA2A.Protocol.Version.at_least?(version, "1.1")
  end

  defp loop(conn, id, v11?, idle) do
    receive do
      {:a2a_live, _sid, %AshA2A.Protocol.Event.MessageUpdate{}} when not v11? ->
        loop(conn, id, v11?, 0)

      {:a2a_live, _sid, event} ->
        conn |> raw_frame(id, Live.encode(event)) |> loop(id, v11?, 0)

      {:a2a_live_closed, _sid, _reason} ->
        conn
    after
      @heartbeat_ms ->
        idle = idle + @heartbeat_ms

        with true <- idle < @max_idle_ms,
             {:ok, conn} <- chunk(conn, ": keepalive\n\n") do
          loop(conn, id, v11?, idle)
        else
          _ -> conn
        end
    end
  end

  defp frame(conn, id, struct) do
    {:ok, encoded} = AshA2A.Protocol.JSON.encode_stream_response(struct)
    raw_frame(conn, id, encoded)
  end

  defp raw_frame(conn, id, encoded) do
    case AshA2A.Protocol.DowngradeWire.frame(conn, encoded) do
      :drop ->
        conn

      {:ok, encoded} ->
        data = "data: " <> Jason.encode!(Response.success(id, encoded)) <> "\n\n"

        case chunk(conn, data) do
          {:ok, conn} -> conn
          {:error, _closed} -> conn
        end
    end
  end

  defp reply(conn, id, {:ok, result}), do: json(conn, Response.success(id, result))
  defp reply(conn, id, {:error, %Error{} = error}), do: json(conn, Response.error(id, error))

  defp json(conn, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(body))
  end
end
