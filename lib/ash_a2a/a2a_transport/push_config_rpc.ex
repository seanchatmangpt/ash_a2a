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

  @max_url 2048
  @max_token 512
  @max_id 128
  @max_credentials 2048
  @max_schemes 8
  alias AshA2A.A2ATransport
  alias AshA2A.A2ATransport.{PushConfigStore, PushDelivery, WebhookPolicy}

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
    # `tenant` (v1 multi-tenancy) is routing-only: it selects the agent/mount
    # upstream of this module and is deliberately NOT part of the store key
    # (task ids are already globally unique per transport). It is ignored here.
    with {:ok, task_id} <- fetch_string(params, "taskId"),
         {:ok, raw, flat?} <- config_source(params),
         :ok <- task_exists(ctx, task_id),
         {:ok, config} <- build(task_id, raw, ctx.push_opts, request_version(ctx)),
         {:ok, stored} <- store_put(ctx, config) do
      {:ok, encode(stored, flat?)}
    end
  end

  defp run("tasks/pushNotificationConfig/get", params, ctx) do
    with {:ok, task_id} <- task_id(params),
         :ok <- task_exists(ctx, task_id) do
      case PushConfigStore.get(store(ctx), task_id, params["pushNotificationConfigId"]) do
        {:ok, config} -> {:ok, encode(config, v1_wire?(ctx))}
        :error -> {:error, Error.invalid_params("push notification config not found")}
      end
    end
  end

  # Legacy (0.3) callers get the bare list. The v1 shape
  # `{configs, nextPageToken}` is returned when the caller pages
  # (`pageSize`/`pageToken` present) or `ctx.wire == :v1`.
  defp run("tasks/pushNotificationConfig/list", params, ctx) do
    with {:ok, task_id} <- task_id(params),
         :ok <- task_exists(ctx, task_id) do
      configs = ctx |> store() |> PushConfigStore.list(task_id)
      flat? = v1_wire?(ctx)

      if v1_wire?(ctx) or Map.has_key?(params, "pageSize") or Map.has_key?(params, "pageToken") do
        with {:ok, page, next} <- paginate(configs, params) do
          result = %{
            "configs" => Enum.map(page, &encode(&1, flat?)),
            "nextPageToken" => next || ""
          }

          {:ok, result}
        end
      else
        {:ok, Enum.map(configs, &encode(&1, false))}
      end
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
    with {:ok, config} <- build(task_id, raw, ctx.push_opts, request_version(ctx)) do
      store_put(ctx, config)
    end
  end

  @doc "Admits an inline push config's URL before any work is started."
  @spec preflight(map(), keyword()) :: :ok | {:error, Error.t()}
  def preflight(raw, push_opts) do
    with {:ok, _} <- build("preflight", raw, push_opts, nil), do: :ok
  end

  defp v1_wire?(ctx), do: Map.get(ctx, :wire) == :v1

  # The A2A version of the request creating the config (ctx key :a2a_version,
  # negotiated by the plug), else "1.0".
  defp request_version(ctx), do: Map.get(ctx, :a2a_version) || "1.0"

  # Accepts the v1 flat `TaskPushNotificationConfig` (id, taskId, url, token,
  # authentication at the top level) and falls back to the legacy nested
  # `pushNotificationConfig`. Returns `{:ok, raw, flat?}`.
  defp config_source(params) do
    case params["pushNotificationConfig"] do
      %{} = nested ->
        {:ok, nested, false}

      nil ->
        if is_binary(params["url"]),
          do:
            {:ok, Map.take(params, ["id", "url", "token", "authentication", "protocolVersion"]),
             true},
          else: {:error, Error.invalid_params("\"pushNotificationConfig\" must be an object")}

      _ ->
        {:error, Error.invalid_params("\"pushNotificationConfig\" must be an object")}
    end
  end

  @doc false
  # Shared pagination helper: `pageSize`/`pageToken` in, `{page, next | nil}` out.
  # The token is an opaque base64url offset; malformed -> -32602.
  def paginate(configs, params) do
    with {:ok, offset} <- decode_page_token(params["pageToken"]),
         {:ok, size} <- page_size(params["pageSize"]) do
      rest = Enum.drop(configs, offset)

      case size do
        nil ->
          {:ok, rest, nil}

        size ->
          {page, remaining} = Enum.split(rest, size)

          next =
            if remaining == [],
              do: nil,
              else: Base.url_encode64(Integer.to_string(offset + size), padding: false)

          {:ok, page, next}
      end
    end
  end

  defp page_size(nil), do: {:ok, nil}
  defp page_size(n) when is_integer(n) and n > 0, do: {:ok, n}
  defp page_size(n) when is_integer(n), do: {:ok, nil}

  defp page_size(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n > 0 -> {:ok, n}
      {_, ""} -> {:ok, nil}
      _ -> {:error, Error.invalid_params("\"pageSize\" must be an integer")}
    end
  end

  defp page_size(_), do: {:error, Error.invalid_params("\"pageSize\" must be an integer")}

  defp decode_page_token(nil), do: {:ok, 0}
  defp decode_page_token(""), do: {:ok, 0}

  defp decode_page_token(token) when is_binary(token) do
    with {:ok, bin} <- Base.url_decode64(token, padding: false),
         {offset, ""} when offset >= 0 <- Integer.parse(bin) do
      {:ok, offset}
    else
      _ -> {:error, Error.invalid_params("\"pageToken\" is not a valid page token")}
    end
  end

  defp decode_page_token(_),
    do: {:error, Error.invalid_params("\"pageToken\" is not a valid page token")}

  defp build(task_id, raw, push_opts, default_version) when is_map(raw) do
    with {:ok, url} <- fetch_string(raw, "url"),
         {:ok, version} <- protocol_version(raw, default_version),
         :ok <- admit(url, push_opts),
         :ok <- bounded(url, "url", @max_url),
         :ok <- optional_string(raw, "token"),
         :ok <- optional_bounded(raw, "token", @max_token),
         :ok <- optional_id(raw),
         :ok <- optional_map(raw, "authentication"),
         :ok <- validate_authentication(raw["authentication"]) do
      {:ok,
       %{
         id: raw["id"] || generate_id(),
         task_id: task_id,
         url: url,
         token: raw["token"],
         authentication: raw["authentication"],
         protocol_version: version
       }}
    end
  end

  defp build(_task_id, _raw, _opts, _version),
    do: {:error, Error.invalid_params("\"pushNotificationConfig\" must be an object")}

  # An explicit `protocolVersion` wins; otherwise the creating request's
  # version; otherwise "1.0".
  defp protocol_version(raw, default) do
    case raw["protocolVersion"] do
      nil ->
        {:ok, AshA2A.Protocol.Version.normalize(default || "1.0")}

      v when is_binary(v) ->
        if v =~ ~r/\A\s*\d+\.\d+/,
          do: {:ok, AshA2A.Protocol.Version.normalize(v)},
          else: {:error, Error.invalid_params("\"protocolVersion\" must be Major.Minor")}

      _ ->
        {:error, Error.invalid_params("\"protocolVersion\" must be a string")}
    end
  end

  defp bounded(value, key, max) do
    if byte_size(value) <= max,
      do: :ok,
      else: {:error, Error.invalid_params("\"#{key}\" exceeds #{max} bytes")}
  end

  defp optional_bounded(map, key, max) do
    case map[key] do
      value when is_binary(value) -> bounded(value, key, max)
      _ -> :ok
    end
  end

  # A config id keys the store and is echoed in URLs: it must be a short,
  # URL-safe string, not an arbitrary term.
  defp optional_id(%{"id" => nil}), do: :ok

  defp optional_id(%{"id" => id}) do
    if is_binary(id) and id =~ ~r/\A[A-Za-z0-9._~:-]{1,#{@max_id}}\z/,
      do: :ok,
      else: {:error, Error.invalid_params("\"id\" must be 1-#{@max_id} URL-safe characters")}
  end

  defp optional_id(_raw), do: :ok

  defp validate_authentication(nil), do: :ok

  defp validate_authentication(auth) do
    list = auth["schemes"] || singular_scheme(auth["scheme"])

    with :ok <- schemes(list),
         :ok <- optional_string(auth, "credentials"),
         :ok <- optional_bounded(auth, "credentials", @max_credentials),
         :ok <- sendable_scheme(list, auth["credentials"]) do
      credentials_safe(auth["credentials"])
    end
  end

  # Fail at set time, not silently unauthenticated at delivery: mTLS is refused
  # with its own typed error; any scheme PushDelivery cannot render is refused;
  # a sendable scheme needs credentials to send.
  defp sendable_scheme(list, _creds) do
    kinds = Enum.map(list, &PushDelivery.classify_scheme/1)

    cond do
      Enum.any?(kinds, &(&1 == {:error, :mtls})) ->
        {:error,
         Error.invalid_params(%{
           "code" => "refused_push_auth_mtls",
           "detail" => "mutual-TLS push authentication is not supported for webhook delivery"
         })}

      not Enum.any?(kinds, &match?({:ok, _}, &1)) ->
        {:error,
         Error.invalid_params(%{
           "code" => "refused_push_auth_scheme",
           "detail" => "no supported authentication scheme in #{inspect(list)}"
         })}

      true ->
        :ok
    end
  end

  # Credentials travel inside a header: CR/LF/NUL is header injection.
  defp credentials_safe(nil), do: :ok

  defp credentials_safe(creds) do
    if String.contains?(creds, ["\r", "\n", "\0"]),
      do:
        {:error,
         Error.invalid_params("\"authentication.credentials\" contains control characters")},
      else: :ok
  end

  # The v1 proto's AuthenticationInfo carries a singular `scheme`; the spec
  # text an array `schemes`. Both are admitted.
  defp singular_scheme(s) when is_binary(s), do: [s]
  defp singular_scheme(other), do: other

  defp schemes(schemes)
       when is_list(schemes) and schemes != [] and length(schemes) <= @max_schemes do
    if Enum.all?(schemes, &(is_binary(&1) and &1 != "" and byte_size(&1) <= 64)),
      do: :ok,
      else: {:error, Error.invalid_params("\"authentication.schemes\" must be non-empty strings")}
  end

  defp schemes(_),
    do:
      {:error,
       Error.invalid_params(
         "\"authentication.schemes\" must be a non-empty list of at most #{@max_schemes} strings"
       )}

  defp admit(url, push_opts) do
    case WebhookPolicy.admit(
           url,
           Keyword.take(push_opts, [:allow_http, :allow_cidrs, :resolver, :allow_ports])
         ) do
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
    case AshA2A.A2ATransport.Ownership.fetch_strict(
           ctx.agent,
           task_id,
           Map.get(ctx, :principal, :anonymous)
         ) do
      {:ok, _} -> :ok
      {:error, :unavailable} -> {:error, Error.internal_error("agent unavailable")}
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
  def encode(config), do: encode(config, false)

  @doc false
  # flat? = v1 `TaskPushNotificationConfig` (id/taskId/url/token/authentication
  # at top level); otherwise the legacy nested `pushNotificationConfig`.
  def encode(config, true) do
    auth = if is_map(config.authentication), do: Map.delete(config.authentication, "credentials")

    %{"id" => config.id, "taskId" => config.task_id, "url" => config.url}
    |> put_unless_nil("token", config.token)
    |> put_unless_nil("authentication", auth)
    |> put_unless_nil("protocolVersion", Map.get(config, :protocol_version))
  end

  def encode(config, false) do
    auth =
      case config.authentication do
        %{} = a -> Map.delete(a, "credentials")
        nil -> nil
      end

    push =
      %{"id" => config.id, "url" => config.url}
      |> put_unless_nil("token", config.token)
      |> put_unless_nil("authentication", auth)
      |> put_v11_version(Map.get(config, :protocol_version))

    %{"taskId" => config.task_id, "pushNotificationConfig" => push}
  end

  # The legacy nested shape only reports protocolVersion for 1.1+ configs so
  # pre-1.1 callers see the exact shape they always did.
  defp put_v11_version(map, version) do
    if AshA2A.Protocol.Version.at_least?(version, "1.1"),
      do: Map.put(map, "protocolVersion", version),
      else: map
  end

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)
end
