# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.A2ATransport.PushConfigRPC do
  @moduledoc """
  JSON-RPC handlers for `tasks/pushNotificationConfig/{set,get,list,delete}`
  (A2A 0.3 wire shapes; the v0.3 PascalCase aliases route here too).

  | method | params | result |
  |--------|--------|--------|
  | `set` | `{taskId, pushNotificationConfig: {id?, url, token?, authentication?}}` | `TaskPushNotificationConfig` |
  | `get` | `{id: taskId, pushNotificationConfigId?}` | `TaskPushNotificationConfig` |
  | `list` | `{id: taskId}` | `[TaskPushNotificationConfig]` |
  | `delete` | `{id: taskId, pushNotificationConfigId}` | `null` |

  `taskId` is accepted in place of `id` on get/list/delete. Unknown tasks,
  and tasks not owned by the verified caller, are `-32001`. Webhook URLs are admitted by `AshA2A.A2ATransport.WebhookPolicy`
  at `set` time; a refused URL is `-32602` with
  `data: %{"code" => "refused_webhook_*", "detail" => ...}`. The
  `authentication.credentials` value is write-only: it is stored for delivery
  but never echoed back by get/list.
  """

  alias AshA2A.Protocol.JSONRPC.{Error, Response}
  alias AshA2A.A2ATransport
  alias AshA2A.A2ATransport.{PushConfigStore, WebhookPolicy}

  @doc "Dispatches one push-config method; returns a JSON-RPC response map."
  @spec handle(String.t(), map(), term(), map()) :: map()
  def handle(method, params, id, ctx) when is_map(params) do
    case run(method, params, ctx) do
      {:ok, result} -> Response.success(id, result)
      {:error, %Error{} = error} -> Response.error(id, error)
    end
  end

  def handle(_method, _params, id, _ctx),
    do: Response.error(id, Error.invalid_params("params must be an object"))

  defp run("tasks/pushNotificationConfig/set", params, ctx) do
    with {:ok, task_id} <- fetch_string(params, "taskId"),
         {:ok, raw} <- fetch_map(params, "pushNotificationConfig"),
         :ok <- task_exists(ctx, task_id),
         {:ok, config} <- build(task_id, raw, ctx.push_opts),
         {:ok, stored} <- store_put(ctx, config) do
      {:ok, encode(stored)}
    end
  end

  defp run("tasks/pushNotificationConfig/get", params, ctx) do
    with {:ok, task_id} <- task_id(params),
         :ok <- task_exists(ctx, task_id) do
      case PushConfigStore.get(store(ctx), task_id, params["pushNotificationConfigId"]) do
        {:ok, config} -> {:ok, encode(config)}
        :error -> {:error, Error.invalid_params("push notification config not found")}
      end
    end
  end

  defp run("tasks/pushNotificationConfig/list", params, ctx) do
    with {:ok, task_id} <- task_id(params),
         :ok <- task_exists(ctx, task_id) do
      {:ok, ctx |> store() |> PushConfigStore.list(task_id) |> Enum.map(&encode/1)}
    end
  end

  defp run("tasks/pushNotificationConfig/delete", params, ctx) do
    with {:ok, task_id} <- task_id(params),
         {:ok, config_id} <- fetch_string(params, "pushNotificationConfigId"),
         :ok <- task_exists(ctx, task_id) do
      # Idempotent per TCK PUSH-DEL-002: deleting an already-deleted (or
      # never-existing) config answers success, never an error. The unknown
      # *task* refusal above is unchanged — that is an addressing failure,
      # not a delete outcome.
      _ = PushConfigStore.delete(store(ctx), task_id, config_id)
      {:ok, nil}
    end
  end

  defp run(method, _params, _ctx), do: {:error, Error.method_not_found(method)}

  @doc """
  Validates and stores an inline `configuration.pushNotificationConfig` from
  `message/send`/`message/stream` for `task_id`.
  """
  @spec attach_inline(String.t(), map(), map()) :: {:ok, map()} | {:error, Error.t()}
  def attach_inline(task_id, raw, ctx) do
    with {:ok, config} <- build(task_id, raw, ctx.push_opts) do
      store_put(ctx, config)
    end
  end

  @doc "Admits an inline push config's URL before any work is started."
  @spec preflight(map(), keyword()) :: :ok | {:error, Error.t()}
  def preflight(raw, push_opts) do
    with {:ok, _} <- build("preflight", raw, push_opts), do: :ok
  end

  defp build(task_id, raw, push_opts) when is_map(raw) do
    with {:ok, url} <- fetch_string(raw, "url"),
         :ok <- admit(url, push_opts),
         :ok <- optional_string(raw, "token"),
         :ok <- optional_map(raw, "authentication") do
      {:ok,
       %{
         id: raw["id"] || generate_id(),
         task_id: task_id,
         url: url,
         token: raw["token"],
         authentication: raw["authentication"]
       }}
    end
  end

  defp build(_task_id, _raw, _opts),
    do: {:error, Error.invalid_params("\"pushNotificationConfig\" must be an object")}

  defp admit(url, push_opts) do
    case WebhookPolicy.admit(url, Keyword.take(push_opts, [:allow_http, :allow_cidrs, :resolver])) do
      {:ok, _} ->
        :ok

      {:error, code, detail} ->
        {:error, Error.invalid_params(%{"code" => Atom.to_string(code), "detail" => detail})}
    end
  end

  defp store_put(ctx, config) do
    case PushConfigStore.put(store(ctx), config) do
      {:ok, stored} ->
        {:ok, stored}

      {:error, code, detail} ->
        {:error, Error.invalid_params(%{"code" => Atom.to_string(code), "detail" => detail})}
    end
  end

  defp store(ctx), do: A2ATransport.push_store_name(ctx.transport)

  # Owner-scoped: a task the verified caller does not own is -32001, exactly
  # like a missing one (see AshA2A.A2ATransport.Ownership).
  defp task_exists(ctx, task_id) do
    case AshA2A.A2ATransport.Ownership.fetch(
           ctx.agent,
           task_id,
           Map.get(ctx, :principal, :anonymous)
         ) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, Error.task_not_found()}
    end
  end

  defp task_id(params) do
    case params["id"] || params["taskId"] do
      id when is_binary(id) -> {:ok, id}
      _ -> {:error, Error.invalid_params("\"id\" (task id) is required")}
    end
  end

  defp fetch_string(map, key) do
    case map[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, Error.invalid_params("\"#{key}\" is required")}
    end
  end

  defp fetch_map(map, key) do
    case map[key] do
      value when is_map(value) -> {:ok, value}
      _ -> {:error, Error.invalid_params("\"#{key}\" must be an object")}
    end
  end

  defp optional_string(map, key) do
    if is_nil(map[key]) or is_binary(map[key]),
      do: :ok,
      else: {:error, Error.invalid_params("\"#{key}\" must be a string")}
  end

  defp optional_map(map, key) do
    if is_nil(map[key]) or is_map(map[key]),
      do: :ok,
      else: {:error, Error.invalid_params("\"#{key}\" must be an object")}
  end

  defp generate_id, do: 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  @doc false
  def encode(config) do
    auth =
      case config.authentication do
        %{} = a -> Map.delete(a, "credentials")
        nil -> nil
      end

    push =
      %{"id" => config.id, "url" => config.url}
      |> put_unless_nil("token", config.token)
      |> put_unless_nil("authentication", auth)

    %{"taskId" => config.task_id, "pushNotificationConfig" => push}
  end

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)
end
