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

  v1.1: logged events carry the task `generation`; `message-update` events are
  delivered only to subscribers that negotiated `>= 1.1`; `tasks/resubscribe`
  honours `lastSeenGeneration` (no Task snapshot, replay of newer events, or a
  snapshot when the log cannot cover it); `write_stream_error/3` emits a
  `StreamError` frame without closing the stream. The stream closes at
  terminal states only.

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
    with {:ok, task, enum} <- stream_or_message(agent, message, call_opts),
         _ = run_on_task(Keyword.get(sse_opts, :on_task), task),
         snapshot = encode_task(task),
         _ = maybe_publish_message_update(transport, task, message),
         _seq = TaskEvents.publish(transport, task.id, "task", snapshot, false, task_gen(task)),
         {:ok, _pid} <- start_pump(transport, agent, task, enum) |> pump_started() do
      backlog = TaskEvents.subscribe(transport, task.id, version: negotiated_version(conn, sse_opts))

      conn
      |> start_sse()
      |> replay_and_follow(transport, task.id, id, backlog, 0, sse_opts)
    else
      {:message, %AshA2A.Protocol.Message{} = reply} ->
        # Spec §3.1.2: a message-only stream is exactly one Message, then close.
        conn |> start_sse() |> write_frame(id, nil, encode_event(reply))

      other ->
        # Typed errors survive (-32001 / -32602 / -32000); SEC-08: no raw
        # reason (it can carry a task with metadata["a2a.auth"]) reaches the wire.
        send_json(conn, Response.error(id, stream_error(other)))
    end
  end

  # A continuation (message.task_id set) appended the client message to the
  # task: broadcast it as a message-update carrying the task's generation after
  # the append. Only >= 1.1 subscribers receive it (TaskEvents gates delivery).
  defp maybe_publish_message_update(transport, task, %AshA2A.Protocol.Message{} = message) do
    if is_binary(message.task_id) and message.task_id == task.id,
      do: publish_message_update(transport, task, message)
  end

  defp maybe_publish_message_update(_transport, _task, _message), do: nil

  @doc """
  Publishes a `message-update` event (a client message appended to `task`) at
  the task's current generation. Returns the event's seq.
  """
  @spec publish_message_update(atom(), AshA2A.Protocol.Task.t(), AshA2A.Protocol.Message.t()) ::
          non_neg_integer()
  def publish_message_update(transport, task, message) do
    event =
      struct(AshA2A.Protocol.Event.MessageUpdate, %{
        task_id: task.id,
        context_id: task.context_id,
        message: message,
        metadata: %{},
        generation: Map.get(task, :generation)
      })

    TaskEvents.publish(transport, task.id, "message-update", encode_event(event), false,
      task_gen(task)
    )
  end

  defp task_gen(task) do
    case Map.get(task, :generation) do
      g when is_integer(g) and g > 0 -> [generation: g]
      _ -> []
    end
  end

  @doc """
  Writes a `StreamError` `StreamResponse` frame on a live SSE connection and
  returns the conn; the stream stays open. The frame carries no `id:` line, so
  `Last-Event-ID` cursors are unaffected.
  """
  @spec write_stream_error(Plug.Conn.t(), term(), AshA2A.Protocol.StreamError.t()) ::
          Plug.Conn.t()
  def write_stream_error(conn, id \\ nil, %AshA2A.Protocol.StreamError{} = error) do
    write_frame(conn, id, nil, encode_stream_error(error))
  end

  @doc false
  def encode_stream_error(%AshA2A.Protocol.StreamError{} = error) do
    case AshA2A.Protocol.JSON.encode_stream_response(error) do
      {:ok, wrapped} ->
        wrapped

      _ ->
        body =
          %{"code" => error.code}
          |> put_present("taskId", error.task_id)
          |> put_present("message", error.message)
          |> put_present("referenceId", error.reference_id)
          |> put_present("metadata", if(error.metadata == %{}, do: nil, else: error.metadata))

        %{"error" => body}
    end
  end

  defp put_present(map, _k, nil), do: map
  defp put_present(map, k, v), do: Map.put(map, k, v)

  defp negotiated_version(conn, sse_opts),
    do: Keyword.get(sse_opts, :version) || AshA2A.Protocol.Version.get_negotiated(conn) || "1.0"

  defp stream_or_message(agent, message, call_opts) do
    case AshA2A.Protocol.stream(agent, message, call_opts) do
      {:ok, %AshA2A.Protocol.Message{} = reply} -> {:message, reply}
      other -> other
    end
  end

  @doc false
  def stream_error({:error, reason}), do: stream_error(reason)
  def stream_error(:not_found), do: Error.task_not_found()
  def stream_error(:terminal), do: Error.unsupported_operation()

  def stream_error({:invalid_params, detail}) when is_binary(detail),
    do: Error.invalid_params(detail)

  def stream_error({:not_streaming, _task}), do: Error.unsupported_operation()
  def stream_error({:ok, %AshA2A.Protocol.Message{}}), do: Error.unsupported_operation()

  def stream_error(reason) do
    %{ref: ref} = AshA2A.Transport.SafeError.internal(:stream_start_failed, reason)
    %{Error.internal_error(%{"code" => "stream_start_failed", "ref" => ref}) | code: -32_000}
  end

  @doc "Handles `tasks/resubscribe` through the transport."
  @spec resubscribe(Plug.Conn.t(), atom(), GenServer.server(), map(), term(), keyword()) ::
          Plug.Conn.t()
  def resubscribe(conn, transport, agent, params, id, sse_opts) do
    task_id = params["id"]

    with true <- is_binary(task_id) || {:error, Error.invalid_params("\"id\" is required")},
         {:ok, task} <- get_task(agent, task_id, Keyword.get(sse_opts, :principal, :anonymous)),
         :ok <- Ownership.authorize(Keyword.get(sse_opts, :authorize), :resubscribe, task),
         {:ok, last_gen} <- last_seen_generation(params) do
      version = negotiated_version(conn, sse_opts)
      backlog = TaskEvents.subscribe(transport, task_id, version: version)

      # The resubscriber's snapshot replaces logged "task" events.
      backlog = Enum.reject(backlog, fn {_, kind, _, _} -> kind == "task" end)

      # v1.1 lastSeenGeneration: when set, no Task snapshot is sent; only events
      # with generation > last_gen are replayed (then live). When the log no
      # longer retains that range, fall back to a snapshot (never an error).
      # Unset: snapshot + Last-Event-ID (seq) replay, as before.
      {backlog, after_seq, snapshot?} =
        with gen when is_integer(gen) <- last_gen,
             {:ok, replay, cursor} <-
               transport
               |> TaskEvents.backlog(task_id)
               |> TaskEvents.replay_from_generation(gen, Map.get(task, :generation)) do
          {TaskEvents.visible(replay, version), cursor, false}
        else
          _ -> {backlog, last_event_id(conn), true}
        end

      retained_final? =
        transport
        |> TaskEvents.backlog(task_id)
        |> Enum.any?(fn {_, kind, _, final?} -> final? and kind != "task" end)

      # Decided BEFORE the SSE response starts: a TERMINAL task with no
      # retained final event to replay is refused with -32004 (spec §3.1.6,
      # STREAM-SUB-003 MUST). A retained log is replayed (STREAM-SUB-002's
      # missed-events semantics). A task paused for input stays subscribed —
      # it can still reach a terminal state later (STREAM-SUB-002).
      cond do
        AshA2A.Protocol.Task.terminal?(task) and not retained_final? ->
          TaskEvents.unsubscribe(transport, task_id)
          send_json(conn, Response.error(id, Error.unsupported_operation()))

        true ->
          conn = start_sse(conn)
          conn = if snapshot?, do: write_frame(conn, id, nil, encode_task(task)), else: conn

          # Nothing newer than last_gen exists and the task is terminal: there
          # is nothing left to follow.
          if not snapshot? and backlog == [] and AshA2A.Protocol.Task.terminal?(task) do
            done(conn, transport, task_id)
          else
            resubscribe_follow(conn, transport, agent, task_id, id, backlog, after_seq, sse_opts)
          end
      end
    else
      {:error, %Error{} = error} -> send_json(conn, Response.error(id, error))
    end
  end

  defp resubscribe_follow(conn, transport, agent, task_id, id, backlog, after_seq, sse_opts) do
    # Also ride the agent's own subscriber fan-out: a task completed on
    # the protocol-agent path never reaches the transport TaskEvents
    # log, so without this the stream would never see the terminal
    # transition (TCK STREAM-SUB-002). The {:subscribe, task_id}
    # registration delivers {:a2a_task_event, task_id, task} here at
    # every transition (handled in follow/7).
    _ = safe_subscribe(agent, task_id)

    replay_and_follow(conn, transport, task_id, id, backlog, after_seq, sse_opts)
  end

  # `lastSeenGeneration` (camelCase or snake_case): nil when unset.
  defp last_seen_generation(params) do
    case Map.get(params, "lastSeenGeneration", Map.get(params, "last_seen_generation")) do
      nil ->
        {:ok, nil}

      n when is_integer(n) and n >= 0 ->
        {:ok, n}

      s when is_binary(s) ->
        case Integer.parse(s) do
          {n, ""} when n >= 0 -> {:ok, n}
          _ -> {:error, Error.invalid_params("\"lastSeenGeneration\" must be a non-negative integer")}
        end

      _ ->
        {:error, Error.invalid_params("\"lastSeenGeneration\" must be a non-negative integer")}
    end
  end

  # The agent-side registration is best-effort enrichment (see above): an
  # unreachable agent must not kill the SSE connection process.
  defp safe_subscribe(agent, task_id) do
    GenServer.call(agent, {:subscribe, task_id}, 5_000)
  catch
    :exit, _ -> :error
  end

  defp run_on_task(nil, _task), do: :ok
  defp run_on_task(fun, task) when is_function(fun, 1), do: fun.(task)

  # Owner-scoped: a foreign task is -32001, indistinguishable from a missing one.
  defp get_task(agent, task_id, principal) do
    case Ownership.fetch_strict(agent, task_id, principal) do
      {:ok, task} -> {:ok, task}
      {:error, :unavailable} -> {:error, Error.internal_error("agent unavailable")}
      {:error, _} -> {:error, Error.task_not_found()}
    end
  end

  # -- pump ---------------------------------------------------------------------

  defp pump_started({:ok, pid}) when is_pid(pid), do: {:ok, pid}
  defp pump_started({:ok, pid, _info}) when is_pid(pid), do: {:ok, pid}
  defp pump_started(other), do: {:error, {:pump_start_failed, other}}

  defp start_pump(transport, agent, task, enum) do
    Task.Supervisor.start_child(A2ATransport.task_sup_name(transport), fn ->
      pump(transport, agent, task, enum)
    end)
  end

  @doc false
  def pump(transport, agent, task, enum) do
    # Same id the agent's stream_done fold stamps on the final artifact
    # (:stream_artifact_id); mint only as a fallback.
    artifact_id =
      Map.get(task.metadata, :stream_artifact_id) || AshA2A.Protocol.ID.generate("art")

    artifact = %{AshA2A.Protocol.Artifact.new([]) | artifact_id: artifact_id}

    try do
      # One artifact for the whole stream: the first part creates it, every
      # later part is `append: true`. One-ahead buffering (as in plug.ex): a
      # part is published when its successor arrives; the drain publishes the
      # pending final part with `last_chunk: true`.
      pending =
        Enum.reduce(enum, nil, fn part, pending ->
          case pending do
            nil ->
              {part, 0}

            {prev, index} ->
              publish_chunk(transport, task, artifact, prev, index, false)
              {part, index + 1}
          end
        end)

      case pending do
        nil -> :ok
        {part, index} -> publish_chunk(transport, task, artifact, part, index, true)
      end

      # The agent's stream wrapper casts {:stream_done, ...} from this process
      # when the enum ends; this call is ordered after it, so it observes the
      # task's real post-stream state.
      {final, terminal?, gen_opts} =
        case GenServer.call(agent, {:get_task, task.id}) do
          {:ok, done} ->
            {final_status(done), AshA2A.Protocol.Task.terminal?(done), task_gen(done)}

          {:error, _} ->
            {status_event(task, :completed, nil), true, []}
        end

      # The stream closes at TERMINAL states only (spec 3.1.2/3.1.6 + proto
      # TaskState note): an interrupted state (input-/auth-required) is
      # published non-final, so subscribers stay attached for the task's
      # continuation.
      TaskEvents.publish(transport, task.id, "status-update", final, terminal?, gen_opts)
    rescue
      e -> publish_failed(transport, task, Exception.message(e))
    catch
      # GenServer.call timeout / noproc / a throw from the agent's stream: the
      # subscriber must still get a final frame, never a silent hang.
      kind, reason when kind in [:exit, :throw] ->
        publish_failed(
          transport,
          task,
          "stream #{kind}: #{inspect(reason) |> String.slice(0, 120)}"
        )
    end
  end

  defp publish_chunk(transport, task, artifact, part, index, last?) do
    event =
      AshA2A.Protocol.Event.ArtifactUpdate.new(task.id, %{artifact | parts: List.wrap(part)},
        context_id: task.context_id,
        append: index > 0,
        last_chunk: last?
      )

    TaskEvents.publish(transport, task.id, "artifact-update", encode_event(event))
  end

  defp publish_failed(transport, task, message) do
    TaskEvents.publish(
      transport,
      task.id,
      "status-update",
      status_event(task, :failed, message),
      true
    )
  end

  # -- following ----------------------------------------------------------------

  # Replays the backlog after `after_seq`, then follows live. Also consumes the
  # agent subscriber fan-out (3-tuple, TCK STREAM-SUB-002) when the caller
  # registered with the agent (resubscribe); message/stream never receives it.
  defp replay_and_follow(%Plug.Conn{} = conn, transport, task_id, id, backlog, after_seq, opts) do
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
      {conn, last} ->
        # A Last-Event-ID beyond the log (overshoot) only bounds the backlog replay;
        # live events (seq > anything logged so far) must still be delivered.
        logged_max =
          transport
          |> TaskEvents.backlog(task_id)
          |> Enum.reduce(0, fn {seq, _, _, _}, acc -> if is_integer(seq), do: max(seq, acc), else: acc end)

        follow(conn, transport, task_id, id, min(last, logged_max), opts, 0)
    end
  end

  defp follow(conn, transport, task_id, id, last, opts, idle) do
    heartbeat = Keyword.get(opts, :heartbeat_ms, 15_000)
    max_idle = Keyword.get(opts, :max_idle_ms, 300_000)

    receive do
      # Transport TaskEvents fan-out (6-tuple): the ordered, seq-numbered live
      # stream. Already-delivered seq (backlog/live overlap) is dropped and does
      # not reset the idle bound.
      {:a2a_task_event, ^task_id, seq, _kind, _payload, _final?}
      when is_integer(seq) and seq <= last ->
        follow(conn, transport, task_id, id, last, opts, idle)

      {:a2a_task_event, ^task_id, seq, _kind, payload, final?} when is_integer(seq) ->
        case chunk_frame(conn, id, seq, payload) do
          {:ok, conn} when final? -> done(conn, transport, task_id)
          {:ok, conn} -> follow(conn, transport, task_id, id, seq, opts, 0)
          {:error, conn} -> done(conn, transport, task_id)
        end

      # StreamError for THIS stream (TaskEvents.send_stream_error/3): written as
      # a frame without an id and the stream stays open.
      {:a2a_stream_error, ^task_id, wrapped} ->
        case chunk_frame(conn, id, nil, wrapped) do
          {:ok, conn} -> follow(conn, transport, task_id, id, last, opts, 0)
          {:error, conn} -> done(conn, transport, task_id)
        end

      # Agent subscriber fan-out (3-tuple): task transitions that bypass the
      # TaskEvents log (protocol-path completions).
      {:a2a_task_event, ^task_id, %AshA2A.Protocol.Task{} = task} ->
        if pumped?(transport, task_id) do
          # A pumped task publishes its remaining chunks and its own final
          # status-update through the ordered log; the agent's terminal
          # notification races ahead of the last chunk, so it must not end the
          # stream. The log's final event does.
          follow(conn, transport, task_id, id, last, opts, idle)
        else
          ride_along(conn, transport, task_id, id, last, opts, idle, task)
        end
    after
      heartbeat ->
        idle = idle + heartbeat

        if idle >= max_idle do
          done(conn, transport, task_id)
        else
          case chunk(conn, ": keepalive\n\n") do
            {:ok, conn} -> follow(conn, transport, task_id, id, last, opts, idle)
            {:error, _} -> done(conn, transport, task_id)
          end
        end
    end
  end

  # A pump is in flight when the log holds the task snapshot but no final
  # event yet (the pump's last act is the final status-update). Once a final
  # event exists the pump is done and later transitions (e.g. a resumed
  # input-required task) arrive only through the agent ride-along.
  defp pumped?(transport, task_id) do
    log = TaskEvents.backlog(transport, task_id)

    # In flight = a Task snapshot exists and no terminal/interrupted status
    # event followed the latest one (the pump's last act is that status event;
    # an interrupted pump end is non-final but still ends the pump).
    case for({seq, "task", _, _} <- log, do: seq) do
      [] ->
        false

      seqs ->
        last_snapshot = Enum.max(seqs)

        not Enum.any?(log, fn {seq, kind, payload, _} ->
          seq > last_snapshot and kind == "status-update" and TaskEvents.closing_payload?(payload)
        end)
    end
  end

  # A protocol-path transition is PUBLISHED to the TaskEvents log so it gets a
  # stable seq (Last-Event-ID replay) and reaches every subscriber, including
  # this one, via the 6-tuple clause of follow/7. If the log's latest
  # status-bearing event already carries this state (another subscriber
  # published it first), nothing is republished.
  defp ride_along(conn, transport, task_id, id, last, opts, idle, task) do
    terminal? = AshA2A.Protocol.Task.terminal?(task)

    encoded =
      AshA2A.Protocol.Event.StatusUpdate.new(task.id, task.status,
        context_id: task.context_id,
        final: terminal?
      )
      |> encode_event()

    unless latest_state(transport, task_id) == status_state(encoded) do
      TaskEvents.publish(transport, task_id, "status-update", encoded, terminal?, task_gen(task))
    end

    follow(conn, transport, task_id, id, last, opts, idle)
  end

  defp latest_state(transport, task_id) do
    transport
    |> TaskEvents.backlog(task_id)
    |> Enum.reverse()
    |> Enum.find_value(fn {_, kind, payload, _} ->
      if kind in ["task", "status-update"], do: status_state(payload)
    end)
  end

  defp status_state(payload) do
    get_in(payload, ["statusUpdate", "status", "state"]) ||
      get_in(payload, ["task", "status", "state"])
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
    id_line = if is_nil(seq), do: "", else: "id: #{seq}\n"
    # SSE frames are JSON-RPC envelopes; downgrade the whole envelope.
    case AshA2A.Protocol.DowngradeWire.frame(conn, Response.success(id, payload)) do
      :drop ->
        {:ok, conn}

      {:ok, envelope} ->
        data = id_line <> "data: #{Jason.encode!(envelope)}\n\n"

        case chunk(conn, data) do
          {:ok, conn} -> {:ok, conn}
          {:error, _} -> {:error, conn}
        end
    end
  end

  defp send_json(conn, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(AshA2A.Protocol.DowngradeWire.body(conn, body)))
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
    {:ok, wrapped} =
      task |> Ownership.strip_task() |> AshA2A.Protocol.JSON.encode_stream_response()

    wrapped
  end

  @doc false
  # The task's OWN stored status is re-encoded, not a fresh one: two
  # resubscribers to the same task must receive byte-identical final frames
  # (STREAM-ORDER-003), and a synthesized `DateTime.utc_now()` would stamp a
  # different timestamp per subscriber.
  def final_status(task), do: status_event(task, task.status)

  defp status_event(task, state, message) when is_atom(state) do
    status_event(task, AshA2A.Protocol.Task.Status.new(state, message))
  end

  defp status_event(task, %AshA2A.Protocol.Task.Status{} = status) do
    AshA2A.Protocol.Event.StatusUpdate.new(task.id, status,
      context_id: task.context_id,
      final: AshA2A.Protocol.Task.terminal?(%{task | status: status})
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
