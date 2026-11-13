if Code.ensure_loaded?(Plug) do
  defmodule AshA2A.Protocol.Plug.SSE do
    @moduledoc false

    import Plug.Conn

    alias AshA2A.Protocol.JSONRPC.{Error, Response}

    @doc """
    Streams a message/stream response as SSE events.

    Calls `AshA2A.Protocol.stream/3` on the agent, then sends each part as an
    `ArtifactUpdate` SSE event and finishes with a terminal `StatusUpdate`
    event. Each event is a `StreamResponse` wrapper inside the JSON-RPC
    `result`.

    An agent that replies `{:message, parts}` answers out-of-band: the
    stream is a single Message event with no task snapshot and no final
    status, since no task was ever created.

    The optional `call_opts` are forwarded to `AshA2A.Protocol.stream/3` so that
    metadata, task_id, and context_id reach the agent.
    """
    @spec stream_message(
            Plug.Conn.t(),
            GenServer.server(),
            AshA2A.Protocol.Message.t(),
            term(),
            keyword()
          ) :: Plug.Conn.t()
    def stream_message(conn, agent, message, jsonrpc_id, call_opts \\ []) do
      case AshA2A.Protocol.stream(agent, message, call_opts) do
        {:ok, task, enum} ->
          conn = start_sse(conn)
          conn = send_task_snapshot(conn, jsonrpc_id, task)

          v11? =
            AshA2A.Protocol.Version.at_least?(
              AshA2A.Protocol.Version.get_negotiated(conn),
              "1.1"
            )

          conn = send_new_messages(conn, jsonrpc_id, task, %{v11?: v11?, seen: 0})
          stream_and_finalize(conn, jsonrpc_id, task, enum)

        {:ok, %AshA2A.Protocol.Message{} = agent_message} ->
          conn |> start_sse() |> send_message_event(jsonrpc_id, agent_message)

        {:error, :not_found} ->
          send_jsonrpc_error(conn, jsonrpc_id, Error.task_not_found())

        {:error, :not_continuable} ->
          send_jsonrpc_error(conn, jsonrpc_id, Error.unsupported_operation())

        {:error, :message_on_task} ->
          send_jsonrpc_error(
            conn,
            jsonrpc_id,
            Error.invalid_agent_response("Message reply to a task-scoped request")
          )

        {:error, reason} ->
          %{ref: ref} = AshA2A.Transport.SafeError.internal(:internal_error, reason)
          send_jsonrpc_error(conn, jsonrpc_id, Error.internal_error(%{"ref" => ref}))
      end
    end

    @doc """
    Streams an already-running task as SSE events.

    The caller has already resolved and authorized the task; this registers
    as a subscriber, sends the current task as the opening event, then relays
    each state change until the task is terminal.

    Unlike `stream_message/5` this never enumerates the agent's own stream —
    that enumerable replays from the start rather than attaching, so a second
    consumer would duplicate the task's artifacts and history.
    """
    @spec subscribe_task(Plug.Conn.t(), GenServer.server(), String.t(), term(), timeout()) ::
            Plug.Conn.t()
    def subscribe_task(conn, agent, task_id, jsonrpc_id, idle_timeout, opts \\ []) do
      with {:ok, last_seen} <- last_seen_generation(Keyword.get(opts, :params) || %{}) do
        case GenServer.call(agent, {:subscribe, task_id}) do
          {:ok, task} ->
            gen = AshA2A.Protocol.Task.Generation.generation_of(task)
            version = Keyword.get(opts, :version) || AshA2A.Protocol.Version.get_negotiated(conn)
            v11? = AshA2A.Protocol.Version.at_least?(version, "1.1")

            # This path keeps no event log, so a lastSeenGeneration is only
            # honoured (no Task snapshot) when the client is already current;
            # a gap cannot be replayed and falls back to a snapshot.
            resume? = is_integer(last_seen) and last_seen == gen and v11?

            conn = start_sse(conn)

            conn =
              if resume?,
                do: conn,
                else: send_task_snapshot(conn, jsonrpc_id, task)

            st = %{
              floor: if(resume?, do: last_seen),
              seen: gen,
              v11?: v11?,
              id: jsonrpc_id
            }

            if resume? and AshA2A.Protocol.Task.terminal?(task),
              do: conn,
              else: relay_task_events(conn, jsonrpc_id, idle_timeout, st)

          {:error, :not_found} ->
            send_jsonrpc_error(conn, jsonrpc_id, Error.task_not_found())

          {:error, :terminal} ->
            send_jsonrpc_error(conn, jsonrpc_id, Error.unsupported_operation())
        end
      else
        {:error, %Error{} = error} -> send_jsonrpc_error(conn, jsonrpc_id, error)
      end
    end

    @doc """
    Writes a `StreamError` `StreamResponse` frame on an open SSE connection.
    No `id:` line is written and the stream stays open.
    """
    @spec write_stream_error(Plug.Conn.t(), term(), AshA2A.Protocol.StreamError.t()) ::
            Plug.Conn.t()
    def write_stream_error(conn, jsonrpc_id, %AshA2A.Protocol.StreamError{} = error) do
      case AshA2A.Protocol.JSON.encode_stream_response(error) do
        {:ok, wrapped} -> write_wrapped(conn, jsonrpc_id, wrapped)
        _ -> conn
      end
    end

    defp write_wrapped(conn, jsonrpc_id, wrapped) do
      case send_event(conn, jsonrpc_id, wrapped) do
        {:error, conn} -> conn
        conn -> conn
      end
    end

    # `lastSeenGeneration`: nil when unset, a non-negative integer otherwise,
    # else -32602.
    defp last_seen_generation(params) do
      case Map.get(params, "lastSeenGeneration", Map.get(params, "last_seen_generation")) do
        nil ->
          {:ok, nil}

        n when is_integer(n) and n >= 0 ->
          {:ok, n}

        s when is_binary(s) ->
          case Integer.parse(s) do
            {n, ""} when n >= 0 -> {:ok, n}
            _ -> {:error, bad_generation()}
          end

        _ ->
          {:error, bad_generation()}
      end
    end

    defp bad_generation,
      do: Error.invalid_params("\"lastSeenGeneration\" must be a non-negative integer")

    defp relay_task_events({:error, conn}, _jsonrpc_id, _idle_timeout, _st), do: conn

    defp relay_task_events(conn, jsonrpc_id, idle_timeout, st) do
      receive do
        {:a2a_stream_error, _task_id, wrapped} ->
          conn
          |> write_wrapped(jsonrpc_id, wrapped)
          |> relay_task_events(jsonrpc_id, idle_timeout, st)

        {:a2a_task_event, _task_id, task} ->
          terminal? = AshA2A.Protocol.Task.terminal?(task)
          gen = AshA2A.Protocol.Task.Generation.generation_of(task)

          if is_integer(st.floor) and gen <= st.floor and not terminal? do
            relay_task_events(conn, jsonrpc_id, idle_timeout, st)
          else
            conn = send_new_messages(conn, jsonrpc_id, task, st)

            event =
              AshA2A.Protocol.Event.StatusUpdate.new(task.id, task.status,
                context_id: task.context_id,
                final: terminal?,
                generation: gen
              )

            {:ok, encoded} = AshA2A.Protocol.JSON.encode_stream_response(event)

            case send_event(conn, jsonrpc_id, encoded) do
              {:error, conn} ->
                conn

              conn ->
                st = %{st | seen: max(st.seen, gen)}

                if terminal?,
                  do: conn,
                  else: relay_task_events(conn, jsonrpc_id, idle_timeout, st)
            end
          end

        # Unknown StreamResponse payloads forwarded verbatim.
        {:a2a_stream_frame, _task_id, %{} = frame} ->
          conn
          |> write_wrapped(jsonrpc_id, frame)
          |> relay_task_events(jsonrpc_id, idle_timeout, st)
      after
        # A task that never reaches a terminal state would otherwise pin this
        # connection process indefinitely.
        idle_timeout -> conn
      end
    end

    # messageUpdate frames: v1.1 consumers only, one per client message on the
    # task timeline newer than what this stream already sent.
    defp send_new_messages(conn, jsonrpc_id, task, %{v11?: true, seen: seen}) do
      task.timeline
      |> List.wrap()
      |> Enum.reduce(conn, fn
        %AshA2A.Protocol.TimelineEntry{entry: {:message, message}, generation: gen}, conn
        when is_integer(gen) and gen > seen ->
          event =
            AshA2A.Protocol.Event.MessageUpdate.new(task.id, message,
              context_id: task.context_id,
              generation: gen
            )

          {:ok, encoded} = AshA2A.Protocol.JSON.encode_stream_response(event)
          write_wrapped(conn, jsonrpc_id, encoded)

        _other, conn ->
          conn
      end)
    end

    defp send_new_messages(conn, _jsonrpc_id, _task, _st), do: conn

    defp send_jsonrpc_error(conn, jsonrpc_id, error) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(Response.error(jsonrpc_id, error)))
    end

    defp start_sse(conn) do
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> send_chunked(200)
    end

    # Strip the :stream key from metadata — it holds the raw enumerable
    # function ref which is not JSON-serializable.
    defp send_task_snapshot(conn, jsonrpc_id, task) do
      clean = %{task | metadata: Map.delete(task.metadata, :stream)}
      {:ok, encoded} = AshA2A.Protocol.JSON.encode_stream_response(clean)
      send_event(conn, jsonrpc_id, encoded)
    end

    defp send_message_event(conn, jsonrpc_id, message) do
      {:ok, encoded} = AshA2A.Protocol.JSON.encode_stream_response(message)

      case send_event(conn, jsonrpc_id, encoded) do
        {:error, conn} -> conn
        conn -> conn
      end
    end

    defp stream_and_finalize(conn, jsonrpc_id, task, enum) do
      {conn, last} = stream_parts(conn, jsonrpc_id, task, enum)
      send_final_status(conn, jsonrpc_id, task, :completed, nil, last + 1)
    rescue
      e ->
        # SEC-08: no Exception.message/1 on the wire; opaque ref, detail logged.
        %{ref: ref} = AshA2A.Transport.SafeError.internal(:internal_error, e, __STACKTRACE__)

        send_final_status(
          conn,
          jsonrpc_id,
          task,
          :failed,
          "Internal error (ref: #{ref})",
          AshA2A.Protocol.Task.Generation.generation_of(task) + 1
        )
    end

    # Artifact frames carry the artifact's own generation when set
    # (end_generation || start_generation), else the next task generation;
    # stamped values are strictly increasing and above the opening snapshot.
    defp stream_parts(conn, jsonrpc_id, task, enum) do
      start = AshA2A.Protocol.Task.Generation.generation_of(task)

      Enum.reduce_while(enum, {conn, start}, fn part, {conn, last} ->
        artifact = AshA2A.Protocol.Artifact.new([part])
        own = artifact.end_generation || artifact.start_generation
        gen = if is_integer(own) and own > last, do: own, else: last + 1

        event =
          AshA2A.Protocol.Event.ArtifactUpdate.new(task.id, artifact,
            context_id: task.context_id,
            generation: gen
          )

        {:ok, encoded} = AshA2A.Protocol.JSON.encode_stream_response(event)

        case send_event(conn, jsonrpc_id, encoded) do
          {:error, conn} -> {:halt, {conn, gen}}
          conn -> {:cont, {conn, gen}}
        end
      end)
    end

    defp send_final_status(conn, jsonrpc_id, task, state, message_text, generation) do
      status_msg =
        if message_text,
          do: AshA2A.Protocol.Message.new_agent(message_text),
          else: nil

      event =
        AshA2A.Protocol.Event.StatusUpdate.new(
          task.id,
          AshA2A.Protocol.Task.Status.new(state, status_msg),
          context_id: task.context_id,
          final: true,
          generation: generation
        )

      {:ok, encoded} = AshA2A.Protocol.JSON.encode_stream_response(event)

      case send_event(conn, jsonrpc_id, encoded) do
        {:error, conn} -> conn
        conn -> conn
      end
    end

    defp send_event(conn, jsonrpc_id, encoded_result) do
      payload = Response.success(jsonrpc_id, encoded_result)

      case AshA2A.Protocol.DowngradeWire.frame(conn, payload) do
        :drop ->
          conn

        {:ok, payload} ->
          data = "data: #{Jason.encode!(payload)}\n\n"

          case chunk(conn, data) do
            {:ok, conn} -> conn
            {:error, :closed} -> {:error, conn}
          end
      end
    end
  end
end
