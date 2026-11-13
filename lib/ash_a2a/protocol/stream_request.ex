# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Protocol.StreamRequest do
  @moduledoc """
  A2A v1.1 `StreamRequest` (`SendLiveMessage` uplink item), decoded from its
  wire map shape:

      %{"tenant" => "t", "sendMessage" => %{"message" => ..., "configuration" => ...,
                                             "artifactUpdates" => [...]}}
      %{"tenant" => "t", "subscribe" => %{"taskId" => id, "lastSeenGeneration" => 7}}

  `decode/1` returns:

    * `{:ok, %StreamRequest{kind: :send_message | :subscribe, ...}}`
    * `{:error, {:unknown_payload, keys}}` - no recognised payload key (forward
      compatibility: the server rejects the request, never the stream)
    * `{:error, {:invalid, detail, reference_id}}` - malformed; `reference_id` is
      the rejected `messageId` / `artifactId` when one can be named, else `nil`

  `payload` is `%{message: Message.t() | nil, configuration: map(),
  artifact_updates: [map()], task_id: String.t() | nil}` for `:send_message` and
  `%{task_id: String.t(), last_seen_generation: non_neg_integer() | nil}` for
  `:subscribe`.
  """

  alias AshA2A.Protocol.JSON

  @type t :: %__MODULE__{
          kind: :send_message | :subscribe,
          tenant: String.t() | nil,
          payload: map()
        }
  defstruct [:kind, :tenant, :payload]

  @spec decode(term()) :: {:ok, t()} | {:error, term()}
  def decode(%{} = map) do
    tenant = Map.get(map, "tenant")
    send? = Map.has_key?(map, "sendMessage")
    sub? = Map.has_key?(map, "subscribe")

    cond do
      send? and sub? ->
        {:error, {:invalid, "StreamRequest carries more than one payload", nil}}

      send? ->
        decode_send(Map.get(map, "sendMessage"), tenant)

      sub? ->
        decode_subscribe(Map.get(map, "subscribe"), tenant)

      true ->
        {:error, {:unknown_payload, map |> Map.keys() |> Enum.reject(&(&1 == "tenant"))}}
    end
  end

  def decode(_other), do: {:error, {:invalid, "StreamRequest must be an object", nil}}

  defp decode_subscribe(%{} = sub, tenant) do
    task_id = Map.get(sub, "taskId") || Map.get(sub, "id")

    cond do
      not (is_binary(task_id) and task_id != "") ->
        {:error, {:invalid, "subscribe requires taskId", nil}}

      true ->
        case parse_generation(Map.get(sub, "lastSeenGeneration")) do
          {:ok, gen} ->
            {:ok,
             %__MODULE__{
               kind: :subscribe,
               tenant: tenant,
               payload: %{task_id: task_id, last_seen_generation: gen}
             }}

          :error ->
            {:error, {:invalid, "lastSeenGeneration must be a non-negative integer", nil}}
        end
    end
  end

  defp decode_subscribe(_, _), do: {:error, {:invalid, "subscribe must be an object", nil}}

  defp decode_send(%{} = send, tenant) do
    updates = Map.get(send, "artifactUpdates") || []
    configuration = Map.get(send, "configuration") || %{}
    raw_message = Map.get(send, "message")

    cond do
      not is_list(updates) ->
        {:error, {:invalid, "artifactUpdates must be a list", nil}}

      not is_map(configuration) ->
        {:error, {:invalid, "configuration must be an object", message_id(raw_message)}}

      is_nil(raw_message) and updates == [] ->
        {:error, {:invalid, "sendMessage requires message or artifactUpdates", nil}}

      true ->
        with {:ok, message} <- decode_message(raw_message),
             :ok <- check_updates(updates) do
          task_id =
            (message && message.task_id) || first_update_task(updates)

          {:ok,
           %__MODULE__{
             kind: :send_message,
             tenant: tenant,
             payload: %{
               message: message,
               configuration: configuration,
               artifact_updates: updates,
               task_id: blank_to_nil(task_id)
             }
           }}
        end
    end
  end

  defp decode_send(_, _), do: {:error, {:invalid, "sendMessage must be an object", nil}}

  defp decode_message(nil), do: {:ok, nil}

  defp decode_message(%{} = raw) do
    case JSON.decode(raw, :message) do
      {:ok, message} ->
        {:ok, message}

      {:error, reason} ->
        {:error, {:invalid, "invalid message: #{inspect(reason)}", message_id(raw)}}
    end
  end

  defp decode_message(_), do: {:error, {:invalid, "message must be an object", nil}}

  defp check_updates(updates) do
    Enum.reduce_while(updates, :ok, fn
      %{"artifact" => %{} = artifact}, :ok ->
        case JSON.decode(artifact, :artifact) do
          {:ok, _} ->
            {:cont, :ok}

          {:error, reason} ->
            {:halt,
             {:error, {:invalid, "invalid artifact: #{inspect(reason)}", artifact_id(artifact)}}}
        end

      other, :ok ->
        {:halt,
         {:error, {:invalid, "artifactUpdates entry needs an artifact", artifact_id(other)}}}
    end)
  end

  defp first_update_task([%{"taskId" => id} | _]), do: id
  defp first_update_task(_), do: nil

  defp message_id(%{"messageId" => id}) when is_binary(id), do: id
  defp message_id(_), do: nil

  defp artifact_id(%{"artifact" => %{"artifactId" => id}}) when is_binary(id), do: id
  defp artifact_id(%{"artifactId" => id}) when is_binary(id), do: id
  defp artifact_id(_), do: nil

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v

  defp parse_generation(nil), do: {:ok, nil}
  defp parse_generation(n) when is_integer(n) and n >= 0, do: {:ok, n}

  defp parse_generation(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_generation(_), do: :error
end
