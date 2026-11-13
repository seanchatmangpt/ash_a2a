defmodule AshA2A.Protocol.JSONRPC.Request do
  @moduledoc false

  alias AshA2A.Protocol.JSONRPC.Error

  @type id :: String.t() | integer() | nil

  @type t :: %__MODULE__{
          jsonrpc: String.t(),
          id: id(),
          method: String.t(),
          params: map()
        }

  @enforce_keys [:jsonrpc, :method]
  defstruct [:jsonrpc, :id, :method, params: %{}]

  @doc """
  Parses a raw map into a `%Request{}`, validating the JSON-RPC 2.0 envelope.

  Returns `{:ok, request}` or `{:error, %Error{}}`.
  """
  @spec parse(map()) :: {:ok, t()} | {:error, Error.t()}
  def parse(%{} = raw) do
    with :ok <- validate_jsonrpc(raw),
         {:ok, method} <- validate_method(raw),
         {:ok, id} <- validate_id(raw),
         {:ok, params} <- validate_params_field(raw) do
      {:ok, %__MODULE__{jsonrpc: "2.0", id: id, method: method, params: params}}
    end
  end

  def parse(_), do: {:error, Error.invalid_request("Request must be a JSON object")}

  @doc """
  Validates method-specific params on a parsed request.

  Returns `:ok` or `{:error, %Error{}}`.
  """
  @spec validate_params(t()) :: :ok | {:error, Error.t()}
  def validate_params(%__MODULE__{method: method, params: params})
      when method in ["message/send", "message/stream"] do
    cond do
      not is_map(params["message"]) and not artifact_only_send?(method, params) ->
        {:error, Error.invalid_params("\"message\" must be a JSON object")}

      bad_timeline_length?(params) ->
        {:error, Error.invalid_params("\"timelineLength\" must be a non-negative integer")}

      bad_generation?(Map.get(params, "configuration")) ->
        {:error, Error.invalid_params("\"ifGenerationMatch\" must be a non-negative integer")}

      bad_artifact_updates?(params) ->
        {:error,
         Error.invalid_params("\"artifactUpdates\" must be a list of artifact update objects")}

      bad_history_length?(params) ->
        {:error, Error.invalid_params("\"historyLength\" must be a non-negative integer")}

      bad_send_configuration?(params) ->
        {:error,
         Error.invalid_params(
           "\"returnImmediately\" must be a boolean and \"acceptedOutputModes\" a list of strings"
         )}

      true ->
        :ok
    end
  end

  def validate_params(%__MODULE__{method: method, params: params})
      when method in ["tasks/get", "tasks/cancel", "tasks/resubscribe"] do
    cond do
      not is_binary(params["id"]) ->
        {:error, Error.invalid_params("\"id\" must be a string")}

      bad_history_length?(params) ->
        {:error, Error.invalid_params("\"historyLength\" must be a non-negative integer")}

      method == "tasks/get" and bad_timeline_length?(params) ->
        {:error, Error.invalid_params("\"timelineLength\" must be a non-negative integer")}

      method == "tasks/get" and bad_current_generation?(params) ->
        {:error, Error.invalid_params("\"currentGeneration\" must be a non-negative integer")}

      true ->
        :ok
    end
  end

  def validate_params(%__MODULE__{method: "tasks/list", params: params}) do
    cond do
      bad_timeline_length?(params) ->
        {:error, Error.invalid_params("\"timelineLength\" must be a non-negative integer")}

      bad_page_size?(params) ->
        {:error, Error.invalid_params("\"pageSize\" must be an integer between 1 and 100")}

      bad_status?(params) ->
        {:error, Error.invalid_params("\"status\" must be a valid task state")}

      bad_history_length?(params) ->
        {:error, Error.invalid_params("\"historyLength\" must be a non-negative integer")}

      bad_timestamp?(params) ->
        {:error,
         Error.invalid_params("\"statusTimestampAfter\" must be a valid ISO 8601 timestamp")}

      true ->
        :ok
    end
  end

  @push_methods [
    "tasks/pushNotificationConfig/set",
    "tasks/pushNotificationConfig/get",
    "tasks/pushNotificationConfig/list",
    "tasks/pushNotificationConfig/delete"
  ]

  def validate_params(%__MODULE__{method: method, params: params}) when method in @push_methods do
    cond do
      # The task id travels as `taskId`/`task_id`; the REST-mapped dispatchers
      # (A2ATransport) carry it as `id` with the config under
      # `pushNotificationConfigId`, so `id` also satisfies the task reference.
      not non_empty_string?(params["taskId"] || params["task_id"] || params["id"]) ->
        {:error, Error.invalid_params("\"taskId\" must be a non-empty string")}

      method == "tasks/pushNotificationConfig/list" and bad_push_page?(params) ->
        {:error,
         Error.invalid_params(
           "\"pageSize\" must be a positive integer and \"pageToken\" a string"
         )}

      true ->
        :ok
    end
  end

  def validate_params(%__MODULE__{}), do: :ok

  defp non_empty_string?(value), do: is_binary(value) and value != ""

  defp bad_push_page?(params) do
    bad_size? =
      case Map.get(params, "pageSize") do
        nil -> false
        size -> not is_integer(size) or size < 1
      end

    bad_token? =
      case Map.get(params, "pageToken") do
        nil -> false
        token -> not is_binary(token)
      end

    bad_size? or bad_token?
  end

  @doc """
  Reads `historyLength` from a params map, accepting either spelling.

  The spec names this field `historyLength`, and that is what the REST
  binding and our own client send. Some JSON-RPC clients send the protobuf
  field name `history_length` instead, and the reference implementation
  accepts both, so we do too rather than silently ignoring the limit.

  Returns `nil` when neither key is present.
  """
  @spec history_length(map()) :: term() | nil
  def history_length(%{"historyLength" => hl}), do: hl
  def history_length(%{"history_length" => hl}), do: hl
  def history_length(_), do: nil

  @doc """
  Reads `timelineLength` (or `timeline_length`) from a params/configuration
  map. Returns `nil` when absent.
  """
  @spec timeline_length(map()) :: term() | nil
  def timeline_length(%{"timelineLength" => v}), do: norm_int(v)
  def timeline_length(%{"timeline_length" => v}), do: norm_int(v)
  def timeline_length(_), do: nil

  # int64 fields may arrive as decimal strings (proto3 JSON); anything else
  # passes through unchanged so validation can refuse it.
  defp norm_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> n
      _ -> v
    end
  end

  defp norm_int(v), do: v

  @doc "Reads `currentGeneration` (or `current_generation`); `nil` when absent."
  @spec current_generation(map()) :: term() | nil
  def current_generation(%{"currentGeneration" => v}), do: norm_int(v)
  def current_generation(%{"current_generation" => v}), do: norm_int(v)
  def current_generation(_), do: nil

  @doc "Reads `ifGenerationMatch` (or `if_generation_match`); `nil` when absent."
  @spec if_generation_match(map() | nil) :: term() | nil
  def if_generation_match(%{"ifGenerationMatch" => v}), do: norm_int(v)
  def if_generation_match(%{"if_generation_match" => v}), do: norm_int(v)
  def if_generation_match(_), do: nil

  @doc "Reads the client `artifactUpdates` list (or `artifact_updates`); `[]` when absent."
  @spec artifact_updates(map()) :: [map()]
  def artifact_updates(%{"artifactUpdates" => v}) when is_list(v), do: v
  def artifact_updates(%{"artifact_updates" => v}) when is_list(v), do: v
  def artifact_updates(_), do: []

  @doc """
  Reads `SendMessageConfiguration.return_immediately` from a configuration map.

  Accepts `returnImmediately` / `return_immediately`, and the legacy
  `blocking` flag as its inverse (`blocking: false` == return immediately).
  Defaults to `false` (wait for a terminal or interrupted state).
  """
  @spec return_immediately(map() | nil) :: boolean()
  def return_immediately(%{"returnImmediately" => v}) when is_boolean(v), do: v
  def return_immediately(%{"return_immediately" => v}) when is_boolean(v), do: v
  def return_immediately(%{"blocking" => v}) when is_boolean(v), do: not v
  def return_immediately(_), do: false

  @doc """
  Reads `acceptedOutputModes` (or `accepted_output_modes`) from a
  configuration map. Returns `nil` when absent or not a list of strings.
  """
  @spec accepted_output_modes(map() | nil) :: [String.t()] | nil
  def accepted_output_modes(%{"acceptedOutputModes" => modes}), do: clean_modes(modes)
  def accepted_output_modes(%{"accepted_output_modes" => modes}), do: clean_modes(modes)
  def accepted_output_modes(_), do: nil

  defp clean_modes(modes) when is_list(modes) do
    if Enum.all?(modes, &is_binary/1), do: modes, else: nil
  end

  defp clean_modes(_), do: nil

  # -- private ---------------------------------------------------------------

  defp validate_jsonrpc(%{"jsonrpc" => "2.0"}), do: :ok

  defp validate_jsonrpc(_) do
    {:error, Error.invalid_request("\"jsonrpc\" must be \"2.0\"")}
  end

  defp validate_method(%{"method" => method}) when is_binary(method), do: {:ok, method}

  defp validate_method(_) do
    {:error, Error.invalid_request("\"method\" must be a string")}
  end

  defp validate_id(%{"id" => id}) when is_binary(id), do: {:ok, id}
  defp validate_id(%{"id" => id}) when is_integer(id), do: {:ok, id}
  defp validate_id(%{"id" => nil}), do: {:ok, nil}
  defp validate_id(raw) when not is_map_key(raw, "id"), do: {:ok, nil}

  defp validate_id(_) do
    {:error, Error.invalid_request("\"id\" must be a string, integer, or null")}
  end

  defp validate_params_field(%{"params" => params}) when is_map(params), do: {:ok, params}
  defp validate_params_field(%{"params" => _}), do: {:ok, %{}}
  defp validate_params_field(_), do: {:ok, %{}}

  defp bad_page_size?(%{"pageSize" => ps}) do
    not is_integer(ps) or ps < 1 or ps > 100
  end

  defp bad_page_size?(_), do: false

  defp bad_status?(%{"status" => status}) when is_binary(status) do
    status not in AshA2A.Protocol.JSON.valid_state_strings()
  end

  defp bad_status?(%{"status" => _}), do: true
  defp bad_status?(_), do: false

  defp bad_history_length?(params) do
    bad_hl?(params) or
      case Map.get(params, "configuration") do
        %{} = configuration -> bad_hl?(configuration)
        _ -> false
      end
  end

  defp bad_send_configuration?(params) do
    case Map.get(params, "configuration") do
      %{} = conf ->
        bad_bool?(conf, "returnImmediately") or bad_bool?(conf, "return_immediately") or
          bad_modes?(conf, "acceptedOutputModes") or bad_modes?(conf, "accepted_output_modes")

      _ ->
        false
    end
  end

  defp bad_bool?(map, key) do
    case Map.fetch(map, key) do
      {:ok, v} -> not is_boolean(v)
      :error -> false
    end
  end

  defp bad_modes?(map, key) do
    case Map.fetch(map, key) do
      {:ok, v} -> not (is_list(v) and Enum.all?(v, &is_binary/1))
      :error -> false
    end
  end

  # `message` may be omitted only on unary send, and only when every
  # client artifact update names its (existing) task.
  defp artifact_only_send?("message/send", params) do
    case Map.get(params, "message") do
      nil ->
        updates = artifact_updates(params)

        updates != [] and
          Enum.all?(updates, fn u ->
            is_map(u) and non_empty_string?(u["taskId"] || u["task_id"])
          end)

      _ ->
        false
    end
  end

  defp artifact_only_send?(_method, _params), do: false

  defp bad_artifact_updates?(params) do
    case Map.fetch(params, "artifactUpdates") do
      {:ok, v} -> not (is_list(v) and Enum.all?(v, &is_map/1))
      :error -> false
    end
  end

  defp bad_timeline_length?(params) do
    bad_nonneg?(timeline_length(params)) or
      case Map.get(params, "configuration") do
        %{} = configuration -> bad_nonneg?(timeline_length(configuration))
        _ -> false
      end
  end

  defp bad_current_generation?(params), do: bad_nonneg?(current_generation(params))

  defp bad_generation?(%{} = configuration), do: bad_nonneg?(if_generation_match(configuration))
  defp bad_generation?(_), do: false

  defp bad_nonneg?(nil), do: false
  defp bad_nonneg?(v), do: not is_integer(v) or v < 0

  defp bad_hl?(map) do
    case AshA2A.Protocol.JSONRPC.Request.history_length(map) do
      nil -> false
      hl -> not is_integer(hl) or hl < 0
    end
  end

  defp bad_timestamp?(%{"statusTimestampAfter" => ts}) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, _, _} -> false
      _ -> true
    end
  end

  defp bad_timestamp?(%{"statusTimestampAfter" => _}), do: true
  defp bad_timestamp?(_), do: false
end
