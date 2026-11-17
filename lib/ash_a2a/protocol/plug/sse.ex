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

        {:error, {:invalid_agent_response, _} = reason} ->
          send_jsonrpc_error(conn, jsonrpc_id, AshA2A.Transport.Plug.reason_error(reason))

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

            # Without an event log a lastSeenGeneration is only honoured (no
            # Task snapshot) when the client is already current; a gap cannot
            # be replayed and falls back to a snapshot (documented
            # fallback). With a running transport event log, newer events
            # (generation > lastSeenGeneration) are replayed instead, and
            # only an unretained range falls back to the snapshot.
            journal = journal_plan(task_id, last_seen, gen, v11?)

            plan =
              case journal do
                {:ok, _events} = ok ->
                  ok

                :unavailable ->
                  replay_plan(Keyword.get(opts, :transport), task_id, last_seen, gen, v11?)
              end

            {resume?, replay} =
              case plan do
                {:ok, events} -> {true, events}
                :unavailable -> {is_integer(last_seen) and last_seen == gen and v11?, []}
              end

            conn = start_sse(conn)

            # `:wire_task` lets an owner-scoped transport strip its internal
            # metadata (verified identity, owner key) from the snapshot.
            wire_task = Keyword.get(opts, :wire_task) || (& &1)

            conn =
              if resume?,
                do: conn,
                else: send_task_snapshot(conn, jsonrpc_id, wire_task.(task))

            conn =
              Enum.reduce(replay, conn, fn {_seq, _kind, payload, _final?}, conn ->
                write_wrapped(conn, jsonrpc_id, payload)
              end)

            replayed_final? =
              Enum.any?(replay, fn {_, kind, payload, final?} ->
                final? or
                  (kind == "status-update" and
                     AshA2A.A2ATransport.TaskEvents.terminal_payload?(payload))
              end)

            # `prev` is the snapshot the agent fan-out's next one is compared
            # with: every mutation in between is one event at its own
            # generation (`AshA2A.Protocol.Task.Delta`, A2A v1.1 3.2.7).
            st = %{
              floor: if(resume?, do: last_seen),
              seen: gen,
              prev: task,
              v11?: v11?,
              id: jsonrpc_id,
              task_id: task_id
            }

            # After a journal replay, a non-terminal task with no local live
            # producer (fresh agent / second node: the snapshot came from the
            # TaskStore) would otherwise wait for events nobody will send.
            # It gets a bounded wait, then a StreamError close (see
            # `orphan_close/3`) instead of hanging to the idle timeout.
            st =
              Map.put(
                st,
                :orphan_grace,
                if(
                  match?({:ok, _}, journal) and awaiting_producer?(task, replay) and
                    not local_producer?(agent, task_id),
                  do: orphan_grace_ms(idle_timeout)
                )
              )

            if resume? and (AshA2A.Protocol.Task.terminal?(task) or replayed_final?),
              do: conn,
              else: relay_task_events(conn, jsonrpc_id, idle_timeout, st)

          {:error, :not_found} ->
            send_jsonrpc_error(conn, jsonrpc_id, Error.task_not_found())

          {:error, :terminal} ->
            terminal_resume(conn, agent, task_id, jsonrpc_id, last_seen, opts)
        end
      else
        {:error, %Error{} = error} -> send_jsonrpc_error(conn, jsonrpc_id, error)
      end
    end

    # A terminal task cannot be subscribed to (-32004), except a v1.1
    # lastSeenGeneration resume that a retained transport log can serve: the
    # missed events (possibly none) are replayed without a Task snapshot and
    # the stream closes.
    defp terminal_resume(conn, agent, task_id, jsonrpc_id, last_seen, opts) do
      version = Keyword.get(opts, :version) || AshA2A.Protocol.Version.get_negotiated(conn)
      v11? = AshA2A.Protocol.Version.at_least?(version, "1.1")

      with true <- is_integer(last_seen) and v11?,
           {:ok, task} <- GenServer.call(agent, {:get_task, task_id}),
           gen = AshA2A.Protocol.Task.Generation.generation_of(task),
           {:ok, events} <- terminal_plan(opts, task_id, last_seen, gen) do
        conn = start_sse(conn)

        Enum.reduce(events, conn, fn {_seq, _kind, payload, _final?}, conn ->
          write_wrapped(conn, jsonrpc_id, payload)
        end)
      else
        _ -> send_jsonrpc_error(conn, jsonrpc_id, Error.unsupported_operation())
      end
    end

    defp terminal_plan(opts, task_id, last_seen, gen) do
      case journal_plan(task_id, last_seen, gen, true) do
        {:ok, _events} = ok -> ok
        :unavailable -> replay_plan(Keyword.get(opts, :transport), task_id, last_seen, gen, true)
      end
    end

    # Replay through the durable `AshA2A.Protocol.EventJournal` configured by
    # `config :ash_a2a, :event_journal, {module, ref}` (same convention as
    # `:task_store`; unset means no journal). The module is resolved at runtime:
    # when it is unset, not loaded, lacks `replay_after/3`, errors, or retains
    # nothing for a client that is behind (`last_seen < gen`), this is
    # `:unavailable` and the caller falls back to the node-local transport log
    # / snapshot. The writer is `AshA2A.Protocol.EventJournal.record_task/3`,
    # called from `AshA2A.Protocol.Agent.State.put_task_checked/2`.
    defp journal_plan(task_id, last_seen, gen, true) when is_integer(last_seen) do
      with {mod, ref} when is_atom(mod) <- Application.get_env(:ash_a2a, :event_journal),
           true <- Code.ensure_loaded?(mod),
           true <- function_exported?(mod, :replay_after, 3),
           {:ok, raw} when is_list(raw) <- safe_replay_after({mod, ref}, task_id, last_seen) do
        events =
          raw
          |> Enum.map(&normalize_journal_event/1)
          |> Enum.reject(fn {_, kind, payload, _} ->
            g = AshA2A.A2ATransport.TaskEvents.generation_of(payload)
            kind == "task" or not (is_integer(g) and g > last_seen)
          end)
          |> AshA2A.A2ATransport.TaskEvents.visible("1.1")

        if events == [] and last_seen < (gen || 0), do: :unavailable, else: {:ok, events}
      else
        _ -> :unavailable
      end
    end

    defp journal_plan(_task_id, _last_seen, _gen, _v11?), do: :unavailable

    defp safe_replay_after(journal, task_id, last_seen) do
      AshA2A.Protocol.EventJournal.replay_after(journal, task_id, last_seen)
    rescue
      _ -> {:error, :journal_failed}
    catch
      :exit, _ -> {:error, :journal_failed}
    end

    defp normalize_journal_event({_, _, _, _} = event), do: event

    defp normalize_journal_event(%{} = payload) do
      kind =
        cond do
          Map.has_key?(payload, "statusUpdate") -> "status-update"
          Map.has_key?(payload, "artifactUpdate") -> "artifact-update"
          Map.has_key?(payload, "messageUpdate") -> "message-update"
          Map.has_key?(payload, "task") -> "task"
          true -> "event"
        end

      {0, kind, payload, AshA2A.A2ATransport.TaskEvents.terminal_payload?(payload)}
    end

    defp normalize_journal_event(_other), do: {0, "event", %{}, false}

    # Only a task that is being worked on (submitted/working) needs a live
    # producer to advance. An interrupted task (input/auth-required) advances
    # on the next client message, which any node holding the TaskStore can
    # serve, so its stream stays open. The state is the last replayed status
    # when there is one, else the snapshot's.
    defp awaiting_producer?(task, replay) do
      replayed =
        replay
        |> Enum.reverse()
        |> Enum.find_value(fn {_, _, payload, _} ->
          AshA2A.A2ATransport.TaskEvents.payload_state(payload)
        end)

      case replayed do
        nil -> task.status.state in [:submitted, :working]
        state -> state in ["submitted", "working"]
      end
    end

    # A task this agent process ran or continued is held in its memory; a
    # task it can only read through the TaskStore (fresh agent, second node)
    # has no producer here.
    defp local_producer?(agent, task_id) do
      GenServer.call(agent, {:ash_a2a_task_local?, task_id}) == true
    catch
      :exit, _ -> false
    end

    defp orphan_grace_ms(idle_timeout) do
      grace = Application.get_env(:ash_a2a, :resubscribe_orphan_grace_ms, 500)
      if is_integer(idle_timeout), do: min(idle_timeout, grace), else: grace
    end

    # Documented close for a non-terminal task with no live producer: a
    # `StreamError` frame (code `PRODUCER_UNAVAILABLE`) and the stream ends.
    # The task is NOT reported terminal; the client should `tasks/get` and
    # resubscribe against the node that owns the producer.
    defp orphan_close(conn, jsonrpc_id, task_id) do
      write_stream_error(
        conn,
        jsonrpc_id,
        %AshA2A.Protocol.StreamError{
          task_id: task_id,
          code: "PRODUCER_UNAVAILABLE",
          message: "No live producer for this task on this node; journal replay is complete."
        }
      )
    end

    # `{:ok, events}` (possibly empty) when a running transport log can serve
    # the resume; `:unavailable` otherwise (no transport, no lastSeenGeneration,
    # pre-1.1 client, or the log no longer retains the range).
    defp replay_plan(transport, task_id, last_seen, gen, true)
         when is_atom(transport) and not is_nil(transport) and is_integer(last_seen) do
      if AshA2A.A2ATransport.running?(transport) do
        log = AshA2A.A2ATransport.TaskEvents.backlog(transport, task_id)

        case AshA2A.A2ATransport.TaskEvents.replay_from_generation(log, last_seen, gen) do
          {:ok, replay, _cursor} -> {:ok, AshA2A.A2ATransport.TaskEvents.visible(replay, "1.1")}
          :unavailable -> :unavailable
        end
      else
        :unavailable
      end
    end

    defp replay_plan(_transport, _task_id, _last_seen, _gen, _v11?), do: :unavailable

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
      wait = Map.get(st, :orphan_grace) || idle_timeout

      receive do
        {:a2a_stream_error, _task_id, wrapped} ->
          conn
          |> write_wrapped(jsonrpc_id, wrapped)
          |> relay_task_events(jsonrpc_id, idle_timeout, Map.put(st, :orphan_grace, nil))

        {:a2a_task_event, _task_id, task} ->
          terminal? = AshA2A.Protocol.Task.terminal?(task)

          # One frame per mutation since the previous snapshot, each at the
          # task's generation after it; nothing at a generation already sent.
          events =
            for {gen, event} <- AshA2A.Protocol.Task.Delta.events(Map.get(st, :prev), task),
                gen > st.seen,
                st.v11? or not match?(%AshA2A.Protocol.Event.MessageUpdate{}, event),
                do: {gen, event}

          result =
            Enum.reduce_while(events, conn, fn {_gen, event}, conn ->
              {:ok, encoded} = AshA2A.Protocol.JSON.encode_stream_response(event)

              case send_event(conn, jsonrpc_id, encoded) do
                {:error, conn} -> {:halt, {:error, conn}}
                conn -> {:cont, conn}
              end
            end)

          case result do
            {:error, conn} ->
              conn

            conn ->
              gen = AshA2A.Protocol.Task.Generation.generation_of(task)

              st =
                %{st | seen: max(st.seen, gen)}
                |> Map.put(:prev, task)
                |> Map.put(:orphan_grace, if(events == [], do: Map.get(st, :orphan_grace)))

              if terminal?,
                do: conn,
                else: relay_task_events(conn, jsonrpc_id, idle_timeout, st)
          end

        # Unknown StreamResponse payloads forwarded verbatim.
        {:a2a_stream_frame, _task_id, %{} = frame} ->
          conn
          |> write_wrapped(jsonrpc_id, frame)
          |> relay_task_events(jsonrpc_id, idle_timeout, Map.put(st, :orphan_grace, nil))
      after
        # A task that never reaches a terminal state would otherwise pin this
        # connection process indefinitely.
        wait ->
          if Map.get(st, :orphan_grace),
            do: orphan_close(conn, jsonrpc_id, Map.get(st, :task_id)),
            else: conn
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

      # Every chunk of one stream belongs to one artifact (the id the agent
      # stores it under) and is one stored mutation: its frame carries the
      # task's generation after it (A2A v1.1 3.2.7).
      artifact_id =
        Map.get(task.metadata, :stream_artifact_id) || AshA2A.Protocol.ID.generate("art")

      Enum.reduce_while(enum, {conn, start}, fn part, {conn, last} ->
        artifact = %{AshA2A.Protocol.Artifact.new([part]) | artifact_id: artifact_id}
        stored = AshA2A.Protocol.Agent.Runtime.chunk_generation(task.id)
        gen = if is_integer(stored) and stored > last, do: stored, else: last + 1

        event =
          AshA2A.Protocol.Event.ArtifactUpdate.new(task.id, artifact,
            context_id: task.context_id,
            append: if(last > start, do: true),
            last_chunk: if(AshA2A.Protocol.Agent.Runtime.chunk_last?(task.id), do: true),
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
