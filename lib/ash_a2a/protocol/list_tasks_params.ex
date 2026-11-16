# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Protocol.ListTasksParams do
  @moduledoc """
  The one validator for `ListTasksRequest` members, shared by the JSON-RPC
  (`tasks/list`), HTTP+JSON (`GET /tasks`) and gRPC (`ListTasks`) bindings.

  `validate/1` takes the string-keyed params map of a request (query values
  already coerced by the HTTP binding, proto-JSON for gRPC) and refuses a
  present, non-null member of the wrong JSON type or out of range:

    * `pageSize` - integer 1..100
    * `historyLength`, `timelineLength` - non-negative integer
      (`timelineLength` may be a decimal string, as proto3 JSON int64)
    * `includeArtifacts` - boolean
    * `contextId`, `pageToken` - string
    * `status` - one of `AshA2A.Protocol.JSON.valid_state_strings/0`
    * `statusTimestampAfter` - ISO 8601 timestamp string

  It returns `:ok` or `{:error, message}`. Each binding maps the refusal with
  its own table: JSON-RPC `-32602`, HTTP `400` `INVALID_ARGUMENT`, gRPC
  `INVALID_ARGUMENT(3)`; `to_error/1` builds the shared `-32602` error those
  tables start from.
  """

  alias AshA2A.Protocol.JSONRPC.Error

  @doc "Validates the `ListTasksRequest` members in `params`."
  @spec validate(map()) :: :ok | {:error, String.t()}
  def validate(params) when is_map(params) do
    checks = [
      {&bad_timeline_length?/1, "\"timelineLength\" must be a non-negative integer"},
      {&bad_page_size?/1, "\"pageSize\" must be an integer between 1 and 100"},
      {&bad_status?/1, "\"status\" must be a valid task state"},
      {&bad_history_length?/1, "\"historyLength\" must be a non-negative integer"},
      {&bad_timestamp?/1, "\"statusTimestampAfter\" must be a valid ISO 8601 timestamp"},
      {&bad_bool?(&1, "includeArtifacts"), "\"includeArtifacts\" must be a boolean"},
      {&bad_string?(&1, "contextId"), "\"contextId\" must be a string"},
      {&bad_string?(&1, "pageToken"), "\"pageToken\" must be a string"}
    ]

    case Enum.find(checks, fn {bad?, _message} -> bad?.(params) end) do
      nil -> :ok
      {_bad?, message} -> {:error, message}
    end
  end

  def validate(_other), do: {:error, "params must be an object"}

  @doc "The shared `-32602` (invalid params) error for a `validate/1` refusal message."
  @spec to_error(String.t()) :: Error.t()
  def to_error(message) when is_binary(message), do: Error.invalid_params(message)

  # -- checks -------------------------------------------------------------------

  defp bad_page_size?(%{"pageSize" => nil}), do: false
  defp bad_page_size?(%{"pageSize" => ps}), do: not is_integer(ps) or ps < 1 or ps > 100
  defp bad_page_size?(_), do: false

  defp bad_status?(%{"status" => nil}), do: false

  defp bad_status?(%{"status" => status}) when is_binary(status),
    do: status not in AshA2A.Protocol.JSON.valid_state_strings()

  defp bad_status?(%{"status" => _}), do: true
  defp bad_status?(_), do: false

  defp bad_history_length?(params) do
    bad_nonneg?(history(params)) or
      case Map.get(params, "configuration") do
        %{} = configuration -> bad_nonneg?(history(configuration))
        _ -> false
      end
  end

  defp bad_timeline_length?(params) do
    bad_nonneg?(timeline(params)) or
      case Map.get(params, "configuration") do
        %{} = configuration -> bad_nonneg?(timeline(configuration))
        _ -> false
      end
  end

  defp history(%{"historyLength" => v}), do: v
  defp history(%{"history_length" => v}), do: v
  defp history(_), do: nil

  defp timeline(%{"timelineLength" => v}), do: norm_int(v)
  defp timeline(%{"timeline_length" => v}), do: norm_int(v)
  defp timeline(_), do: nil

  defp norm_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> n
      _ -> v
    end
  end

  defp norm_int(v), do: v

  defp bad_nonneg?(nil), do: false
  defp bad_nonneg?(v), do: not is_integer(v) or v < 0

  defp bad_bool?(params, key) do
    case Map.get(params, key) do
      nil -> false
      v -> not is_boolean(v)
    end
  end

  defp bad_string?(params, key) do
    case Map.get(params, key) do
      nil -> false
      v -> not is_binary(v)
    end
  end

  defp bad_timestamp?(%{"statusTimestampAfter" => nil}), do: false

  defp bad_timestamp?(%{"statusTimestampAfter" => ts}) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, _, _} -> false
      _ -> true
    end
  end

  defp bad_timestamp?(%{"statusTimestampAfter" => _}), do: true
  defp bad_timestamp?(_), do: false
end
