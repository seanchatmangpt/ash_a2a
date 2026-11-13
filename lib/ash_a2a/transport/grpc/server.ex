defmodule AshA2A.Transport.GRPC.Server do
  @moduledoc """
  Real gRPC server transport for the A2A v1.0 gRPC binding: the canonical
  `a2aproject/A2A` proto service `lf.a2a.v1.A2AService`, served over HTTP/2
  (cowboy via the `:grpc_server` package).

  **Scope: ALIVE.** Every unary RPC delegates to the SAME dispatch layer the
  HTTP binding uses — `AshA2A.Transport.Grpc.Dispatch.call/4`, which routes
  through `AshA2A.Protocol.JSONRPC.handle/3` — with protobuf messages mapped
  to/from the codec's proto-JSON maps via `Protobuf.JSON` (proto3 JSON).
  The two server-streaming RPCs are driven by the same per-task event log the
  SSE transport uses (`AshA2A.A2ATransport.TaskEvents`) and pump the agent's
  stream through `AshA2A.A2ATransport.SSE.pump/4`, so gRPC and SSE
  subscribers see the same events in the same order.

  ## Wiring

      {:ok, _pid, port} =
        GRPC.Server.start_endpoint(AshA2A.Transport.GRPC.Server.Endpoint, 50051)

      Application.put_env(:ash_a2a, AshA2A.Transport.GRPC.Server,
        handler: MyApp.A2APlug,
        ctx: %{agent: agent_pid, opts: %{authorize_task: nil}}
      )

  Optional env keys beside `:handler`/`:ctx`: `:versions` (supported
  A2A-Version list for the gate, default `Version.supported_default/0`) and
  `:extensions` (the same entries the HTTP binding's `a2a.extensions` takes;
  required extensions are enforced, activated URIs are echoed in the
  `a2a-extensions` response metadata, -32008 is FAILED_PRECONDITION(9)).

  ## TLS

  Pass `cred: GRPC.Credential.new(ssl: [certfile: ..., keyfile: ...])` to
  `GRPC.Server.start_endpoint/3` (or `AshA2A.Transport.GRPC.Supervisor`'s
  `:cred` option) to serve TLS; without it the listener is plain HTTP/2.
  Clients connect with `cred:` on `GRPC.Stub.connect/2` likewise.

  `:handler` (the `AshA2A.Protocol.JSONRPC` behaviour module the HTTP binding
  uses) is required at call time — calls are refused UNAVAILABLE(14) without
  it; `:ctx` defaults to `%{}`. The streaming RPCs additionally read
  `:transport` from the ctx (an `AshA2A.A2ATransport` instance name,
  default `AshA2A.A2ATransport`), whose `TaskEvents` registry the gRPC
  streams subscribe to.

  ## Proto-JSON bridging

  The codec's wire maps (`AshA2A.Protocol.JSON`) and proto3 JSON agree on
  member names (`taskId`, `contextId`, `historyLength`, `mediaType`) and enum
  spellings (`TASK_STATE_COMPLETED`, `ROLE_USER`), so the bridge is
  `Protobuf.JSON` in both directions with no hand-written per-field mapping:

      request -> Protobuf.JSON.encode! -> Jason.decode! -> proto-JSON map
      result  -> Jason.encode! -> Protobuf.JSON.decode!(resp_mod, _)

  Regeneration of the committed projection
  `lib/ash_a2a/transport/grpc/pb/lf/a2a/v1/a2a.pb.ex` (never hand-edited) is
  documented in `priv/proto/a2a.proto`'s provenance header.
  """

  use GRPC.Server, service: Lf.A2a.V1.A2AService.Service

  alias AshA2A.A2ATransport
  alias AshA2A.A2ATransport.{SSE, TaskEvents}
  alias AshA2A.Protocol
  alias AshA2A.Protocol.JSONRPC.Request
  alias AshA2A.Protocol.Telemetry
  alias AshA2A.Trace.W3C
  alias AshA2A.Transport.Grpc.Dispatch
  alias AshA2A.Transport.GRPC.Downgrade
  alias AshA2A.Transport.Principal
  alias Lf.A2a.V1, as: Pb

  # -- unary RPCs -----------------------------------------------------------

  def send_message(req, mat), do: unary("SendMessage", req, mat, Pb.SendMessageResponse)

  def get_task(req, mat), do: unary("GetTask", req, mat, Pb.Task)

  def cancel_task(req, mat), do: unary("CancelTask", req, mat, Pb.Task)

  def list_tasks(req, mat), do: unary("ListTasks", req, mat, Pb.ListTasksResponse)

  def create_task_push_notification_config(req, mat) do
    unary("CreateTaskPushNotificationConfig", req, mat, Pb.TaskPushNotificationConfig)
  end

  def get_task_push_notification_config(req, mat) do
    unary("GetTaskPushNotificationConfig", req, mat, Pb.TaskPushNotificationConfig)
  end

  def list_task_push_notification_configs(req, mat) do
    unary(
      "ListTaskPushNotificationConfigs",
      req,
      mat,
      Pb.ListTaskPushNotificationConfigsResponse
    )
  end

  def get_extended_agent_card(req, mat) do
    unary("GetExtendedAgentCard", req, mat, Pb.AgentCard)
  end

  # Per the proto this returns google.protobuf.Empty. The runtime's dispatch
  # layer refuses push-notification-config CRUD with -32003, which the
  # dispatch's error mapping turns into FAILED_PRECONDITION(9) before a response
  # type is ever needed; the Empty target exists for hosts whose handler
  # implements the optional push callbacks.
  def delete_task_push_notification_config(req, mat) do
    unary("DeleteTaskPushNotificationConfig", req, mat, Google.Protobuf.Empty)
  end

  # -- server-streaming RPCs ------------------------------------------------

  # Both streaming RPCs answer with a direct GRPC.Server.send_reply loop over
  # the shared per-task event log instead of a Flow pipeline: the Flow-based
  # path buffers until the stream halts (observed: backlog events never
  # reached the client before halt, so any non-terminal task's subscribe
  # stream stayed silent until the client deadline), while the send_reply loop
  # emits each event the moment the log has it — true push semantics (spec
  # §3.5.2, TCK STREAM-ORDER/STREAM-SUB).
  def send_streaming_message(req, mat), do: streaming("SendStreamingMessage", req, mat)

  def subscribe_to_task(req, mat), do: streaming("SubscribeToTask", req, mat)

  # -- bidirectional streaming (v1.1 SendLiveMessage, spec 3.1.12) -----------

  # Native duplex over the transport-independent `AshA2A.Transport.Live` core.
  # The handler process owns the downlink (it receives `{:a2a_live, sid, event}`
  # and writes StreamResponse frames); a reader process drains the client's
  # StreamRequest uplink into `Live.uplink/2`. Per-request rejections are
  # `StreamError` events on the downlink and never close the stream. The RPC
  # ends on a terminal task (`:a2a_live_closed`) or client half-close.
  def send_live_message(req_enum, mat) do
    session_result =
      span("SendLiveMessage", fn ->
        auth = auth!(mat)
        gate!(mat)
        ctx = auth |> call_ctx() |> with_version(mat)
        open_live(ctx, auth)
      end)

    case session_result do
      {:ok, session, ctx} ->
        run_live(req_enum, mat, session, ctx)

      {:error, %GRPC.RPCError{} = error} ->
        raise error
    end
  end

  defp open_live(ctx, auth) do
    agent = Map.get(ctx, :agent)
    live_ctx = %{metadata: live_metadata(ctx, auth)}

    live_ctx =
      case Map.get(ctx, :principal) do
        nil -> live_ctx
        principal -> Map.put(live_ctx, :principal, principal)
      end

    case AshA2A.Transport.Live.open(agent, live_ctx, self()) do
      {:ok, session} ->
        {:ok, session, ctx}

      {:error, :unsupported_operation} ->
        {:error,
         GRPC.RPCError.exception(
           status: 12,
           message: "This operation is not supported",
           details: [error_info("UNSUPPORTED_OPERATION", "SendLiveMessage")]
         )}

      {:error, _} ->
        {:error, GRPC.RPCError.exception(status: 14, message: "agent unavailable")}
    end
  end

  defp live_metadata(ctx, auth) do
    base =
      case Map.get(ctx, :opts) do
        %{} = opts -> Map.get(opts, :metadata, %{})
        opts when is_list(opts) -> Keyword.get(opts, :metadata, %{})
        _ -> %{}
      end

    base = if is_map(base), do: Map.drop(base, ["a2a.auth", "ash_a2a.owner"]), else: %{}
    if auth, do: Map.put(base, "a2a.auth", auth), else: base
  end

  defp run_live(req_enum, mat, session, ctx) do
    parent = self()
    ref = make_ref()
    version = Map.get(ctx, :a2a_version)

    reader =
      spawn(fn ->
        try do
          Enum.each(req_enum, fn req ->
            case to_params(req) do
              {:ok, params} ->
                AshA2A.Transport.Live.uplink(session, Map.delete(params, "tenant"))

              {:error, _} ->
                :ok
            end
          end)
        catch
          _, _ -> :ok
        end

        send(parent, {ref, :half_closed})
      end)

    try do
      live_loop(mat, session, ref, version)
    after
      Process.exit(reader, :kill)
      AshA2A.Transport.Live.close(session)
    end

    {:ok, mat, :noreply}
  end

  defp live_loop(mat, session, ref, version) do
    receive do
      {:a2a_live, _sid, event} ->
        send_live_event(mat, event, version)
        live_loop(mat, session, ref, version)

      {:a2a_live_closed, _sid, _reason} ->
        :ok

      {^ref, :half_closed} ->
        # Client half-close: let the session flush what it already accepted.
        AshA2A.Transport.Live.close(session)
        drain_live(mat, version)
    end
  end

  defp drain_live(mat, version) do
    receive do
      {:a2a_live, _sid, event} ->
        send_live_event(mat, event, version)
        drain_live(mat, version)

      {:a2a_live_closed, _sid, _reason} ->
        :ok
    after
      500 -> :ok
    end
  end

  defp send_live_event(mat, %AshA2A.Protocol.Event.MessageUpdate{} = event, version) do
    if AshA2A.Protocol.Version.at_least?(version, "1.1") do
      do_send_live_event(mat, event)
    else
      :ok
    end
  end

  defp send_live_event(mat, event, _version), do: do_send_live_event(mat, event)

  defp do_send_live_event(mat, event) do
    GRPC.Server.send_reply(mat, to_pb!(Pb.StreamResponse, AshA2A.Transport.Live.encode(event)))
  end

  defp last_seen_generation(params) do
    case Map.get(params, "lastSeenGeneration") do
      n when is_integer(n) and n >= 0 ->
        n

      s when is_binary(s) ->
        case Integer.parse(s) do
          {n, ""} when n >= 0 -> n
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp with_version(ctx, mat),
    do: Map.put(ctx, :a2a_version, AshA2A.Protocol.Version.parse_header(request_version(mat)))

  # The request span covers the stream SETUP (auth, gates, dispatch, subscribe),
  # not the whole stream.
  defp streaming(rpc, req, mat) do
    trace = W3C.extract(request_headers(mat))

    result =
      span(rpc, fn ->
        auth = auth!(mat)
        gate!(mat)
        start_stream(rpc, req, with_version(call_ctx(auth), mat), auth, trace)
      end)

    case result do
      {:ok, events} -> stream_loop(mat, events)
      {:error, %GRPC.RPCError{} = error} -> raise error
    end
  end

  # `[:ash_a2a, :transport, :request]` span for one RPC. `ok?` is false when
  # the body raises or returns `{:error, _}`; a raise is re-raised unchanged
  # after the span closes.
  defp span(rpc, fun) do
    outcome =
      Telemetry.request_span(:grpc, %{rpc: rpc}, fn ->
        try do
          result = fun.()
          {{:returned, result}, not (match?({:error, _}, result) or match?({:err_run, _}, result))}
        rescue
          e -> {{:raised, e, __STACKTRACE__}, false}
        end
      end)

    case outcome do
      {:returned, result} -> result
      {:raised, e, stacktrace} -> reraise e, stacktrace
    end
  end

  defp request_headers(mat) do
    case GRPC.Stream.get_headers(mat) do
      %{} = headers -> headers
      _ -> %{}
    end
  end

  defp stream_loop(mat, events) do
    wire = wire_version(mat)

    Enum.each(events, fn {payload, _seq} ->
      case Downgrade.strip(to_pb!(Pb.StreamResponse, payload), wire) do
        :drop -> :ok
        frame -> GRPC.Server.send_reply(mat, frame)
      end
    end)

    {:ok, mat, :noreply}
  end

  # -- bridging -------------------------------------------------------------

  defp unary(method, req, mat, resp_mod) do
    trace = W3C.extract(request_headers(mat))
    parent = self()
    ref = make_ref()

    outcome =
      span(method, fn ->
        auth = auth!(mat)
        gate!(mat)
        call_ctx = auth |> call_ctx() |> with_version(mat)

        run =
          req
          |> GRPC.Stream.unary(materializer: mat)
          |> GRPC.Stream.map(fn _ ->
            case dispatch_unary(method, req, resp_mod, call_ctx, trace, wire_version(mat)) do
              {:error, _} = error ->
                send(parent, {ref, :rpc_error})
                error

              ok ->
                ok
            end
          end)
          |> GRPC.Stream.run()

        # An error status raised/returned inside the stream pipeline is
        # reported over the message so the span's `ok?` reflects it.
        receive do
          {^ref, :rpc_error} -> {:err_run, run}
        after
          0 -> {:ok_run, run}
        end
      end)

    {_tag, run} = outcome
    run
  end

  # The version as the client sent it: `nil` when no A2A-Version header was
  # sent (no downgrade), else the normalized `Major.Minor`.
  defp wire_version(mat) do
    case request_version(mat) do
      nil -> nil
      "" -> nil
      [] -> nil
      raw -> AshA2A.Protocol.Version.parse_header(raw)
    end
  end

  defp dispatch_unary(method, req, resp_mod, call_ctx, trace, wire) do
    with {:ok, params} <- to_params(req),
         {params, call_ctx} = bind_request(params, call_ctx, trace),
         {:ok, result} <- dispatch_call(method, params, call_ctx) do
      Downgrade.strip(to_pb!(resp_mod, result), wire)
    else
      {:error, %GRPC.RPCError{}} = error -> error
      {:error, code, msg, details} -> {:error, rpc_error(code, msg, details)}
    end
  end

  # SendMessage goes through a thin handler wrapper that turns the agent's raw
  # send-path refusal reasons (:context_mismatch, :not_continuable,
  # {:content_type_not_supported, _}) into typed A2A errors.
  defp dispatch_call("SendMessage", params, call_ctx) do
    real = handler!()
    Dispatch.call_detailed("SendMessage", params, __MODULE__.SendHandler, Map.put(call_ctx, :grpc_handler, real))
  end

  defp dispatch_call(method, params, call_ctx),
    do: Dispatch.call_detailed(method, params, handler!(), call_ctx)

  # -- request binding: tenant, trace ---------------------------------------

  @tenant_keys ["ash_a2a.tenant", "a2a.tenant"]

  # Binds the proto request `tenant` field (the only lawful tenant source)
  # into call metadata under "ash_a2a.tenant" and scopes the principal;
  # client-supplied tenant metadata is dropped. A valid traceparent (gRPC
  # metadata wins over the message's own) rides in the message metadata the
  # dispatcher's correlation reads.
  defp bind_request(params, ctx, trace) do
    tenant =
      case Map.get(params, "tenant") do
        t when is_binary(t) and t != "" -> t
        _ -> nil
      end

    params = params |> scrub_tenant() |> inject_trace(trace)
    ctx = ctx |> bind_tenant_metadata(tenant) |> scope_principal(tenant)
    {params, ctx}
  end

  defp scrub_tenant(params) do
    params
    |> scrub_metadata_at("metadata")
    |> then(fn
      %{"message" => %{} = message} = p -> Map.put(p, "message", scrub_metadata_at(message, "metadata"))
      p -> p
    end)
  end

  defp scrub_metadata_at(map, key) do
    case Map.get(map, key) do
      %{} = md -> Map.put(map, key, Map.drop(md, @tenant_keys))
      _ -> map
    end
  end

  defp inject_trace(%{"message" => %{} = message} = params, header_ctx) do
    md = if is_map(message["metadata"]), do: message["metadata"], else: %{}
    trace = W3C.resolve(header_ctx, W3C.from_metadata(md))

    if map_size(trace) == 0 do
      params
    else
      md =
        md
        |> Map.put("traceparent", trace.traceparent)
        |> then(fn m ->
          case trace do
            %{tracestate: ts} -> Map.put(m, "tracestate", ts)
            _ -> Map.delete(m, "tracestate")
          end
        end)

      Map.put(params, "message", Map.put(message, "metadata", md))
    end
  end

  defp inject_trace(params, _trace), do: params

  defp bind_tenant_metadata(ctx, nil), do: ctx

  defp bind_tenant_metadata(ctx, tenant) do
    opts =
      case Map.get(ctx, :opts) do
        %{} = opts -> opts
        opts when is_list(opts) -> if Keyword.keyword?(opts), do: Map.new(opts), else: %{}
        _ -> %{}
      end

    md =
      case Map.get(opts, :metadata) do
        %{} = md -> Map.drop(md, @tenant_keys)
        _ -> %{}
      end

    Map.put(ctx, :opts, Map.put(opts, :metadata, Map.put(md, "ash_a2a.tenant", tenant)))
  end

  defp scope_principal(ctx, nil), do: ctx

  defp scope_principal(ctx, tenant) do
    key =
      case Map.get(ctx, :principal, :anonymous) do
        {key, _old_tenant} -> key
        key -> key
      end

    Map.put(ctx, :principal, Principal.scope(key, tenant))
  end

  defp start_stream("SendStreamingMessage", req, ctx, auth, trace) do
    with {:ok, params} <- to_params(req),
         {params, ctx} = bind_request(params, ctx, trace),
         {:stream, "message/stream", params, _id} <-
           Dispatch.call_detailed("SendStreamingMessage", params, handler!(), ctx) do
      start_message_stream(params, ctx, auth)
    else
      {:error, %GRPC.RPCError{}} = error ->
        error

      {:error, code, msg, details} ->
        {:error, rpc_error(code, msg, details)}

      {:ok, _} ->
        {:error,
         GRPC.RPCError.exception(
           status: 13,
           message: "SendStreamingMessage dispatched a unary result"
         )}
    end
  end

  defp start_stream("SubscribeToTask", req, ctx, _auth, trace) do
    with {:ok, params} <- to_params(req),
         {params, ctx} = bind_request(params, ctx, trace),
         {:stream, "tasks/resubscribe", params, _id} <-
           Dispatch.call_detailed("SubscribeToTask", params, handler!(), ctx) do
      start_resubscribe_stream(params, ctx)
    else
      {:error, %GRPC.RPCError{}} = error ->
        error

      {:error, code, msg, details} ->
        {:error, rpc_error(code, msg, details)}

      {:ok, _} ->
        {:error,
         GRPC.RPCError.exception(
           status: 13,
           message: "SubscribeToTask dispatched a unary result"
         )}
    end
  end

  defp start_message_stream(params, ctx, auth) do
    message = Map.fetch!(params, "message")
    agent = Map.fetch!(ctx, :agent)
    transport = Map.get(ctx, :transport, A2ATransport.default_name())

    with :ok <- owned_continuation(agent, message, ctx),
         call_opts = call_opts(params, message, ctx, auth),
         {:ok, task, enum} <- Protocol.stream(agent, message, call_opts) do
      {:ok,
       stream_enum(
         transport,
         task.id,
         fn ->
           backlog = TaskEvents.subscribe(transport, task.id, version: Map.get(ctx, :a2a_version))
           _seq = TaskEvents.publish(transport, task.id, "task", SSE.encode_task(task))
           start_pump(transport, agent, task, enum)
           backlog
         end,
         # The initial task snapshot is the first frame the client sees.
         include_task_events: true,
         idle_ms: idle_ms(ctx)
       )}
    else
      {:error, %GRPC.RPCError{} = error} ->
        {:error, error}

      {:error, reason} when reason in [:context_mismatch, :not_continuable] ->
        {:error, send_reason_error(reason)}

      {:error, {:content_type_not_supported, _} = reason} ->
        {:error, send_reason_error(reason)}

      other ->
        # `other` is e.g. {:not_streaming, %Task{}} or {:ok, %Message{}} —
        # SafeError.redact/1 of such terms is still a tuple/map, and
        # interpolating a non-String.Chars term crashes the RPC (surfacing as
        # INTERNAL). Redact to a *string* via inspect/1 before interpolation.
        # Status is FAILED_PRECONDITION(9) — the state-conflict class (A2A
        # v1.0 §5.4's FAILED_PRECONDITION band in the dispatch table:
        # -32002/-32007/-32008).
        redacted = other |> AshA2A.Transport.SafeError.redact() |> inspect()

        {:error,
         GRPC.RPCError.exception(status: 9, message: "Task is not streamable: #{redacted}")}
    end
  end

  # Verified identity -> agent call options. `ctx[:opts]` may be the
  # documented map or a keyword list; only the task/context ids of the message
  # (continuation) and the metadata layers are call options. The verified auth
  # is merged LAST so no caller field can forge it.
  defp call_opts(params, message, ctx, auth) do
    base =
      case Map.get(ctx, :opts) do
        %{} = opts -> Map.get(opts, :metadata, %{})
        opts when is_list(opts) -> Keyword.get(opts, :metadata, %{})
        _ -> %{}
      end

    base = if is_map(base), do: Map.drop(base, ["a2a.auth", "ash_a2a.owner"]), else: %{}
    metadata = if auth, do: Map.put(base, "a2a.auth", auth), else: base

    configuration = if is_map(params["configuration"]), do: params["configuration"], else: nil

    []
    |> put_opt(:task_id, message.task_id)
    |> put_opt(:context_id, message.context_id)
    |> put_opt(:metadata, if(metadata == %{}, do: nil, else: metadata))
    |> put_opt(:return_immediately, if(Request.return_immediately(configuration), do: true))
    |> put_opt(:accepted_output_modes, Request.accepted_output_modes(configuration))
  end

  defp send_reason_error(reason) do
    {:error, code, msg, details} = Dispatch.reason_error(reason)
    rpc_error(code, msg, details)
  end

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: [{key, value} | opts]

  # A message naming an existing task continues it only for the task's owner
  # (a foreign task is NOT_FOUND, indistinguishable from a missing one).
  defp owned_continuation(_agent, %{task_id: nil}, _ctx), do: :ok

  defp owned_continuation(agent, %{task_id: task_id}, ctx) do
    principal = Map.get(ctx, :principal, :anonymous)

    case A2ATransport.Ownership.fetch_strict(agent, task_id, principal) do
      {:ok, _task} ->
        :ok

      {:error, :unavailable} ->
        {:error, GRPC.RPCError.exception(status: 14, message: "agent unavailable")}

      {:error, :not_found} ->
        {:error, GRPC.RPCError.exception(status: 5, message: "Task not found")}
    end
  end

  defp idle_ms(ctx) do
    case Map.get(ctx, :stream_idle_ms) do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> 60_000
    end
  end

  defp start_resubscribe_stream(params, ctx) do
    handler = handler!()
    task_id = Map.fetch!(params, "id")
    transport = Map.get(ctx, :transport, A2ATransport.default_name())

    with {:ok, task_map} <- Dispatch.call_detailed("GetTask", %{"id" => task_id}, handler, ctx),
         {:ok, task} <- AshA2A.Protocol.JSON.decode(task_map, :task) do
      if AshA2A.Protocol.Task.terminal?(task) do
        # The proto's UnsupportedOperationError (-32004) for an already-terminal
        # task: UNIMPLEMENTED(12) per the pinned TCK (STREAM-SUB-003; reason
        # UNSUPPORTED_OPERATION).
        {:error,
         GRPC.RPCError.exception(
           status: 12,
           message: "This operation is not supported",
           details: [error_info("UNSUPPORTED_OPERATION", task_id)]
         )}
      else
        agent = Map.get(ctx, :agent)
        version = Map.get(ctx, :a2a_version)

        # v1.1 lastSeenGeneration: when set and the log retains that range, no
        # snapshot is sent, only the events after that generation; otherwise
        # fall back to the snapshot (never an error).
        replay =
          with gen when is_integer(gen) <- last_seen_generation(params),
               {:ok, events, _cursor} <-
                 transport
                 |> TaskEvents.backlog(task_id)
                 |> TaskEvents.replay_from_generation(gen, Map.get(task, :generation)) do
            {:ok, TaskEvents.visible(events, version)}
          else
            _ -> :snapshot
          end

        {:ok,
         stream_enum(
           transport,
           task_id,
           fn ->
             backlog = TaskEvents.subscribe(transport, task_id, version: version)
             # Ride the agent's own subscriber fan-out too: transitions on the
             # protocol path never reach the TaskEvents log (STREAM-SUB-002).
             if agent, do: safe_agent_subscribe(agent, task_id)

             case replay do
               {:ok, events} -> events
               :snapshot -> backlog
             end
           end,
           # The current snapshot replaces logged "task" events (same as the
           # SSE resubscribe), so a resubscriber always sees one fresh task
           # frame first.
           snapshot: if(replay == :snapshot, do: SSE.encode_task(task)),
           idle_ms: idle_ms(ctx)
         )}
      end
    else
      {:error, code, msg, details} -> {:error, rpc_error(code, msg, details)}
      {:error, _decode} -> {:error, GRPC.RPCError.exception(status: 13, message: "Internal error")}
    end
  end

  defp safe_agent_subscribe(agent, task_id) do
    GenServer.call(agent, {:subscribe, task_id}, 5_000)
  catch
    :exit, _ -> :error
  end

  # The pump is the SSE transport's own public pump: it consumes the agent's
  # stream, publishing one "artifact-update" event per part and a final
  # "status-update" carrying the task's real post-stream state, so gRPC
  # subscribers and SSE subscribers observe the same event log.
  defp start_pump(transport, agent, task, enum) do
    Task.Supervisor.start_child(A2ATransport.task_sup_name(transport), fn ->
      SSE.pump(transport, agent, task, enum)
    end)
  end

  # A lazy enumerator over the task's event log. `subscribe_fun` runs in the
  # single Flow partition that owns this enumeration (it must be the process
  # that registers with the task's Registry): it subscribes, and for
  # message/stream it also publishes the snapshot and starts the pump. Events
  # logged before the subscribe (minus already-served snapshots) come from
  # the returned backlog, then the subscription mailbox is drained until the
  # final event — the SSE transport's replay-then-follow semantics. Each
  # element is `{proto_json_payload, seq}`; finality halts the stream.
  # The result is piped through a Stream.map/2 identity so the value is a
  # real `%Elixir.Stream{}` struct: Stream.resource/3 alone returns a bare
  # arity-2 fun, which GRPC.Stream.from/2's catch-all clause would wrap in a
  # list and enumerate the fun itself as a single (useless) element.
  @doc false
  def stream_enum(transport, task_id, subscribe_fun, opts \\ []) do
    include_task? = Keyword.get(opts, :include_task_events, false)
    snapshot = Keyword.get(opts, :snapshot)
    idle_ms = Keyword.get(opts, :idle_ms, 60_000)

    Stream.resource(
      fn ->
        queue =
          subscribe_fun.()
          |> Enum.reject(fn {_seq, kind, _payload, _final?} ->
            kind == "task" and not include_task?
          end)
          |> Enum.map(fn {seq, _kind, payload, final?} -> {seq, {payload, final?}} end)

        # The snapshot (seq 0) is emitted ahead of the logged backlog.
        queue = if snapshot, do: [{0, {snapshot, false}} | queue], else: queue
        {queue, 0}
      end,
      fn
        {:done, _last} ->
          {:halt, {:done, 0}}

        {queue, last} ->
          case next_event(queue, last, task_id, idle_ms) do
            {:ok, {seq, {payload, final?}}, rest} ->
              next = if final?, do: {:done, seq}, else: {rest, seq}
              {[{payload, seq}], next}

            :idle ->
              # No final event arrived within the idle window; end the RPC
              # the way the SSE transport ends an idle connection.
              {:halt, {:done, last}}
          end
      end,
      fn _last -> TaskEvents.unsubscribe(transport, task_id) end
    )
    |> Stream.map(& &1)
  end

  defp next_event([], last, task_id, idle_ms) do
    receive do
      {:a2a_task_event, ^task_id, seq, _kind, payload, final?} when seq > last ->
        {:ok, {seq, {payload, final?}}, []}

      # Agent subscriber fan-out (3-tuple): a protocol-path transition that
      # never reached the TaskEvents log.
      {:a2a_task_event, ^task_id, %AshA2A.Protocol.Task{} = task} ->
        terminal? = AshA2A.Protocol.Task.terminal?(task)

        event =
          AshA2A.Protocol.Event.StatusUpdate.new(task.id, task.status,
            context_id: task.context_id,
            final: terminal?
          )

        {:ok, encoded} = AshA2A.Protocol.JSON.encode_stream_response(event)
        {:ok, {last + 1, {encoded, terminal?}}, []}
    after
      idle_ms -> :idle
    end
  end

  # Backlog events interleave with already-delivered live events: a live
  # event whose seq falls before the backlog head is emitted first, a
  # duplicate of a backlog event is dropped (the backlog copy wins).
  defp next_event([{seq, event} | rest], last, task_id, _idle_ms) do
    receive do
      {:a2a_task_event, ^task_id, s, _kind, payload, final?} when s > last and s < seq ->
        {:ok, {s, {payload, final?}}, [{seq, event} | rest]}
    after
      0 -> {:ok, {seq, event}, rest}
    end
  end

  # -- config ---------------------------------------------------------------

  # Optional auth-interceptor seam (BIND-EQUIV-004). When the endpoint env
  # carries `auth: {module, opts}`, module.authenticate(mat, opts) runs BEFORE
  # dispatch on every RPC; `{:error, %GRPC.RPCError{}}` (typically
  # UNAUTHENTICATED(16) from AshA2A.Transport.GRPC.Auth) refuses the call.
  # Unconfigured = the historical anonymous behavior, so the TCK's anonymous
  # gRPC subset and the anonymous wire tests stay green.
  # Returns the verified auth map (`%{identity: ...}`) or nil when anonymous.
  # Fail-closed: a configured-but-malformed endpoint env or a malformed auth
  # option refuses the call (INTERNAL) instead of silently admitting it.
  defp auth!(mat) do
    case Application.get_env(:ash_a2a, AshA2A.Transport.GRPC.Server.Endpoint, []) do
      kw when is_list(kw) ->
        case Keyword.get(kw, :auth) do
          nil -> nil
          {module, opts} when is_atom(module) -> run_auth(module, mat, opts)
          _bad -> raise GRPC.RPCError, status: 13, message: "gRPC auth misconfigured"
        end

      _not_a_list ->
        raise GRPC.RPCError, status: 13, message: "gRPC endpoint configuration invalid"
    end
  end

  defp run_auth(module, mat, opts) do
    Code.ensure_loaded(module)

    result =
      if function_exported?(module, :authenticate_identity, 2),
        do: module.authenticate_identity(mat, opts),
        else: module.authenticate(mat, opts)

    case result do
      :ok -> nil
      {:ok, auth} when is_map(auth) or is_nil(auth) -> auth
      {:error, %GRPC.RPCError{} = error} -> raise error
      {:error, :forbidden} -> raise AshA2A.Transport.GRPC.Auth.forbidden()
      _other -> raise GRPC.RPCError, status: 16, message: ~s({"error":"Unauthorized"})
    end
  end

  # Per-call dispatch context: the host's static ctx plus the VERIFIED
  # principal/auth. They are written last, so a static or caller-supplied value
  # can never override the verified identity; owner scoping over gRPC then
  # works exactly like the HTTP bindings.
  defp call_ctx(nil), do: ctx()

  defp call_ctx(%{identity: identity} = auth) do
    ctx() |> Map.put(:auth, auth) |> Map.put(:principal, AshA2A.Transport.Principal.key(identity))
  end

  defp call_ctx(_other), do: ctx()

  # A2A-Version gate (spec §3.6.2), mirroring the landed HTTP-binding gate in
  # AshA2A.Transport.Plug.handle_json_rpc/1 (plug.ex lines ~208-243): parse
  # + validate against the shared supported list; the refused version is
  # VersionNotSupportedError (-32009). On gRPC that code maps to
  # UNIMPLEMENTED(12) per the pinned TCK (GRPC-ERR-002), and
  # the error carries the spec's google.rpc.ErrorInfo (reason
  # VERSION_NOT_SUPPORTED, domain a2a-protocol.org) in the
  # grpc-status-details-bin trailer — the same ErrorInfo the codec stamps on
  # -32009 in AshA2A.Protocol.JSONRPC.Error (@error_info_reasons). An absent
  # or empty header is tolerated as the "0.3" default (§3.6.2), exactly like
  # the HTTP gate.
  defp gate_version!(mat) do
    version = AshA2A.Protocol.Version.parse_header(request_version(mat))

    case AshA2A.Protocol.Version.validate(version, supported_versions()) do
      :ok ->
        :ok

      {:error, rejected} ->
        raise GRPC.RPCError.exception(
                status: 12,
                message: "Version not supported",
                details: [error_info("VERSION_NOT_SUPPORTED", rejected)]
              )
    end
  end

  # A2A-Extensions gate (spec §3.6.2/§4.5), same sequence as the HTTP binding
  # (AshA2A.A2ATransport.Plug `gated/4`): parse the header, refuse with
  # ExtensionSupportRequired (-32008 -> FAILED_PRECONDITION(9) + ErrorInfo)
  # when a required extension is not requested, run each requested
  # extension's activate/3, and echo the activated URIs as the
  # `a2a-extensions` response metadata.
  defp gate!(mat) do
    gate_version!(mat)
    gate_extensions!(mat)
  end

  defp gate_extensions!(mat) do
    alias AshA2A.Protocol.Extension
    compiled = Extension.compile(configured(:extensions, []))
    requested = Extension.parse_header(request_extensions(mat))

    with :ok <- Extension.validate_required(compiled, requested),
         {:ok, _activations, uris} <- Extension.activate(compiled, requested, %{stream: mat}) do
      if uris != [] do
        GRPC.Server.set_headers(mat, %{"a2a-extensions" => Enum.join(uris, ", ")})
      end

      :ok
    else
      {:error, missing} when is_list(missing) ->
        joined = Enum.join(missing, ", ")

        raise GRPC.RPCError.exception(
                status: 9,
                message: "Client missing required extensions: " <> joined,
                details: [error_info("EXTENSION_SUPPORT_REQUIRED", joined)]
              )

      {:error, %AshA2A.Protocol.JSONRPC.Error{} = err} ->
        raise GRPC.RPCError.exception(status: 9, message: err.message)
    end
  end

  defp request_extensions(mat) do
    case GRPC.Stream.get_headers(mat) do
      %{"a2a-extensions" => value} -> value
      _ -> nil
    end
  end

  defp supported_versions do
    configured(:versions, AshA2A.Protocol.Version.supported_default())
  end

  defp configured(key, default) do
    case Application.get_env(:ash_a2a, __MODULE__) do
      kw when is_list(kw) -> Keyword.get(kw, key, default)
      _ -> default
    end
  end

  defp request_version(mat) do
    case GRPC.Stream.get_headers(mat) do
      %{"a2a-version" => version} -> version
      _ -> nil
    end
  end

  # The `grpc-status-details-bin` ErrorInfo Any list Dispatch.call_detailed/4
  # computes for an A2A error is passed through to GRPC.RPCError's `:details`
  # verbatim; this is the single shaping point for locally-raised refusals.
  defp rpc_error(code, msg, details) do
    if details == [] do
      GRPC.RPCError.exception(status: code, message: msg)
    else
      GRPC.RPCError.exception(status: code, message: msg, details: details)
    end
  end

  # The google.rpc.ErrorInfo detail carried on A2A refusals (spec §5.4): the
  # UPPER_SNAKE_CASE reason (no "Error" suffix) and the a2a-protocol.org
  # domain, matching the JSON-RPC side's ErrorInfo stamping. The trailer's
  # detail list is `repeated google.protobuf.Any`, so the ErrorInfo is packed
  # into an Any with the canonical type URL. Built by hand rather than via
  # Protobuf.Any.pack/1: the committed googleapis projection carries no
  # `full_name` option, so pack/1 mints a prefix-only type URL.
  defp error_info(reason, detail) do
    %Google.Protobuf.Any{
      type_url: "type.googleapis.com/google.rpc.ErrorInfo",
      value:
        Google.Rpc.ErrorInfo.encode(%Google.Rpc.ErrorInfo{
          reason: reason,
          domain: "a2a-protocol.org",
          metadata: %{"detail" => detail}
        })
    }
  end

  defp handler! do
    case Application.get_env(:ash_a2a, __MODULE__) do
      kw when is_list(kw) ->
        Keyword.fetch!(kw, :handler)

      nil ->
        raise GRPC.RPCError,
          status: 14,
          message: "gRPC transport not configured: no :handler in application env"
    end
  end

  defp ctx do
    case Application.get_env(:ash_a2a, __MODULE__) do
      kw when is_list(kw) -> Keyword.get(kw, :ctx, %{})
      nil -> %{}
    end
  end

  # -- proto-JSON bridge ----------------------------------------------------

  defp to_params(req) do
    {:ok, req |> Protobuf.JSON.encode!() |> Jason.decode!() |> normalize_params(req)}
  rescue
    e -> {:error, GRPC.RPCError.exception(status: 3, message: "bad request: #{Exception.message(e)}")}
  end

  # ListTasksRequest.status UNSPECIFIED(0) means "no filter" (proto3 default),
  # never a literal :unknown state filter. historyLength passes through as-is.
  defp normalize_params(params, %Pb.ListTasksRequest{}) do
    Map.reject(params, fn {k, v} ->
      k == "status" and v in ["TASK_STATE_UNSPECIFIED", 0, nil]
    end)
  end

  defp normalize_params(params, _req), do: params

  defp to_pb!(resp_mod, result_map) do
    result_map |> Jason.encode!() |> Protobuf.JSON.decode!(resp_mod)
  end
end

defmodule AshA2A.Transport.GRPC.Server.SendHandler do
  @moduledoc false
  # Used for the SendMessage RPC only: delegates to the host's handler
  # (`ctx.grpc_handler`) and converts the agent's raw send-path refusal reasons
  # into typed A2A errors so they reach the wire as the right gRPC status.
  @behaviour AshA2A.Protocol.JSONRPC

  alias AshA2A.Transport.Grpc.Dispatch

  @impl true
  def handle_send(message, params, ctx) do
    case ctx.grpc_handler.handle_send(message, params, ctx) do
      {:error, reason} = error ->
        case Dispatch.reason_to_error(reason) do
          nil -> error
          typed -> {:error, typed}
        end

      other ->
        other
    end
  end

  @impl true
  def handle_get(task_id, params, ctx), do: ctx.grpc_handler.handle_get(task_id, params, ctx)

  @impl true
  def handle_cancel(task_id, params, ctx), do: ctx.grpc_handler.handle_cancel(task_id, params, ctx)
end

defmodule AshA2A.Transport.GRPC.Server.Endpoint do
  @moduledoc """
  Default `GRPC.Endpoint` hosting `AshA2A.Transport.GRPC.Server`
  (service `lf.a2a.v1.A2AService`). Hosts may instead declare their own
  endpoint with `run AshA2A.Transport.GRPC.Server` to add interceptors.

  ## Auth interceptor seam (BIND-EQUIV-004)

  The optional endpoint option `auth: {module, opts}` (application env under
  `:ash_a2a`, key `AshA2A.Transport.GRPC.Server.Endpoint`) runs
  `module.authenticate(mat, opts)` before every dispatch; failures (an
  `{:error, %GRPC.RPCError{}}` return, typically UNAUTHENTICATED(16)) refuse
  the call. The shipped default is `AshA2A.Transport.GRPC.Auth`, which drives
  the same `AshA2A.Protocol.Plug.Auth` pipeline the HTTP bindings use.
  Unconfigured, the endpoint admits anonymous traffic (backward compatible).
  """

  use GRPC.Endpoint

  run AshA2A.Transport.GRPC.Server
end
