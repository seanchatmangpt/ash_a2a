defmodule AshA2A.Protocol.JSONRPC do
  @moduledoc """
  Transport-agnostic JSON-RPC 2.0 dispatch layer for the A2A protocol.

  Defines a handler behaviour and a `handle/3` function that parses JSON-RPC
  envelopes, validates params, and dispatches to the handler module.

  ## Handler behaviour

  Three callbacks are required — every A2A server answers these methods:

      defmodule MyHandler do
        @behaviour AshA2A.Protocol.JSONRPC

        @impl true
        def handle_send(message, params, context) do
          # process the message, return {:ok, task}, {:ok, message}, or
          # {:error, error} — `SendMessageResponse` is a Task/Message oneof
        end

        @impl true
        def handle_get(task_id, params, context) do
          # look up the task
        end

        @impl true
        def handle_cancel(task_id, params, context) do
          # cancel the task
        end
      end

  Five more are optional, and each has a defined answer when absent:

  - `c:handle_list/2` serves `tasks/list`. Without it that method answers
    `-32601`, method not found.
  - `c:handle_set_push_config/3`, `c:handle_get_push_config/4`,
    `c:handle_list_push_configs/3` and `c:handle_delete_push_config/4` serve
    the four `tasks/pushNotificationConfig/*` methods. Without them those
    answer `-32003`, push notifications not supported.

  Presence is checked per request with `Code.ensure_loaded?/1` and
  `function_exported?/3`, so a handler implementing none of the optional
  callbacks behaves exactly as it did before they existed.

  ## Dispatching

      case AshA2A.Protocol.JSONRPC.handle(decoded_body, MyHandler) do
        {:reply, response_map} -> send_json(response_map)
        {:stream, method, params, id} -> start_sse(method, params, id)
      end

  The third argument to `handle/3` is a context map, threaded unchanged to
  every callback, which transports use to pass per-request data.
  """

  alias AshA2A.Protocol.ClientArtifacts
  alias AshA2A.Protocol.JSONRPC.{Error, Request, Response}

  # v0.3.0 PascalCase method names → internal slash-style names
  @method_aliases %{
    "SendMessage" => "message/send",
    "SendStreamingMessage" => "message/stream",
    "GetTask" => "tasks/get",
    "CancelTask" => "tasks/cancel",
    "SubscribeToTask" => "tasks/resubscribe",
    "ListTasks" => "tasks/list",
    "GetExtendedAgentCard" => "agent/getAuthenticatedExtendedCard",
    "CreateTaskPushNotificationConfig" => "tasks/pushNotificationConfig/set",
    "GetTaskPushNotificationConfig" => "tasks/pushNotificationConfig/get",
    "ListTaskPushNotificationConfigs" => "tasks/pushNotificationConfig/list",
    "DeleteTaskPushNotificationConfig" => "tasks/pushNotificationConfig/delete"
  }

  @type result ::
          {:reply, map()}
          | {:stream, String.t(), map(), String.t() | integer() | nil}

  @doc "Called for `message/send` and `message/stream` requests."
  @callback handle_send(AshA2A.Protocol.Message.t(), params :: map(), context :: map()) ::
              {:ok, AshA2A.Protocol.Task.t() | AshA2A.Protocol.Message.t()} | {:error, Error.t()}

  @doc "Called for `tasks/get` requests."
  @callback handle_get(task_id :: String.t(), params :: map(), context :: map()) ::
              {:ok, AshA2A.Protocol.Task.t()} | {:error, Error.t()}

  @doc "Called for `tasks/cancel` requests."
  @callback handle_cancel(task_id :: String.t(), params :: map(), context :: map()) ::
              {:ok, AshA2A.Protocol.Task.t()} | {:error, Error.t()}

  @doc "Called for `tasks/list` requests. Optional."
  @callback handle_list(params :: map(), context :: map()) ::
              {:ok, map()} | {:error, Error.t()}

  @doc "Called for `tasks/pushNotificationConfig/set` requests. Optional."
  @callback handle_set_push_config(
              AshA2A.Protocol.PushNotificationConfig.t(),
              params :: map(),
              context :: map()
            ) :: {:ok, AshA2A.Protocol.PushNotificationConfig.t()} | {:error, Error.t()}

  @doc "Called for `tasks/pushNotificationConfig/get` requests. Optional."
  @callback handle_get_push_config(
              task_id :: String.t(),
              config_id :: String.t(),
              params :: map(),
              context :: map()
            ) :: {:ok, AshA2A.Protocol.PushNotificationConfig.t()} | {:error, Error.t()}

  @doc "Called for `tasks/pushNotificationConfig/list` requests. Optional."
  @callback handle_list_push_configs(task_id :: String.t(), params :: map(), context :: map()) ::
              {:ok, [AshA2A.Protocol.PushNotificationConfig.t()]} | {:error, Error.t()}

  @doc "Called for `tasks/pushNotificationConfig/delete` requests. Optional."
  @callback handle_delete_push_config(
              task_id :: String.t(),
              config_id :: String.t(),
              params :: map(),
              context :: map()
            ) :: :ok | {:error, Error.t()}

  @optional_callbacks handle_list: 2,
                      handle_set_push_config: 3,
                      handle_get_push_config: 4,
                      handle_list_push_configs: 3,
                      handle_delete_push_config: 4

  @doc """
  Parses a JSON-RPC 2.0 request map and dispatches to the handler.

  An optional `context` map is threaded through to every handler
  callback, letting transports like `AshA2A.Protocol.Plug` pass per-request data
  (agent pid, metadata, etc.) without the process dictionary.

  Returns `{:reply, response_map}` for synchronous methods, or
  `{:stream, method, params, id}` for streaming methods.
  """
  @spec handle(map(), module(), map()) :: result()
  def handle(raw, handler, context \\ %{}) do
    with {:ok, request} <- Request.parse(raw),
         request = normalize_method(request),
         :ok <- Request.validate_params(request) do
      dispatch(request, handler, context)
    else
      {:error, %Error{} = error} ->
        id = extract_id(raw)
        {:reply, Response.error(id, error)}
    end
  end

  # -- dispatch --------------------------------------------------------------

  defp dispatch(%Request{method: "message/send"} = req, handler, ctx) do
    configuration = if is_map(req.params["configuration"]), do: req.params["configuration"], else: %{}
    history_length = Request.history_length(configuration)

    timeline_length =
      Request.timeline_length(configuration) || Request.timeline_length(req.params)

    # Handlers read the parsed SendMessageConfiguration from the context so
    # they need not re-parse the wire spelling (returnImmediately/blocking).
    ctx =
      ctx
      |> Map.put(:return_immediately, Request.return_immediately(configuration))
      |> Map.put(:accepted_output_modes, Request.accepted_output_modes(configuration))
      |> Map.put(:if_generation_match, Request.if_generation_match(configuration))

    with {:ok, decoded} <- decode_updates(req.params),
         :ok <- lift(ClientArtifacts.check_user_artifacts(card_of(ctx), decoded)),
         {:ok, message} <- decode_optional_message(req.params),
         :ok <- check_if_generation_match(ctx, message, configuration, req.params),
         {:ok, result} <- send_or_update(handler, message, decoded, req.params, ctx),
         {:ok, result} <- apply_artifact_updates(ctx, result, message, decoded),
         {:ok, encoded} <- encode_send_result(result, history_length, timeline_length) do
      {:reply, Response.success(req.id, encoded)}
    else
      {:error, %Error{} = error} -> {:reply, Response.error(req.id, error)}
    end
  end

  defp dispatch(%Request{method: "message/stream"} = req, _handler, _ctx) do
    case decode_message(req.params) do
      {:ok, message} ->
        params = Map.put(req.params, "message", message)
        {:stream, "message/stream", params, req.id}

      {:error, %Error{} = error} ->
        {:reply, Response.error(req.id, error)}
    end
  end

  defp dispatch(%Request{method: "tasks/get"} = req, handler, ctx) do
    task_id = req.params["id"]
    history_length = Request.history_length(req.params)
    timeline_length = Request.timeline_length(req.params)

    with {:ok, task} <-
           safe_call(fn -> handler.handle_get(task_id, req.params, ctx) end),
         {:ok, task} <-
           long_poll(task, handler, req.params, ctx),
         task =
           task
           |> AshA2A.Protocol.Task.truncate_history(history_length)
           |> AshA2A.Protocol.Task.Generation.truncate_timeline(timeline_length)
           |> AshA2A.Protocol.Task.strip_stream_metadata(),
         {:ok, encoded} <- AshA2A.Protocol.JSON.encode(task) do
      {:reply, Response.success(req.id, encoded)}
    else
      {:error, %Error{} = error} -> {:reply, Response.error(req.id, error)}
    end
  end

  defp dispatch(%Request{method: "tasks/cancel"} = req, handler, ctx) do
    task_id = req.params["id"]

    with {:ok, task} <-
           safe_call(fn -> handler.handle_cancel(task_id, req.params, ctx) end),
         {:ok, encoded} <- AshA2A.Protocol.JSON.encode(AshA2A.Protocol.Task.strip_stream_metadata(task)) do
      {:reply, Response.success(req.id, encoded)}
    else
      {:error, %Error{} = error} -> {:reply, Response.error(req.id, error)}
    end
  end

  defp dispatch(%Request{method: "tasks/list"} = req, handler, ctx) do
    if exports?(handler, :handle_list, 2) do
      case safe_call(fn -> handler.handle_list(req.params, ctx) end) do
        {:ok, result} ->
          timeline_length = Request.timeline_length(req.params)
          {:reply, Response.success(req.id, encode_list_result(result, timeline_length))}

        {:error, %Error{} = error} -> {:reply, Response.error(req.id, error)}
      end
    else
      {:reply, Response.error(req.id, Error.method_not_found(req.method))}
    end
  end

  defp dispatch(%Request{method: "tasks/resubscribe"} = req, _handler, _ctx) do
    {:stream, "tasks/resubscribe", req.params, req.id}
  end

  defp dispatch(%Request{method: "tasks/pushNotificationConfig/set"} = req, handler, ctx) do
    if exports?(handler, :handle_set_push_config, 3) do
      with {:ok, config} <- decode_push_config(req.params),
           {:ok, stored} <-
             safe_call(fn -> handler.handle_set_push_config(config, req.params, ctx) end),
           {:ok, encoded} <- AshA2A.Protocol.JSON.encode(stored) do
        {:reply, Response.success(req.id, encoded)}
      else
        {:error, %Error{} = error} -> {:reply, Response.error(req.id, error)}
      end
    else
      {:reply, Response.error(req.id, Error.push_notification_not_supported())}
    end
  end

  defp dispatch(%Request{method: "tasks/pushNotificationConfig/get"} = req, handler, ctx) do
    if exports?(handler, :handle_get_push_config, 4) do
      task_id = push_task_id(req.params)
      config_id = req.params["id"]

      with {:ok, config} <-
             safe_call(fn ->
               handler.handle_get_push_config(task_id, config_id, req.params, ctx)
             end),
           {:ok, encoded} <- AshA2A.Protocol.JSON.encode(config) do
        {:reply, Response.success(req.id, encoded)}
      else
        {:error, %Error{} = error} -> {:reply, Response.error(req.id, error)}
      end
    else
      {:reply, Response.error(req.id, Error.push_notification_not_supported())}
    end
  end

  defp dispatch(%Request{method: "tasks/pushNotificationConfig/list"} = req, handler, ctx) do
    if exports?(handler, :handle_list_push_configs, 3) do
      task_id = push_task_id(req.params)

      case safe_call(fn -> handler.handle_list_push_configs(task_id, req.params, ctx) end) do
        {:ok, configs} ->
          case paginate_push_configs(configs, req.params) do
            {:ok, page, next_token} ->
              encoded = Enum.map(page, &AshA2A.Protocol.JSON.encode!/1)

              result =
                if next_token,
                  do: %{"configs" => encoded, "nextPageToken" => next_token},
                  else: %{"configs" => encoded}

              {:reply, Response.success(req.id, result)}

            {:error, %Error{} = error} ->
              {:reply, Response.error(req.id, error)}
          end

        {:error, %Error{} = error} ->
          {:reply, Response.error(req.id, error)}
      end
    else
      {:reply, Response.error(req.id, Error.push_notification_not_supported())}
    end
  end

  defp dispatch(%Request{method: "tasks/pushNotificationConfig/delete"} = req, handler, ctx) do
    if exports?(handler, :handle_delete_push_config, 4) do
      task_id = push_task_id(req.params)
      config_id = req.params["id"]

      # `safe_call/1` only understands ok/error tuples; delete answers a bare
      # `:ok`, so normalize inside the closure to keep its rescue in play.
      result =
        safe_call(fn ->
          case handler.handle_delete_push_config(task_id, config_id, req.params, ctx) do
            :ok -> {:ok, %{}}
            other -> other
          end
        end)

      case result do
        {:ok, _} -> {:reply, Response.success(req.id, %{})}
        {:error, %Error{} = error} -> {:reply, Response.error(req.id, error)}
      end
    else
      {:reply, Response.error(req.id, Error.push_notification_not_supported())}
    end
  end

  defp dispatch(
         %Request{method: "agent/getAuthenticatedExtendedCard"} = req,
         _handler,
         _ctx
       ) do
    # Not configured here: the extended card is served by transports that
    # carry a provider. A bare dispatcher answers the spec's dedicated
    # ExtendedAgentCardNotConfigured error (-32007), not the generic -32004.
    {:reply, Response.error(req.id, Error.authenticated_extended_card_not_configured())}
  end

  defp dispatch(%Request{} = req, _handler, _ctx) do
    {:reply, Response.error(req.id, Error.method_not_found(req.method))}
  end

  # -- helpers ---------------------------------------------------------------

  # `ListTaskPushNotificationConfigs` paging: `pageSize` / `pageToken` in,
  # `nextPageToken` out. The token is an opaque base64 offset; a malformed
  # token is -32602, never a silent restart from the first page.
  defp paginate_push_configs(configs, params) do
    size = params["pageSize"]
    token = params["pageToken"]

    with {:ok, offset} <- decode_page_token(token) do
      rest = Enum.drop(configs, offset)

      case size do
        size when is_integer(size) and size > 0 ->
          {page, remaining} = Enum.split(rest, size)

          next =
            if remaining == [],
              do: nil,
              else: Base.url_encode64(Integer.to_string(offset + size), padding: false)

          {:ok, page, next}

        _ ->
          {:ok, rest, nil}
      end
    end
  end

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

  # The spec and REST binding use `taskId`; the TCK and proto clients send
  # `task_id`. Both are accepted, as they already are for `historyLength`.
  defp push_task_id(params), do: params["taskId"] || params["task_id"]

  # v1.0 sends the config flat on params; v0.3 nests it under
  # `pushNotificationConfig`. `taskId` always lives on params either way.
  defp decode_push_config(params) do
    source =
      case Map.get(params, "pushNotificationConfig") do
        config when is_map(config) -> config
        _ -> params
      end

    source = Map.put(source, "taskId", push_task_id(params))

    case AshA2A.Protocol.JSON.decode(source, :push_notification_config) do
      {:ok, _config} = ok -> ok
      {:error, reason} -> {:error, Error.invalid_params(inspect(reason))}
    end
  end

  # -- v1.1.0 helpers --------------------------------------------------------

  # Tagged errors (`:generation_mismatch`, `{:unsupported_operation, _}`) ->
  # `Error` structs; `Error` structs and `:ok` pass through.
  defp lift(:ok), do: :ok
  defp lift({:error, %Error{}} = error), do: error

  defp lift({:error, reason}) do
    case ClientArtifacts.to_error(reason) do
      %Error{} = error -> {:error, error}
      nil -> {:error, Error.internal_error()}
    end
  end

  defp decode_updates(params) do
    case Request.artifact_updates(params) do
      [] ->
        {:ok, []}

      updates ->
        case ClientArtifacts.decode_updates(updates) do
          {:ok, _} = ok -> ok
          {:error, reason} -> {:error, Error.invalid_params(inspect(reason))}
        end
    end
  end

  defp decode_optional_message(%{"message" => nil}), do: {:ok, nil}
  defp decode_optional_message(%{"message" => m} = params) when is_map(m), do: decode_message(params)
  defp decode_optional_message(_params), do: {:ok, nil}

  defp card_of(%{agent_card: card}) when not is_nil(card), do: card

  defp card_of(%{agent: agent}) when not is_nil(agent) do
    GenServer.call(agent, :get_agent_card)
  catch
    :exit, _ -> nil
  end

  defp card_of(_), do: nil

  defp fetch_task(%{agent: agent}, task_id) when not is_nil(agent) and is_binary(task_id) do
    GenServer.call(agent, {:get_task, task_id})
  catch
    :exit, _ -> {:error, :not_found}
  end

  defp fetch_task(_ctx, _task_id), do: {:error, :not_found}

  # ifGenerationMatch applies only to a message targeting an EXISTING task.
  defp check_if_generation_match(ctx, message, configuration, params) do
    expected = Request.if_generation_match(configuration)

    # Message-less (artifact-only) send: the target is the single taskId the
    # artifactUpdates name.
    target_id =
      cond do
        not is_nil(message) -> message.task_id
        true -> artifact_only_task_id(params)
      end

    with true <- not is_nil(expected) and is_binary(target_id),
         {:ok, task} <- fetch_task(ctx, target_id) do
      case ClientArtifacts.check_generation(task, expected) do
        :ok ->
          :ok

        {:error, :generation_mismatch} ->
          {:error,
           Error.task_generation_mismatch(nil,
             task_id: task.id,
             expected: expected,
             actual: AshA2A.Protocol.Task.Generation.generation_of(task)
           )}
      end
    else
      _ -> :ok
    end
  end

  defp artifact_only_task_id(params) do
    params
    |> Request.artifact_updates()
    |> Enum.map(&(&1["taskId"] || &1["task_id"]))
    |> Enum.uniq()
    |> case do
      [task_id] when is_binary(task_id) -> task_id
      _ -> nil
    end
  end

  # Artifact-only send: no message, updates target an existing task. The
  # handler's `handle_get/3` is the authorization gate for that task.
  defp send_or_update(handler, nil, decoded, params, ctx) do
    ids =
      params
      |> Request.artifact_updates()
      |> Enum.map(&(&1["taskId"] || &1["task_id"]))
      |> Enum.uniq()

    case {ids, decoded} do
      {[task_id], [_ | _]} ->
        with {:ok, _task} <- safe_call(fn -> handler.handle_get(task_id, params, ctx) end) do
          {:ok, {:artifact_only, task_id}}
        end

      _ ->
        {:error, Error.invalid_params("artifactUpdates without a message must name one taskId")}
    end
  end

  defp send_or_update(handler, message, _decoded, params, ctx) do
    safe_call(fn -> handler.handle_send(message, params, ctx) end)
  end

  defp apply_artifact_updates(_ctx, result, _message, []) when not is_tuple(result), do: {:ok, result}

  defp apply_artifact_updates(ctx, {:artifact_only, task_id}, _message, decoded) do
    apply_to_agent(ctx, task_id, decoded, true)
  end

  # A direct Message reply creates no task: updates are not persisted.
  defp apply_artifact_updates(_ctx, %AshA2A.Protocol.Message{} = result, _message, _decoded),
    do: {:ok, result}

  defp apply_artifact_updates(ctx, %AshA2A.Protocol.Task{id: id}, _message, decoded),
    do: apply_to_agent(ctx, id, decoded, false)

  # The artifact-only path rechecks ifGenerationMatch inside the serialized
  # agent (4-tuple call); a message+artifact send already passed the
  # pre-check against the pre-message generation, so it applies unguarded.
  defp apply_to_agent(%{agent: agent} = ctx, task_id, decoded, guard?) when not is_nil(agent) do
    expected = if guard?, do: Map.get(ctx, :if_generation_match)

    case GenServer.call(agent, {:apply_artifact_updates, task_id, decoded, expected}) do
      {:ok, _task} = ok -> ok
      {:error, :not_found} -> {:error, Error.task_not_found()}
      {:error, _} = error -> lift(error)
    end
  end

  defp apply_to_agent(_ctx, _task_id, _decoded, _guard?),
    do: {:error, Error.unsupported_operation("artifactUpdates need an agent in context")}

  # GetTask `currentGeneration` long-poll: answer now when the task is already
  # past the value (or terminal); otherwise hold on the agent's task-update
  # notifications (`{:a2a_task_event, id, snapshot}`) until the generation
  # advances or the monotonic deadline passes, then answer the current state.
  defp long_poll(task, handler, params, ctx) do
    value = Request.current_generation(params)
    gen = AshA2A.Protocol.Task.Generation.generation_of(task)

    if is_nil(value) or gen > value or AshA2A.Protocol.Task.terminal?(task) or
         is_nil(Map.get(ctx, :agent)) do
      {:ok, task}
    else
      timeout = ClientArtifacts.long_poll_timeout_ms(Map.get(ctx, :long_poll_timeout_ms))
      deadline = System.monotonic_time(:millisecond) + timeout
      await_generation(ctx.agent, task.id, value, deadline)
      safe_call(fn -> handler.handle_get(task.id, params, ctx) end)
    end
  end

  defp await_generation(agent, task_id, value, deadline) do
    case GenServer.call(agent, {:subscribe, task_id}) do
      {:ok, snapshot} ->
        if AshA2A.Protocol.Task.Generation.generation_of(snapshot) > value,
          do: :advanced,
          else: receive_generation(task_id, value, deadline)

      _terminal_or_missing ->
        :done
    end
  catch
    :exit, _ -> :done
  end

  defp receive_generation(task_id, value, deadline) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {:a2a_task_event, ^task_id, snapshot} ->
        if AshA2A.Protocol.Task.Generation.generation_of(snapshot) > value,
          do: :advanced,
          else: receive_generation(task_id, value, deadline)
    after
      remaining -> :timeout
    end
  end

  defp decode_message(params) do
    case AshA2A.Protocol.JSON.decode(params["message"], :message) do
      {:ok, _message} = ok -> ok
      {:error, reason} -> {:error, Error.invalid_params(inspect(reason))}
    end
  end

  # `SendMessageResponse` is a Task/Message oneof. `historyLength` and the
  # `:stream` metadata key are task-only — a Message has neither field.
  defp encode_send_result(%AshA2A.Protocol.Task{} = task, history_length, timeline_length) do
    with {:ok, encoded} <-
           task
           |> AshA2A.Protocol.Task.truncate_history(history_length)
           |> AshA2A.Protocol.Task.Generation.truncate_timeline(timeline_length)
           |> AshA2A.Protocol.Task.strip_stream_metadata()
           |> AshA2A.Protocol.JSON.encode() do
      {:ok, %{"task" => encoded}}
    end
  end

  defp encode_send_result(%AshA2A.Protocol.Message{} = message, _history_length, _timeline_length) do
    with {:ok, encoded} <- AshA2A.Protocol.JSON.encode(message) do
      {:ok, %{"message" => encoded}}
    end
  end

  defp encode_list_result(%{tasks: tasks} = result, timeline_length) do
    encoded_tasks =
      Enum.map(tasks, fn task ->
        task
        |> AshA2A.Protocol.Task.Generation.truncate_timeline(timeline_length)
        |> AshA2A.Protocol.Task.strip_stream_metadata()
        |> AshA2A.Protocol.JSON.encode!()
      end)

    %{
      "tasks" => encoded_tasks,
      "totalSize" => result.total_size,
      "pageSize" => result.page_size,
      "nextPageToken" => result.next_page_token
    }
  end

  # `function_exported?/3` answers false for a module that has not been loaded
  # yet, which under lazy loading silently downgrades a supported method to
  # "unsupported". Force the load before asking.
  defp exports?(handler, fun, arity) do
    Code.ensure_loaded?(handler) and function_exported?(handler, fun, arity)
  end

  # SEC-08: a handler crash must not echo `Exception.message/1` (internal
  # detail: SQL text, file paths, secret-bearing config) onto the wire. The
  # caller gets -32603 with an opaque `ref`; the full detail is logged
  # server-side under the same ref.
  defp safe_call(fun) do
    case fun.() do
      {:ok, _} = ok -> ok
      {:error, %Error{}} = err -> err
    end
  rescue
    e ->
      %{ref: ref} = AshA2A.Transport.SafeError.internal(:internal_error, e, __STACKTRACE__)
      {:error, Error.internal_error(%{"ref" => ref})}
  end

  defp normalize_method(%Request{method: method} = request) do
    case Map.get(@method_aliases, method) do
      nil -> request
      canonical -> %{request | method: canonical}
    end
  end

  defp extract_id(%{"id" => id}) when is_binary(id) or is_integer(id), do: id
  defp extract_id(_), do: nil
end
