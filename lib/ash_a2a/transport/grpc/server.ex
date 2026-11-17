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
  stream through `AshA2A.A2ATransport.SSE.pump`, so gRPC and SSE
  subscribers see the same events in the same order.

  ## Wiring

      {:ok, _pid, port} =
        GRPC.Server.start_endpoint(AshA2A.Transport.GRPC.Server.Endpoint, 50051)

      Application.put_env(:ash_a2a, AshA2A.Transport.GRPC.Server,
        handler: MyApp.A2APlug,
        ctx: %{agent: agent_pid, opts: %{authorize_task: nil}}
      )

  Optional env keys beside `:handler`/`:ctx`: `:versions` (supported
  A2A-Version list for the gate, default `Version.supported_default`) and
  `:extensions` (the same entries the HTTP binding's `a2a.extensions` takes;
  required extensions are enforced, activated URIs are echoed in the
  `a2a-extensions` response metadata, -32008 is FAILED_PRECONDITION(9)).

  ## TLS

  Pass `cred: GRPC.Credential.new(ssl: [certfile: ..., keyfile: ...])` to
  `GRPC.Server.start_endpoint` (or `AshA2A.Transport.GRPC.Supervisor`'s
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

  # The request codecs hand an undecodable request to the RPC as a marker
  # (answered INVALID_ARGUMENT) instead of raising inside the adapter (UNKNOWN).
  use GRPC.Server,
    service: Lf.A2a.V1.A2AService.Service,
    codecs: [
      AshA2A.Transport.GRPC.Codec.Proto,
      AshA2A.Transport.GRPC.Codec.WebText,
      AshA2A.Transport.GRPC.Codec.JSON
    ]

  alias AshA2A.A2ATransport
  alias AshA2A.A2ATransport.{PushConfigRPC, SSE, TaskEvents}
  alias AshA2A.Protocol
  alias AshA2A.Protocol.JSONRPC.Request
  alias AshA2A.Protocol.Telemetry
  alias AshA2A.Trace.W3C
  alias AshA2A.Transport.Grpc.Dispatch
  alias AshA2A.Transport.Follow
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
  # `StreamError` events on the downlink and never close the stream.
  #
  # A client half-close ends only the uplink: every request the client wrote
  # before it was already handed to the session, and the downlink keeps
  # delivering their frames. The RPC ends when the session closes — the bound
  # task turned terminal, the agent answered with a bare message, or (after
  # the half-close) nothing is in flight and nothing more can be owed, see
  # `AshA2A.Transport.Live.uplink_done/1`. A first request for a task that does
  # not exist or belongs to another caller ends the RPC NOT_FOUND
  # (TaskNotFoundError). A client that cancels the RPC takes the handler, the
  # reader and the session down with it; the task itself is not canceled.
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
           status: 9,
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

    # Linked, so a handler killed by a client cancel never leaves the reader
    # blocked on a dead request stream.
    reader =
      spawn_link(fn ->
        try do
          Enum.each(req_enum, fn req ->
            case to_params(req) do
              {:ok, params} ->
                case AshA2A.Transport.Live.uplink(session, Map.delete(params, "tenant")) do
                  {:error, :not_found} -> send(parent, {ref, :not_found})
                  _accepted_or_closed -> :ok
                end

              {:error, %GRPC.RPCError{message: message}} ->
                # An undecodable StreamRequest rejects that request only.
                send(parent, {ref, :rejected, message})

              {:error, _} ->
                :ok
            end
          end)
        catch
          _, _ -> :ok
        end

        send(parent, {ref, :half_closed})
      end)

    # A session that dies without its closing notice still ends the RPC.
    mon = Process.monitor(session)

    outcome =
      try do
        live_loop(mat, session, {ref, mon}, version)
      after
        Process.demonitor(mon, [:flush])
        Process.unlink(reader)
        Process.exit(reader, :kill)
        AshA2A.Transport.Live.close(session)
      end

    case outcome do
      :ok -> {:ok, mat, :noreply}
      {:error, %GRPC.RPCError{} = error} -> raise error
    end
  end

  defp live_loop(mat, session, {ref, mon} = refs, version) do
    receive do
      {:a2a_live, _sid, event} ->
        send_live_event(mat, event, version)
        live_loop(mat, session, refs, version)

      {:a2a_live_closed, _sid, _reason} ->
        :ok

      {:DOWN, ^mon, :process, _pid, _reason} ->
        :ok

      {^ref, :not_found} ->
        {:error, task_not_found()}

      {^ref, :rejected, message} ->
        error = AshA2A.Transport.Live.stream_error("INVALID_ARGUMENT", message, nil, nil)
        send_live_event(mat, error, version)
        live_loop(mat, session, refs, version)

      {^ref, :half_closed} ->
        # Client half-close: the uplink is complete, the downlink is not. The
        # session closes itself once the accepted work has answered.
        AshA2A.Transport.Live.uplink_done(session)
        live_loop(mat, session, refs, version)
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

  # Same explicit-version downgrade as stream_loop/1 and dispatch_unary/6: an
  # explicit <1.1 client never sees v1.1 fields on the live path.
  defp do_send_live_event(mat, event) do
    frame = to_pb!(Pb.StreamResponse, AshA2A.Transport.Live.encode(event))

    case Downgrade.strip(frame, wire_version(mat)) do
      :drop -> :ok
      stripped -> GRPC.Server.send_reply(mat, stripped)
    end
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

          {{:returned, result},
           not (match?({:error, _}, result) or match?({:err_run, _}, result))}
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
  # {:content_type_not_supported, _}) into typed A2A errors, stores an inline
  # push config and publishes the answered task; CancelTask goes through it to
  # publish the canceled task (push notifications).
  defp dispatch_call(method, params, call_ctx) when method in ["SendMessage", "CancelTask"] do
    real = handler!()

    Dispatch.call_detailed(
      method,
      params,
      __MODULE__.SendHandler,
      Map.put(call_ctx, :grpc_handler, real)
    )
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
      %{"message" => %{} = message} = p ->
        Map.put(p, "message", scrub_metadata_at(message, "metadata"))

      p ->
        p
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

  # Admit first (spec 3.1.2): the send is admitted with `return_immediately`,
  # so the agent answers with the stored task before its handler runs. The
  # stream opens with that Task (its id is usable at once for GetTask and
  # CancelTask) and then follows the task to a terminal or interrupted state,
  # one event per stored mutation (see `follow/5`). Every skill is streamable:
  # a handler that answers at once yields Task, its updates and the final
  # status; a task that parks at input-required ends the stream with that
  # status, it is not refused.
  defp start_message_stream(params, ctx, auth) do
    message = Map.fetch!(params, "message")
    agent = Map.fetch!(ctx, :agent)

    with :ok <- owned_continuation(agent, message, ctx),
         {:ok, push_config} <- inline_push(params, ctx),
         call_opts = params |> call_opts(message, ctx, auth) |> Follow.admit_opts(),
         {:ok, result} <- Protocol.call(agent, message, call_opts) do
      case result do
        %AshA2A.Protocol.Task{} = task ->
          attach_inline_push(task, push_config, ctx)
          wired = Follow.wire(task)
          {:ok, follow(agent, ctx, wired, [wired], :send, subscribed?: true)}

        %AshA2A.Protocol.Message{} = reply ->
          # Spec 3.1.2: a message-only stream is exactly one Message.
          {:ok, [{AshA2A.Transport.Live.encode(reply), 0}]}
      end
    else
      {:error, %GRPC.RPCError{} = error} -> {:error, error}
      {:error, %AshA2A.Protocol.JSONRPC.Error{} = error} -> {:error, typed_error(error)}
      {:error, reason} -> {:error, send_reason_error(reason)}
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
    |> put_opt(:if_generation_match, if_generation_match(configuration))
  end

  # v1.1 `configuration.ifGenerationMatch` (an int64: a number or its decimal
  # string in ProtoJSON).
  defp if_generation_match(%{"ifGenerationMatch" => n}) when is_integer(n) and n >= 0, do: n

  defp if_generation_match(%{"ifGenerationMatch" => s}) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n >= 0 -> n
      _ -> nil
    end
  end

  defp if_generation_match(_configuration), do: nil

  # A raw agent refusal as its typed A2A error (status + ErrorInfo, spec 10.6);
  # anything the table does not know is an opaque INTERNAL.
  defp send_reason_error(reason) do
    case Dispatch.reason_error(reason) do
      {:error, code, msg, details} ->
        rpc_error(code, msg, details)

      nil ->
        %{ref: ref} = AshA2A.Transport.SafeError.internal(:stream_start_failed, reason)
        GRPC.RPCError.exception(status: 13, message: "Internal error ref=#{ref}")
    end
  end

  defp typed_error(%AshA2A.Protocol.JSONRPC.Error{} = error) do
    {:error, code, msg, details} = Dispatch.error_to_grpc(error)
    rpc_error(code, msg, details)
  end

  defp task_not_found, do: typed_error(AshA2A.Protocol.JSONRPC.Error.task_not_found())

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
        {:error, task_not_found()}
    end
  end

  defp start_resubscribe_stream(params, ctx) do
    handler = handler!()
    task_id = Map.fetch!(params, "id")
    agent = Map.get(ctx, :agent)
    principal = Map.get(ctx, :principal, :anonymous)

    # The handler's GetTask is the authorization seam; the stored task (with
    # its timeline) is then read for the replay.
    with {:ok, _task_map} <- Dispatch.call_detailed("GetTask", %{"id" => task_id}, handler, ctx),
         {:ok, task} <- A2ATransport.Ownership.fetch_strict(agent, task_id, principal) do
      if AshA2A.Protocol.Task.terminal?(task) do
        # UnsupportedOperationError for an already-terminal task:
        # FAILED_PRECONDITION(9) per spec 5.4 (reason UNSUPPORTED_OPERATION).
        {:error,
         GRPC.RPCError.exception(
           status: 9,
           message: "This operation is not supported",
           details: [error_info("UNSUPPORTED_OPERATION", task_id)]
         )}
      else
        wired = Follow.wire(task)

        # v1.1 lastSeenGeneration: when set and the stored task can replay
        # from it, no snapshot is sent, only the events after that generation;
        # otherwise the stream opens with the snapshot (never an error).
        opening =
          case last_seen_generation(params) do
            nil -> [wired]
            seen -> replay_from(wired, seen)
          end

        {:ok, follow(agent, ctx, wired, opening, :subscribe, [])}
      end
    else
      {:error, code, msg, details} ->
        {:error, rpc_error(code, msg, details)}

      {:error, :unavailable} ->
        {:error, GRPC.RPCError.exception(status: 14, message: "agent unavailable")}

      {:error, _not_found} ->
        {:error, task_not_found()}
    end
  end

  # -- following a task -------------------------------------------------------

  # `{StreamResponse wrapper map, seq}` for `stream_loop/2`, over the shared
  # `AshA2A.Transport.Follow` event stream: `opening`, then one event per
  # stored mutation until the task is terminal (for `:send` also interrupted).
  # A quiet handler does not end the RPC; `ctx[:stream_max_idle_ms]` bounds
  # the silence when a host wants a bound. The task that ends the stream is
  # published (push notifications).
  defp follow(agent, ctx, %AshA2A.Protocol.Task{} = wired, opening, mode, opts) do
    publish_task(ctx, wired)

    opts =
      opts
      |> Keyword.merge(Follow.stream_opts(ctx))
      |> Keyword.put(:on_settled, fn task -> if task != wired, do: publish_task(ctx, task) end)

    agent
    |> Follow.events(wired, opening, mode, opts)
    |> Stream.map(&{AshA2A.Transport.Live.encode(&1), 0})
  end

  # lastSeenGeneration replay: the events after `seen`, or the snapshot when
  # the task cannot replay from there.
  defp replay_from(task, seen) do
    current = AshA2A.Protocol.Task.Generation.generation_of(task)

    cond do
      # Ahead of the task, or before it existed (generation starts at 1): there
      # is nothing to replay from, the client resynchronises on the snapshot.
      seen > current or seen < 1 ->
        [task]

      seen == current ->
        []

      true ->
        case AshA2A.Protocol.Task.Delta.events_after(task, seen) do
          [] -> [task]
          events -> Enum.map(events, &elem(&1, 1))
        end
    end
  end

  # -- push notifications -----------------------------------------------------

  # The task a send, a stream or a cancel answers is published to the shared
  # per-task event log, exactly as the HTTP bindings do: that publication is
  # what fires the registered push-notification webhooks. A no-op when the
  # transport is not running.
  @doc false
  def publish_task(ctx, %AshA2A.Protocol.Task{} = task) do
    transport = Map.get(ctx, :transport)

    if transport && A2ATransport.running?(transport) do
      final? =
        AshA2A.Protocol.Task.terminal?(task) or
          task.status.state in [:input_required, :auth_required]

      TaskEvents.publish(transport, task.id, "task", SSE.encode_task(task), final?)
    end

    :ok
  end

  # `configuration.taskPushNotificationConfig` (1.0: `pushNotificationConfig`)
  # is equivalent to CreateTaskPushNotificationConfig (spec 3.2.2): admitted
  # before any work starts, stored once the task exists.
  @doc false
  def inline_push(params, ctx) do
    configuration = if is_map(params["configuration"]), do: params["configuration"], else: %{}
    transport = Map.get(ctx, :transport)

    case configuration["taskPushNotificationConfig"] || configuration["pushNotificationConfig"] do
      %{} = config when map_size(config) > 0 ->
        if transport && A2ATransport.running?(transport) do
          with :ok <- PushConfigRPC.preflight(config, TaskEvents.push_opts(transport)),
               do: {:ok, config}
        else
          {:error, AshA2A.Protocol.JSONRPC.Error.push_notification_not_supported()}
        end

      _none ->
        {:ok, nil}
    end
  end

  @doc false
  def attach_inline_push(_task, nil, _ctx), do: :ok

  def attach_inline_push(task, config, ctx) do
    transport = Map.fetch!(ctx, :transport)

    _ =
      PushConfigRPC.attach_inline(task.id, config, %{
        agent: Map.get(ctx, :agent),
        transport: transport,
        push_opts: TaskEvents.push_opts(transport),
        principal: Map.get(ctx, :principal, :anonymous),
        wire: :v1,
        a2a_version: Map.get(ctx, :a2a_version)
      })

    :ok
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
    AshA2A.Transport.GRPC.UnknownMethod.ensure_installed(Map.get(mat, :endpoint))

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
  # FAILED_PRECONDITION(9) per spec 5.4, and
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
                status: 9,
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
        # Activation failure: status from the error's A2A code (-32008 ->
        # FAILED_PRECONDITION(9)), with its spec ErrorInfo when the code has
        # one, else a generic EXTENSION_ACTIVATION_FAILED ErrorInfo.
        {:error, status, message, details} = AshA2A.Transport.Grpc.Dispatch.error_to_grpc(err)

        details =
          if details == [],
            do: [error_info("EXTENSION_ACTIVATION_FAILED", message)],
            else: details

        raise GRPC.RPCError.exception(status: status, message: message, details: details)
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

  # Bytes that are not the RPC's request message (see
  # `AshA2A.Transport.GRPC.Codec`): the caller's error, INVALID_ARGUMENT.
  defp to_params(%AshA2A.Transport.GRPC.Codec.Undecodable{module: module}) do
    detail = "the request is not a valid #{inspect(module.full_name())} message"

    {:error,
     GRPC.RPCError.exception(
       status: 3,
       message: "Invalid parameters",
       details: [error_info("INVALID_PARAMS", detail)]
     )}
  end

  defp to_params(req) do
    {:ok,
     req
     |> Protobuf.JSON.encode!()
     |> Jason.decode!()
     |> integral_numbers()
     |> normalize_params(req)}
  rescue
    e ->
      {:error,
       GRPC.RPCError.exception(status: 3, message: "bad request: #{Exception.message(e)}")}
  end

  # A `google.protobuf.Struct` number is always a double, so a client's `300`
  # reaches this bridge as `300.0`, and an Ash `:integer` argument refuses it.
  # JSON has one number type: a whole-number double is read as the integer the
  # HTTP bindings decode for the same message. Fractions are left alone.
  @max_safe_integer 9_007_199_254_740_992

  defp integral_numbers(%{} = map), do: Map.new(map, fn {k, v} -> {k, integral_numbers(v)} end)
  defp integral_numbers(list) when is_list(list), do: Enum.map(list, &integral_numbers/1)

  defp integral_numbers(number)
       when is_float(number) and number == trunc(number) and
              abs(number) < @max_safe_integer,
       do: trunc(number)

  defp integral_numbers(other), do: other

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

  alias AshA2A.Transport.GRPC.Server
  alias AshA2A.Transport.Grpc.Dispatch

  @impl true
  def handle_send(message, params, ctx) do
    with {:ok, push_config} <- Server.inline_push(params, ctx) do
      case ctx.grpc_handler.handle_send(message, params, ctx) do
        {:ok, %AshA2A.Protocol.Task{} = task} = ok ->
          Server.attach_inline_push(task, push_config, ctx)
          Server.publish_task(ctx, task)

          # A task answered while still running (`returnImmediately`) is
          # followed, so its push configs hear how it ends, as on the HTTP
          # bindings.
          AshA2A.A2ATransport.DetachedWatch.start(
            Map.get(ctx, :agent),
            Map.get(ctx, :transport),
            task
          )

          ok

        {:error, reason} = error ->
          case Dispatch.reason_to_error(reason) do
            nil -> error
            typed -> {:error, typed}
          end

        other ->
          other
      end
    end
  end

  @impl true
  def handle_get(task_id, params, ctx), do: ctx.grpc_handler.handle_get(task_id, params, ctx)

  @impl true
  def handle_cancel(task_id, params, ctx) do
    case ctx.grpc_handler.handle_cancel(task_id, params, ctx) do
      {:ok, %AshA2A.Protocol.Task{} = task} = ok ->
        Server.publish_task(ctx, task)
        ok

      other ->
        other
    end
  end
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
