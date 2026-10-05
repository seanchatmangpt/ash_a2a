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
  alias AshA2A.Transport.Grpc.Dispatch
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
  # dispatch's error mapping turns into UNIMPLEMENTED(12) before a response
  # type is ever needed; the Empty target exists for hosts whose handler
  # implements the optional push callbacks.
  def delete_task_push_notification_config(req, mat) do
    unary("DeleteTaskPushNotificationConfig", req, mat, Google.Protobuf.Empty)
  end

  # -- server-streaming RPCs ------------------------------------------------

  def send_streaming_message(req, mat) do
    gate_version!(mat)

    case start_stream("SendStreamingMessage", req) do
      {:ok, events} ->
        # stages: 1 — the Flow partition is the single subscriber of the
        # task's event log; more than one partition would subscribe the same
        # Stream.resource more than once.
        events
        |> GRPC.Stream.from(stages: 1)
        |> GRPC.Stream.map(fn {payload, _seq} -> to_pb!(Pb.StreamResponse, payload) end)
        |> GRPC.Stream.run_with(mat)

      {:error, %GRPC.RPCError{} = error} ->
        raise error
    end
  end

  def subscribe_to_task(req, mat) do
    gate_version!(mat)

    case start_stream("SubscribeToTask", req) do
      {:ok, events} ->
        # Emitted events carry no per-event status; the RPC ends OK when the
        # final event has been sent, exactly like the SSE side.
        events
        |> GRPC.Stream.from(stages: 1)
        |> GRPC.Stream.map(fn {payload, _seq} -> to_pb!(Pb.StreamResponse, payload) end)
        |> GRPC.Stream.run_with(mat)

      {:error, %GRPC.RPCError{} = error} ->
        raise error
    end
  end

  # -- bridging -------------------------------------------------------------

  defp unary(method, req, mat, resp_mod) do
    gate_version!(mat)

    req
    |> GRPC.Stream.unary(materializer: mat)
    |> GRPC.Stream.map(fn _ -> dispatch_unary(method, req, resp_mod) end)
    |> GRPC.Stream.run()
  end

  defp dispatch_unary(method, req, resp_mod) do
    with {:ok, params} <- to_params(req),
         {:ok, result} <- Dispatch.call_detailed(method, params, handler!(), ctx()) do
      to_pb!(resp_mod, result)
    else
      {:error, code, msg, details} -> {:error, rpc_error(code, msg, details)}
    end
  end

  defp start_stream("SendStreamingMessage", req) do
    with {:ok, params} <- to_params(req),
         {:stream, "message/stream", params, _id} <-
           Dispatch.call_detailed("SendStreamingMessage", params, handler!(), ctx()) do
      start_message_stream(params)
    else
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

  defp start_stream("SubscribeToTask", req) do
    with {:ok, params} <- to_params(req),
         {:stream, "tasks/resubscribe", params, _id} <-
           Dispatch.call_detailed("SubscribeToTask", params, handler!(), ctx()) do
      start_resubscribe_stream(params)
    else
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

  defp start_message_stream(params) do
    ctx = ctx()
    message = Map.fetch!(params, "message")
    agent = Map.fetch!(ctx, :agent)
    call_opts = Map.get(ctx, :opts, [])
    transport = Map.get(ctx, :transport, A2ATransport.default_name())

    with {:ok, task, enum} <- Protocol.stream(agent, message, call_opts) do
      {:ok, stream_enum(transport, task.id, fn ->
        backlog = TaskEvents.subscribe(transport, task.id)
        _seq = TaskEvents.publish(transport, task.id, "task", SSE.encode_task(task))
        start_pump(transport, agent, task, enum)
        backlog
      end)}
    else
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

  defp start_resubscribe_stream(params) do
    ctx = ctx()
    handler = handler!()
    task_id = Map.fetch!(params, "id")
    transport = Map.get(ctx, :transport, A2ATransport.default_name())

    with {:ok, task_map} <- Dispatch.call_detailed("GetTask", %{"id" => task_id}, handler, ctx),
         {:ok, task} <- AshA2A.Protocol.JSON.decode(task_map, :task) do
      if AshA2A.Protocol.Task.terminal?(task) do
        # The proto's UnsupportedOperationError for an already-terminal task:
        # A2A v1.0 §5.4 binds UnsupportedOperationError (-32004) to
        # UNIMPLEMENTED(12) — the dispatch table's existing -32004 edge
        # (cross-checked against the TCK's ERROR_BINDINGS: reason
        # UNSUPPORTED_OPERATION, grpc_status UNIMPLEMENTED) — NOT
        # FAILED_PRECONDITION(9), which is TaskNotCancelableError's (-32002)
        # status. TCK STREAM-SUB-003.
        {:error,
         GRPC.RPCError.exception(
           status: 12,
           message: "This operation is not supported",
           details: [version_error_info("UNSUPPORTED_OPERATION", task_id)]
         )}
      else
        {:ok,
         stream_enum(transport, task_id, fn -> TaskEvents.subscribe(transport, task_id) end)}
      end
    else
      {:error, code, msg, details} -> {:error, rpc_error(code, msg, details)}
    end
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
  def stream_enum(transport, task_id, subscribe_fun) do
    Stream.resource(

      fn ->
        subscribe_fun.()
        |> Enum.reject(fn {_seq, kind, _payload, _final?} -> kind == "task" end)
        |> Enum.map(fn {seq, _kind, payload, final?} -> {seq, {payload, final?}} end)
        |> then(&{&1, 0})
      end,
      fn
        {:done, _last} ->
          {:halt, {:done, 0}}

        {queue, last} ->
          case next_event(queue, last, transport, task_id) do
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

  defp next_event([], last, _transport, task_id) do
    receive do
      {:a2a_task_event, ^task_id, seq, _kind, payload, final?} when seq > last ->
        {:ok, {seq, {payload, final?}}, []}
    after
      60_000 -> :idle
    end
  end

  # Backlog events interleave with already-delivered live events: a live
  # event whose seq falls before the backlog head is emitted first, a
  # duplicate of a backlog event is dropped (the backlog copy wins).
  defp next_event([{seq, event} | rest], last, _transport, task_id) do
    receive do
      {:a2a_task_event, ^task_id, s, _kind, payload, final?} when s > last and s < seq ->
        {:ok, {s, {payload, final?}}, [{seq, event} | rest]}
    after
      0 -> {:ok, {seq, event}, rest}
    end
  end

  # -- config ---------------------------------------------------------------

  # A2A-Version gate (spec §3.6.2), mirroring the landed HTTP-binding gate in
  # AshA2A.Transport.Plug.handle_json_rpc/1 (plug.ex lines ~208-243): parse
  # + validate against the shared supported list; the refused version is
  # VersionNotSupportedError (-32009). On gRPC that code maps to
  # UNIMPLEMENTED(12) per the dispatch's cross-binding table (spec §5.4), and
  # the error carries the spec's google.rpc.ErrorInfo (reason
  # VERSION_NOT_SUPPORTED, domain a2a-protocol.org) in the
  # grpc-status-details-bin trailer — the same ErrorInfo the codec stamps on
  # -32009 in AshA2A.Protocol.JSONRPC.Error (@error_info_reasons). An absent
  # or empty header is tolerated as the "0.3" default (§3.6.2), exactly like
  # the HTTP gate.
  defp gate_version!(mat) do
    version = AshA2A.Protocol.Version.parse_header(request_version(mat))

    case AshA2A.Protocol.Version.validate(version, AshA2A.Protocol.Version.supported_default()) do
      :ok ->
        :ok

      {:error, rejected} ->
        raise GRPC.RPCError.exception(
                status: 12,
                message: "Version not supported",
                details: [version_error_info("VERSION_NOT_SUPPORTED", rejected)]
              )
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
  defp version_error_info(reason, detail) do
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
    {:ok, req |> Protobuf.JSON.encode!() |> Jason.decode!()}
  rescue
    e -> {:error, GRPC.RPCError.exception(status: 3, message: "bad request: #{Exception.message(e)}")}
  end

  defp to_pb!(resp_mod, result_map) do
    result_map |> Jason.encode!() |> Protobuf.JSON.decode!(resp_mod)
  end
end

defmodule AshA2A.Transport.GRPC.Server.Endpoint do
  @moduledoc """
  Default `GRPC.Endpoint` hosting `AshA2A.Transport.GRPC.Server`
  (service `lf.a2a.v1.A2AService`). Hosts may instead declare their own
  endpoint with `run AshA2A.Transport.GRPC.Server` to add interceptors.
  """

  use GRPC.Endpoint

  run AshA2A.Transport.GRPC.Server
end
