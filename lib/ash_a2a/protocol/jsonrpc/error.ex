defmodule AshA2A.Protocol.JSONRPC.Error do
  @moduledoc """
  JSON-RPC 2.0 error with A2A-specific error codes.

  Provides a struct and named constructors for the 14 error codes defined by
  the A2A protocol (5 standard JSON-RPC + 9 A2A-specific).

  A2A-specific errors (-32001..-32009) serialize with a `google.rpc.ErrorInfo`
  object inside a `"data"` array, as the spec requires. Invalid params
  (-32602) also carries an `ErrorInfo` (reason `INVALID_PARAMS`); the other 4
  standard JSON-RPC codes have no defined `reason` and keep free-form `data`
  (-32603 internal stays ref-only/redacted — see `AshA2A.ToA2AError`).

  ## Example

      iex> error = AshA2A.Protocol.JSONRPC.Error.task_not_found()
      iex> error.code
      -32001
      iex> AshA2A.Protocol.JSONRPC.Error.to_map(error)
      %{
        "code" => -32001,
        "message" => "Task not found",
        "data" => [
          %{
            "@type" => "type.googleapis.com/google.rpc.ErrorInfo",
            "domain" => "a2a-protocol.org",
            "reason" => "TASK_NOT_FOUND"
          }
        ]
      }
  """

  @type t :: %__MODULE__{
          code: integer(),
          message: String.t(),
          data: term()
        }

  @enforce_keys [:code, :message]
  defstruct [:code, :message, :data]

  @error_info_type "type.googleapis.com/google.rpc.ErrorInfo"
  @a2a_domain "a2a-protocol.org"

  # Reason strings are keyed by code, not by constructor name: -32007's reason
  # is EXTENDED_AGENT_CARD_NOT_CONFIGURED while its constructor is
  # authenticated_extended_card_not_configured/1. -32001 additionally serves
  # two failure classes (task-not-found AND policy denial, distinguished by
  # the ErrorInfo reason on the wire — see `AshA2A.ToA2AError`); the table
  # only supplies the default stamp for unwrapped data.
  @error_info_reasons %{
    -32_001 => "TASK_NOT_FOUND",
    -32_002 => "TASK_NOT_CANCELABLE",
    -32_003 => "PUSH_NOTIFICATION_NOT_SUPPORTED",
    -32_004 => "UNSUPPORTED_OPERATION",
    -32_005 => "CONTENT_TYPE_NOT_SUPPORTED",
    -32_006 => "INVALID_AGENT_RESPONSE",
    -32_007 => "EXTENDED_AGENT_CARD_NOT_CONFIGURED",
    -32_008 => "EXTENSION_SUPPORT_REQUIRED",
    -32_009 => "VERSION_NOT_SUPPORTED",
    -32_010 => "TASK_GENERATION_MISMATCH",
    # -32602 is a standard JSON-RPC code with no spec-defined reason; the
    # ErrorInfo (domain a2a-protocol.org, reason INVALID_PARAMS) is added by
    # lane V3 so validation/changeset failures carry a typed reason too.
    -32_602 => "INVALID_PARAMS",
    # Spec 9.5: `error.data` is an array of objects that each carry `@type`.
    # Free-form data on the remaining standard codes rides the ErrorInfo's
    # `metadata.detail` instead of replacing the array.
    -32_700 => "JSON_PARSE",
    -32_600 => "INVALID_REQUEST",
    -32_601 => "METHOD_NOT_FOUND"
  }

  @doc "Builds a parse error (-32700)."
  @spec parse_error(term()) :: t()
  def parse_error(data \\ nil) do
    %__MODULE__{code: -32_700, message: "Invalid JSON payload", data: data}
  end

  @doc "Builds an invalid request error (-32600)."
  @spec invalid_request(term()) :: t()
  def invalid_request(data \\ nil) do
    %__MODULE__{
      code: -32_600,
      message: "Request payload validation error",
      data: data
    }
  end

  @doc "Builds a method not found error (-32601)."
  @spec method_not_found(term()) :: t()
  def method_not_found(data \\ nil) do
    %__MODULE__{code: -32_601, message: "Method not found", data: data}
  end

  @doc "Builds an invalid params error (-32602)."
  @spec invalid_params(term()) :: t()
  def invalid_params(data \\ nil) do
    %__MODULE__{code: -32_602, message: "Invalid parameters", data: data}
  end

  @doc "Builds an internal error (-32603)."
  @spec internal_error(term()) :: t()
  def internal_error(data \\ nil) do
    %__MODULE__{code: -32_603, message: "Internal error", data: data}
  end

  @doc """
  Builds a task not found error (-32001).

  Option `:task_id` adds `taskId` to the ErrorInfo metadata.

  NOTE: -32001 is deliberately shared with policy denial
  (`POLICY_FORBIDDEN`, see `AshA2A.ToA2AError`) so a denied caller cannot
  distinguish "forbidden" from "absent" by code (no existence leak). Do not
  split it.
  """
  @spec task_not_found(term(), keyword()) :: t()
  def task_not_found(data \\ nil, opts \\ []) do
    %__MODULE__{
      code: -32_001,
      message: "Task not found",
      data: enrich(-32_001, data, task_meta(opts), [])
    }
  end

  @doc "Builds a task not cancelable error (-32002). Option `:task_id` adds `taskId` metadata."
  @spec task_not_cancelable(term(), keyword()) :: t()
  def task_not_cancelable(data \\ nil, opts \\ []) do
    %__MODULE__{
      code: -32_002,
      message: "Task cannot be canceled",
      data: enrich(-32_002, data, task_meta(opts), [])
    }
  end

  @doc "Builds a push notification not supported error (-32003)."
  @spec push_notification_not_supported(term()) :: t()
  def push_notification_not_supported(data \\ nil) do
    %__MODULE__{
      code: -32_003,
      message: "Push Notification is not supported",
      data: data
    }
  end

  @doc "Builds an unsupported operation error (-32004)."
  @spec unsupported_operation(term()) :: t()
  def unsupported_operation(data \\ nil) do
    %__MODULE__{
      code: -32_004,
      message: "This operation is not supported",
      data: data
    }
  end

  @doc "Builds a content type not supported error (-32005)."
  @spec content_type_not_supported(term()) :: t()
  def content_type_not_supported(data \\ nil) do
    %__MODULE__{
      code: -32_005,
      message: "Incompatible content types",
      data: data
    }
  end

  @doc "Builds an invalid agent response error (-32006)."
  @spec invalid_agent_response(term()) :: t()
  def invalid_agent_response(data \\ nil) do
    %__MODULE__{
      code: -32_006,
      message: "Invalid agent response",
      data: data
    }
  end

  @doc "Builds an authenticated extended card not configured error (-32007)."
  @spec authenticated_extended_card_not_configured(term()) :: t()
  def authenticated_extended_card_not_configured(data \\ nil) do
    %__MODULE__{
      code: -32_007,
      message: "Authenticated Extended Card is not configured",
      data: data
    }
  end

  @doc "Builds an extension support required error (-32008)."
  @spec extension_support_required(term()) :: t()
  def extension_support_required(data \\ nil) do
    %__MODULE__{
      code: -32_008,
      message: "Extension support is required",
      data: data
    }
  end

  @doc """
  Builds a version not supported error (-32009).

  Option `:supported_versions` (list of strings) adds `supportedVersions`
  (comma-joined) to the ErrorInfo metadata.
  """
  @spec version_not_supported(term(), keyword()) :: t()
  def version_not_supported(data \\ nil, opts \\ []) do
    meta =
      case Keyword.get(opts, :supported_versions) do
        versions when is_list(versions) and versions != [] ->
          %{"supportedVersions" => Enum.map_join(versions, ",", &to_string/1)}

        _ ->
          %{}
      end

    %__MODULE__{
      code: -32_009,
      message: "Version not supported",
      data: enrich(-32_009, data, meta, [])
    }
  end

  @doc """
  Builds a task generation mismatch error (-32010, HTTP 409, gRPC ABORTED).

  Option `:task_id` adds `taskId`; `:expected` / `:actual` add
  `expectedGeneration` / `actualGeneration` (stringified) to the ErrorInfo
  metadata.
  """
  @spec task_generation_mismatch(term(), keyword()) :: t()
  def task_generation_mismatch(data \\ nil, opts \\ []) do
    meta =
      Enum.reduce(
        [{:expected, "expectedGeneration"}, {:actual, "actualGeneration"}],
        task_meta(opts),
        fn {key, name}, acc ->
          case Keyword.get(opts, key) do
            nil -> acc
            value -> Map.put(acc, name, to_string(value))
          end
        end
      )

    %__MODULE__{
      code: -32_010,
      message: "Task generation mismatch",
      data: enrich(-32_010, data, meta, [])
    }
  end

  @doc """
  Builds an unauthenticated error. Additive: code stays -32600 (current
  caller compatibility); the ErrorInfo reason is `UNAUTHENTICATED`
  (google.rpc status `UNAUTHENTICATED`, see `status_name_for_reason/1`).
  """
  @spec unauthenticated(term()) :: t()
  def unauthenticated(data) do
    %__MODULE__{
      code: -32_600,
      message: "Unauthenticated",
      data: [build_error_info("UNAUTHENTICATED", detail_meta(data))]
    }
  end

  @doc """
  Builds a permission denied error. Additive: code stays -32600; ErrorInfo
  reason `PERMISSION_DENIED` (google.rpc status `PERMISSION_DENIED`).
  """
  @spec permission_denied(term()) :: t()
  def permission_denied(data) do
    %__MODULE__{
      code: -32_600,
      message: "Permission denied",
      data: [build_error_info("PERMISSION_DENIED", detail_meta(data))]
    }
  end

  @doc """
  Builds a server-busy error (-32000, transport HTTP 503). `kind` is
  `:unavailable` (reason `UNAVAILABLE`) or `:resource_exhausted` (reason
  `RESOURCE_EXHAUSTED`).
  """
  @spec server_busy(term(), :unavailable | :resource_exhausted) :: t()
  def server_busy(data, kind) when kind in [:unavailable, :resource_exhausted] do
    reason = if kind == :unavailable, do: "UNAVAILABLE", else: "RESOURCE_EXHAUSTED"

    %__MODULE__{
      code: -32_000,
      message: "Server busy",
      data: [build_error_info(reason, detail_meta(data))]
    }
  end

  @doc """
  Builds an invalid params error (-32602) carrying, besides the ErrorInfo, a
  `google.rpc.BadRequest` detail with one field violation per
  `{field, description}` pair. Additive; `invalid_params/1` is unchanged.
  """
  @spec invalid_params_with_violations(term(), [{String.t() | atom(), String.t()}]) :: t()
  def invalid_params_with_violations(data, violations) when is_list(violations) do
    %__MODULE__{
      code: -32_602,
      message: "Invalid parameters",
      data: enrich(-32_602, data, %{}, [bad_request(violations)])
    }
  end

  @doc "Builds a `google.rpc.BadRequest` detail map from `{field, description}` pairs."
  @spec bad_request([{String.t() | atom(), String.t()}]) :: map()
  def bad_request(violations) do
    %{
      "@type" => "type.googleapis.com/google.rpc.BadRequest",
      "fieldViolations" =>
        Enum.map(violations, fn {field, description} ->
          %{"field" => to_string(field), "description" => to_string(description)}
        end)
    }
  end

  @doc """
  Builds one `google.rpc.ErrorInfo` map (domain `a2a-protocol.org`) with
  optional string-valued metadata.
  """
  @spec build_error_info(String.t(), map()) :: map()
  def build_error_info(reason, metadata \\ %{}) when is_binary(reason) do
    base = %{"@type" => @error_info_type, "domain" => @a2a_domain, "reason" => reason}
    if metadata == %{}, do: base, else: Map.put(base, "metadata", metadata)
  end

  # --- Binding table (A2A section 5.4) ---------------------------------------
  #
  # THE one mapping of an error code to each binding's representation: HTTP
  # status, gRPC status (numeric and google.rpc name). Every transport derives
  # its own table from `bindings/1` at compile time
  # (`AshA2A.Transport.HTTPJSON.status_for/1`, `AshA2A.Transport.Grpc.Dispatch`),
  # and the public helpers below read the same rows.
  #
  # The A2A rows (-32001..-32010) are section 5.4 of the specification. The
  # table is the same text at tags v1.0.1 and v1.1.0-rc (v1.1 only adds
  # TaskGenerationMismatchError), so no row depends on the negotiated version.
  # Earlier releases followed pins recorded from the TCK instead for three
  # HTTP rows (-32002 409, -32005 415, -32006 502) and three gRPC rows
  # (-32003/-32004/-32009 UNIMPLEMENTED); the specification text wins.
  # The standard JSON-RPC rows and -32000 (server busy) are this library's.

  @bindings %{
    -32_001 => {404, 5, "NOT_FOUND"},
    -32_002 => {400, 9, "FAILED_PRECONDITION"},
    -32_003 => {400, 9, "FAILED_PRECONDITION"},
    -32_004 => {400, 9, "FAILED_PRECONDITION"},
    -32_005 => {400, 3, "INVALID_ARGUMENT"},
    -32_006 => {500, 13, "INTERNAL"},
    -32_007 => {400, 9, "FAILED_PRECONDITION"},
    -32_008 => {400, 9, "FAILED_PRECONDITION"},
    -32_009 => {400, 9, "FAILED_PRECONDITION"},
    -32_010 => {409, 10, "ABORTED"},
    -32_700 => {400, 3, "INVALID_ARGUMENT"},
    -32_600 => {400, 3, "INVALID_ARGUMENT"},
    -32_601 => {400, 12, "UNIMPLEMENTED"},
    -32_602 => {400, 3, "INVALID_ARGUMENT"},
    -32_603 => {500, 13, "INTERNAL"},
    -32_000 => {503, 14, "UNAVAILABLE"}
  }

  @a2a_codes -32_010..-32_001//1

  @doc """
  The binding table: `%{jsonrpc_code => {http_status, grpc_status, grpc_name}}`
  for every A2A error (specification 5.4, identical at v1.0.1 and v1.1.0-rc
  apart from the v1.1-only `-32010`), the standard JSON-RPC codes and `-32000`.
  The HTTP+JSON and gRPC transports serve exactly these statuses.

  `scope` is `:all`, or `:a2a` for the A2A error types alone
  (`-32001..-32010`).

      iex> AshA2A.Protocol.JSONRPC.Error.bindings(:all)[-32_002]
      {400, 9, "FAILED_PRECONDITION"}

      iex> AshA2A.Protocol.JSONRPC.Error.bindings(:a2a) |> Map.keys() |> Enum.min_max()
      {-32_010, -32_001}
  """
  @spec bindings(:all | :a2a) :: %{integer() => {pos_integer(), non_neg_integer(), String.t()}}
  def bindings(:all), do: @bindings
  def bindings(:a2a), do: Map.take(@bindings, Enum.to_list(@a2a_codes))

  @doc """
  The HTTP status the HTTP+JSON binding answers for a JSON-RPC error code, or
  `nil` for a code the table does not know.

      iex> AshA2A.Protocol.JSONRPC.Error.http_status(-32_005)
      400
  """
  @spec http_status(integer()) :: pos_integer() | nil
  def http_status(code) do
    case Map.get(@bindings, code) do
      {http, _grpc, _name} -> http
      nil -> nil
    end
  end

  @doc """
  The numeric gRPC status the gRPC binding answers for a JSON-RPC error code,
  or `nil` for a code the table does not know.

      iex> AshA2A.Protocol.JSONRPC.Error.grpc_code(-32_004)
      9
  """
  @spec grpc_code(integer()) :: non_neg_integer() | nil
  def grpc_code(code) do
    case Map.get(@bindings, code) do
      {_http, grpc, _name} -> grpc
      nil -> nil
    end
  end

  @doc """
  The specification's gRPC status (numeric) for an A2A error code
  `-32001..-32010` (section 5.4), or `nil` for any other code. The gRPC
  transport serves this value (`grpc_code/1` is the same table, including the
  standard JSON-RPC codes).
  """
  @spec grpc_status(integer()) :: non_neg_integer() | nil
  def grpc_status(code) when code in @a2a_codes, do: grpc_code(code)
  def grpc_status(_code), do: nil

  @doc """
  The specification's HTTP status for an A2A error code `-32001..-32010`
  (section 5.4), or `nil` for any other code. The HTTP+JSON transport serves
  this value (`http_status/1` is the same table, including the standard
  JSON-RPC codes).
  """
  @spec spec_http_status(integer()) :: non_neg_integer() | nil
  def spec_http_status(code) when code in @a2a_codes, do: http_status(code)
  def spec_http_status(_code), do: nil

  @doc """
  google.rpc status string (e.g. `"NOT_FOUND"`) for the HTTP `error.status`
  field, by JSON-RPC code, or `nil`.
  """
  @spec status_name_for_code(integer()) :: String.t() | nil
  def status_name_for_code(code) do
    case Map.get(@bindings, code) do
      {_http, _grpc, name} -> name
      nil -> nil
    end
  end

  @doc "google.rpc status string for an ErrorInfo reason that has no own code."
  @spec status_name_for_reason(String.t()) :: String.t() | nil
  def status_name_for_reason("UNAUTHENTICATED"), do: "UNAUTHENTICATED"
  def status_name_for_reason("PERMISSION_DENIED"), do: "PERMISSION_DENIED"
  def status_name_for_reason("UNAVAILABLE"), do: "UNAVAILABLE"
  def status_name_for_reason("RESOURCE_EXHAUSTED"), do: "RESOURCE_EXHAUSTED"
  def status_name_for_reason(_), do: nil

  defp task_meta(opts) do
    case Keyword.get(opts, :task_id) do
      id when is_binary(id) and id != "" -> %{"taskId" => id}
      _ -> %{}
    end
  end

  defp detail_meta(nil), do: %{}
  defp detail_meta(detail), do: %{"detail" => stringify(detail)}

  # No extras: data untouched (existing behavior). Extras: pre-wrap so
  # `to_map/1` passes it through (idempotent).
  defp enrich(_code, data, meta, details) when meta == %{} and details == [], do: data

  defp enrich(code, data, meta, details) do
    if already_wrapped?(data) do
      data
    else
      reason = Map.fetch!(@error_info_reasons, code)
      [build_error_info(reason, Map.merge(detail_meta(data), meta)) | details]
    end
  end

  @doc """
  Converts an error struct to a JSON-ready map.

  For A2A-specific codes (-32001..-32009) and for -32602 `"data"` is always
  an array carrying a `google.rpc.ErrorInfo` object; any free-form data is
  preserved under its `"metadata"`. For the remaining standard JSON-RPC codes
  `"data"` is passed through as-is and omitted when nil.

      iex> error = AshA2A.Protocol.JSONRPC.Error.internal_error("boom")
      iex> AshA2A.Protocol.JSONRPC.Error.to_map(error)
      %{"code" => -32603, "message" => "Internal error", "data" => "boom"}
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = error) do
    base = %{"code" => error.code, "message" => error.message}

    case Map.fetch(@error_info_reasons, error.code) do
      {:ok, reason} -> Map.put(base, "data", error_details(error.data, reason))
      :error -> put_unless_nil(base, error.data)
    end
  end

  defp put_unless_nil(base, nil), do: base
  defp put_unless_nil(base, data), do: Map.put(base, "data", data)

  # Idempotent: an error decoded from the wire and re-serialized (a relay or
  # proxy path) already carries its ErrorInfo and must not be wrapped twice.
  defp error_details(data, reason) do
    if already_wrapped?(data), do: data, else: [error_info(reason, data)]
  end

  defp already_wrapped?(data) when is_list(data) do
    Enum.any?(data, &match?(%{"@type" => @error_info_type}, &1))
  end

  defp already_wrapped?(_), do: false

  defp error_info(reason, nil) do
    %{"@type" => @error_info_type, "domain" => @a2a_domain, "reason" => reason}
  end

  defp error_info(reason, detail) do
    Map.put(error_info(reason, nil), "metadata", %{"detail" => stringify(detail)})
  end

  defp stringify(detail) when is_binary(detail), do: detail
  defp stringify(detail), do: inspect(detail)
end
