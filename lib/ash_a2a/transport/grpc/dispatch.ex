defmodule AshA2A.Transport.Grpc.Dispatch do
  @moduledoc """
  Method mapping from the A2A v1.0 proto service (`a2a.A2AService`, the
  normative `a2aproject/A2A` proto) onto the SAME internal handlers the
  HTTP/JSON binding uses — read-only consumption of
  `AshA2A.Protocol.JSONRPC.handle/3`, the transport-agnostic JSON-RPC
  dispatcher. No protocol logic lives here: this module translates
  proto-RPC names and gRPC statuses around the dispatcher.

  **Scope: PARTIAL.** The server socket transport (HTTP/2, TLS, trailers
  over the wire) requires a gRPC server dependency and is UNSUPPORTED
  here. What IS provided is the full dispatch layer a host's gRPC server
  calls:

      {:ok, proto_json_result} =
        Dispatch.call("a2a.A2AService/SendMessage", params, handler, ctx)

      {:error, 5, "Task not found"} =
        Dispatch.call("GetTask", %{"id" => "missing"}, handler, ctx)

    * `call/4` accepts the full gRPC path (`"/a2a.A2AService/SendMessage"`,
      `"a2a.A2AService/SendMessage"`) or the bare RPC name (`"SendMessage"`),
      and returns `{:ok, reply}` | `{:error, grpc_status, message}` |
      `{:stream, method, params, id}`.
    * Proto-JSON member mapping (lowerCamelCase: `taskId`, `contextId`,
      `historyLength`) is the existing codec's wire shape
      (`AshA2A.Protocol.JSON`), so params pass through unchanged — the same
      maps the HTTP binding receives.
    * `{:stream, method, params, id}` is returned for the two
      server-streaming RPCs (`SendStreamingMessage`, `SubscribeToTask`):
      the host's gRPC server drives the stream, framing each
      StreamResponse wrapper (`AshA2A.Protocol.JSON.encode_stream_response/1`)
      with `AshA2A.Transport.Grpc.Framing.encode_frame/2`. The JSON-RPC
      dispatcher has already decoded and validated the message by the time
      this tuple is returned.
    * A2A JSON-RPC error codes are mapped to gRPC statuses per v1.0 §3.3.2:
      -32001 -> NOT_FOUND(5), -32600/-32602/-32700/-32005 ->
      INVALID_ARGUMENT(3), -32002/-32007/-32008 -> FAILED_PRECONDITION(9),
      -32601/-32003/-32004/-32009 -> UNIMPLEMENTED(12), -32603/-32006 ->
      INTERNAL(13), -32000 (server busy) -> UNAVAILABLE(14). `trailers/1`
      converts a result to the `grpc-status`/`grpc-message` trailer map.

  `handler` is any module implementing the `AshA2A.Protocol.JSONRPC`
  behaviour (e.g. `AshA2A.Transport.Plug`) and `ctx` is the context map
  that handler requires — exactly what the HTTP binding passes.
  """

  @service "a2a.A2AService"

  @methods [
    %{name: "SendMessage", internal: "message/send", streaming: false},
    %{name: "SendStreamingMessage", internal: "message/stream", streaming: true},
    %{name: "GetTask", internal: "tasks/get", streaming: false},
    %{name: "CancelTask", internal: "tasks/cancel", streaming: false},
    %{name: "ListTasks", internal: "tasks/list", streaming: false},
    %{name: "SubscribeToTask", internal: "tasks/resubscribe", streaming: true},
    %{name: "CreateTaskPushNotificationConfig", internal: "tasks/pushNotificationConfig/set", streaming: false},
    %{name: "GetTaskPushNotificationConfig", internal: "tasks/pushNotificationConfig/get", streaming: false},
    %{name: "ListTaskPushNotificationConfigs", internal: "tasks/pushNotificationConfig/list", streaming: false},
    %{name: "DeleteTaskPushNotificationConfig", internal: "tasks/pushNotificationConfig/delete", streaming: false},
    %{name: "GetExtendedAgentCard", internal: "agent/getAuthenticatedExtendedCard", streaming: false}
  ]

  @doc false
  def service, do: @service

  def methods, do: @methods

  def call(rpc, params, handler, ctx \\ %{}) when is_binary(rpc) and is_map(params) do
    case call_detailed(rpc, params, handler, ctx) do
      {:error, status, message, _details} -> {:error, status, message}
      other -> other
    end
  end

  @doc """
  Same dispatch as `call/4`, with the A2A error's spec §5.4
  `google.rpc.ErrorInfo` (packed as a `google.protobuf.Any`) appended as a
  fourth element on `{:error, status, message, details}` — the detail list
  GRPC.RPCError's `:details` carries into the `grpc-status-details-bin`
  trailer. `details` is `[]` for errors with no spec ErrorInfo (the standard
  JSON-RPC codes).
  """
  def call_detailed(rpc, params, handler, ctx \\ %{}) when is_binary(rpc) and is_map(params) do
    short = short_name(rpc)

    case Enum.find(@methods, &(&1.name == short)) do
      nil ->
        # UNIMPLEMENTED — must be a literal here: the @grpc_* attributes are
        # defined below, and anti-drift with error.ex's @error_info_reasons
        # table is by-construction: the reason is read out of the error map's
        # stamped ErrorInfo, not re-tabled here.
        {:error, 12, "Method not found: #{rpc}", []}

      _method ->
        request = %{
          "jsonrpc" => "2.0",
          "id" => AshA2A.Protocol.ID.generate("grpc"),
          "method" => short,
          "params" => params
        }

        case AshA2A.Protocol.JSONRPC.handle(request, handler, ctx) do
          {:reply, %{"result" => result}} -> {:ok, result}
          {:reply, %{"error" => error}} -> error_tuple(error)
          {:stream, m, p, id} -> {:stream, m, p, id}
        end
    end
  end

  # gRPC status codes (google.golang.org/grpc/codes / grpc::StatusCode).
  @grpc_ok 0
  @grpc_invalid_argument 3
  @grpc_unknown 2
  @grpc_not_found 5
  @grpc_failed_precondition 9
  @grpc_unimplemented 12
  @grpc_internal 13
  @grpc_unavailable 14

  # A2A v1.0 §3.3.2 cross-binding error mapping: JSON-RPC error code ->
  # gRPC status code. Validation (parse/request/params) is INVALID_ARGUMENT,
  # method-level absence is UNIMPLEMENTED, resource absence is NOT_FOUND,
  # state conflicts are FAILED_PRECONDITION, A2A server errors are
  # UNAVAILABLE (-32000 server busy) or INTERNAL (-32006 invalid agent
  # response), and unimplemented features (-32003/-32004/-32009) are
  # UNIMPLEMENTED.
  @grpc_from_jsonrpc %{
    -32_700 => @grpc_invalid_argument,
    -32_600 => @grpc_invalid_argument,
    -32_601 => @grpc_unimplemented,
    -32_602 => @grpc_invalid_argument,
    -32_603 => @grpc_internal,
    -32_000 => @grpc_unavailable,
    -32_001 => @grpc_not_found,
    -32_002 => @grpc_failed_precondition,
    -32_003 => @grpc_unimplemented,
    -32_004 => @grpc_unimplemented,
    -32_005 => @grpc_invalid_argument,
    -32_006 => @grpc_internal,
    -32_007 => @grpc_failed_precondition,
    -32_008 => @grpc_failed_precondition,
    -32_009 => @grpc_unimplemented
  }

  @grpc_status_names %{
    0 => "OK",
    1 => "CANCELED",
    2 => "UNKNOWN",
    3 => "INVALID_ARGUMENT",
    4 => "DEADLINE_EXCEEDED",
    5 => "NOT_FOUND",
    6 => "ALREADY_EXISTS",
    7 => "PERMISSION_DENIED",
    8 => "RESOURCE_EXHAUSTED",
    9 => "FAILED_PRECONDITION",
    10 => "ABORTED",
    11 => "OUT_OF_RANGE",
    12 => "UNIMPLEMENTED",
    13 => "INTERNAL",
    14 => "UNAVAILABLE",
    15 => "DATA_LOSS",
    16 => "UNAUTHENTICATED"
  }

  @doc "gRPC status name for a status code, e.g. `status_name(5) == \"NOT_FOUND\"`."
  def status_name(code) when is_integer(code), do: Map.get(@grpc_status_names, code, "UNKNOWN")

  @doc """
  The gRPC trailer map for a dispatch result: `{:ok, _}` maps to
  `grpc-status: 0`; `{:error, status, message}` to the status and message.
  """
  def trailers({:ok, _}), do: %{"grpc-status" => @grpc_ok}
  def trailers({:error, status, message}), do: %{"grpc-status" => status, "grpc-message" => message}

  defp error_tuple(%{"code" => code, "message" => message} = error) when is_integer(code) do
    {:error, Map.get(@grpc_from_jsonrpc, code, @grpc_unknown), message, error_info_details(error)}
  end

  # Spec §5.4: an A2A error's JSON-RPC map already carries its stamped
  # google.rpc.ErrorInfo in `data` (AshA2A.Protocol.JSONRPC.Error.to_map/1 is
  # the single stamping point — no reason table is duplicated here). Unpack it
  # into the packed Any GRPC.RPCError carries into grpc-status-details-bin.
  defp error_info_details(%{
         "data" => [%{"@type" => type, "reason" => reason, "domain" => domain} = info]
       })
       when is_binary(type) and is_binary(reason) and is_binary(domain) and
              binary_part(type, byte_size(type) - 9, 9) == "ErrorInfo" do
    [
      %Google.Protobuf.Any{
        type_url: "type.googleapis.com/google.rpc.ErrorInfo",
        value:
          Google.Rpc.ErrorInfo.encode(%Google.Rpc.ErrorInfo{
            reason: reason,
            domain: domain,
            metadata: Map.new(info["metadata"] || %{}, fn {k, v} -> {k, to_string(v)} end)
          })
      }
    ]
  end

  defp error_info_details(_), do: []

  defp short_name(rpc) do
    rpc
    |> String.split("/")
    |> List.last()
  end
end
