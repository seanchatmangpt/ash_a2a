defmodule AshA2A.Protocol.Agent.State do
  @moduledoc false

  @type push_key :: {String.t(), String.t()}

  @type t :: %__MODULE__{
          module: module(),
          tasks: %{String.t() => AshA2A.Protocol.Task.t()},
          contexts: %{String.t() => [String.t()]},
          push_configs: %{push_key() => AshA2A.Protocol.PushNotificationConfig.t()},
          task_store: {module(), AshA2A.Protocol.TaskStore.ref()} | nil,
          push_sender: {module(), keyword()} | nil,
          subscribers: %{String.t() => [{pid(), reference()}]}
        }

  defstruct module: nil,
            tasks: %{},
            contexts: %{},
            push_configs: %{},
            task_store: nil,
            push_sender: nil,
            subscribers: %{}

  @doc """
  Registers `pid` as a subscriber to `task_id`, monitoring it.

  The monitor is the whole cleanup story: a subscriber is an SSE connection
  process, and when the client disconnects that process dies and takes its
  registration with it.
  """
  @spec add_subscriber(t(), String.t(), pid()) :: t()
  def add_subscriber(state, task_id, pid) do
    ref = Process.monitor(pid)
    entries = Map.get(state.subscribers, task_id, [])
    %{state | subscribers: Map.put(state.subscribers, task_id, [{pid, ref} | entries])}
  end

  @doc """
  Removes the subscriber registered under `ref`, wherever it is registered.
  """
  @spec drop_subscriber(t(), reference()) :: t()
  def drop_subscriber(state, ref) do
    subscribers =
      state.subscribers
      |> Enum.map(fn {task_id, entries} ->
        {task_id, Enum.reject(entries, fn {_pid, entry_ref} -> entry_ref == ref end)}
      end)
      |> Enum.reject(fn {_task_id, entries} -> entries == [] end)
      |> Map.new()

    %{state | subscribers: subscribers}
  end

  @doc """
  Drops every subscriber of `task_id`, demonitoring each.

  Used once a task is terminal: the stream is over, so the registrations
  would otherwise linger until each connection happened to close.
  """
  @spec drop_subscribers(t(), String.t()) :: t()
  def drop_subscribers(state, task_id) do
    for {_pid, ref} <- Map.get(state.subscribers, task_id, []) do
      Process.demonitor(ref, [:flush])
    end

    %{state | subscribers: Map.delete(state.subscribers, task_id)}
  end

  @doc """
  The pids subscribed to `task_id`.
  """
  @spec subscribers_for(t(), String.t()) :: [pid()]
  def subscribers_for(state, task_id) do
    for {pid, _ref} <- Map.get(state.subscribers, task_id, []), do: pid
  end

  @doc """
  Transitions a task to a new state, updating the status.
  """
  @spec transition(
          AshA2A.Protocol.Task.t(),
          AshA2A.Protocol.Task.Status.state(),
          AshA2A.Protocol.Message.t() | nil
        ) ::
          AshA2A.Protocol.Task.t()
  def transition(task, new_state, message \\ nil) do
    old_state = if task.status, do: task.status.state

    case AshA2A.TaskLifecycle.check_transition(old_state, new_state) do
      :ok -> do_transition(task, old_state, new_state, message)
      {:error, reason} -> refuse_transition(task, old_state, new_state, reason)
    end
  end

  # A terminal task is never moved to a different state: the refusal leaves
  # the task untouched and is observable on telemetry.
  defp refuse_transition(task, old_state, new_state, reason) do
    :telemetry.execute(
      [:a2a, :task, :transition_refused],
      %{system_time: System.system_time()},
      %{task_id: task.id, from: old_state, to: new_state, reason: reason}
    )

    task
  end

  defp do_transition(task, old_state, new_state, message) do
    task =
      AshA2A.Protocol.Task.Generation.append_status(
        task,
        AshA2A.Protocol.Task.Status.new(new_state, message)
      )

    :telemetry.execute(
      [:a2a, :task, :transition],
      %{system_time: System.system_time()},
      %{
        task_id: task.id,
        context_id: task.context_id,
        from: old_state,
        to: new_state
      }
    )

    task
  end

  @doc """
  Stores a task in the internal state map and optionally in the external store.
  """
  @spec put_task(t(), AshA2A.Protocol.Task.t()) :: t()
  def put_task(state, task) do
    case put_task_checked(state, task) do
      {:ok, state} ->
        state

      {:error, _reason} ->
        # Legacy unchecked path: memory is updated, the failure is on telemetry.
        %{state | tasks: Map.put(state.tasks, task.id, task)}
    end
  end

  @doc """
  Like `put_task/2`, but checks the store's return. A store `{:error, _}`
  (or a raising store such as `AshA2A.TaskStore.Ekv`) yields
  `{:error, {:store_write_failed, reason}}` and the in-memory map is NOT
  updated, so an unpersisted task is never acknowledged.
  """
  @spec put_task_checked(t(), AshA2A.Protocol.Task.t()) :: {:ok, t()} | {:error, term()}
  def put_task_checked(%{task_store: {mod, ref}} = state, task) do
    case safe_store_put(mod, ref, task) do
      :ok ->
        {:ok, %{state | tasks: Map.put(state.tasks, task.id, task)}}

      {:error, reason} ->
        :telemetry.execute([:a2a, :task_store, :put_failed], %{count: 1}, %{
          task_id: task.id,
          reason: reason
        })

        {:error, {:store_write_failed, reason}}
    end
  end

  def put_task_checked(state, task) do
    {:ok, %{state | tasks: Map.put(state.tasks, task.id, task)}}
  end

  defp safe_store_put(mod, ref, task) do
    case mod.put(ref, task) do
      :ok -> :ok
      {:error, _} = error -> error
      other -> {:error, {:unexpected_return, other}}
    end
  rescue
    error -> {:error, {:raised, Exception.message(error)}}
  catch
    kind, value -> {:error, {kind, value}}
  end

  @doc """
  Retrieves a task, checking the external store first if configured.
  """
  @spec get_task(t(), String.t()) :: {:ok, AshA2A.Protocol.Task.t()} | {:error, :not_found}
  def get_task(%{task_store: {mod, ref}} = state, task_id) do
    case Map.fetch(state.tasks, task_id) do
      {:ok, task} ->
        {:ok, task}

      :error ->
        case mod.get(ref, task_id) do
          {:ok, _} = ok -> ok
          _ -> {:error, :not_found}
        end
    end
  end

  def get_task(state, task_id) do
    case Map.fetch(state.tasks, task_id) do
      {:ok, task} -> {:ok, task}
      :error -> {:error, :not_found}
    end
  end

  @doc """
  Tracks a task under its context_id.
  """
  @spec track_context(t(), AshA2A.Protocol.Task.t()) :: t()
  def track_context(state, %{context_id: nil}), do: state

  def track_context(state, %{context_id: ctx_id, id: task_id}) do
    # dual-safe Map.update (absent key stores default unmodified)
    contexts =
      case Map.fetch(state.contexts, ctx_id) do
        :error -> Map.put(state.contexts, ctx_id, [task_id])
        {:ok, prior} -> Map.put(state.contexts, ctx_id, [task_id | prior])
      end

    %{state | contexts: contexts}
  end

  @doc """
  Lists tasks with filtering/pagination. Delegates to external store if
  it supports `list_all/2`, otherwise uses the in-memory task map.
  """
  @spec list_tasks(t(), map()) :: {:ok, map()}
  def list_tasks(%{task_store: {mod, ref}} = state, params) do
    if exports?(mod, :list_all, 2) do
      mod.list_all(ref, params_to_list_opts(params))
    else
      list_from_memory(state, params)
    end
  end

  def list_tasks(state, params) do
    list_from_memory(state, params)
  end

  @doc """
  Stores a push notification config.

  When the store does not implement the push callbacks, configs live in the
  agent's in-memory map and are NOT durable (lost on agent restart); that
  fallback is typed on telemetry `[:a2a, :push_config, :volatile]`. Uses the external store when it implements the push callbacks, the in-memory
  map otherwise — one or the other, never both. A store may be shared between
  agents, so caching configs alongside it would let one agent's stale copy
  shadow another's delete and keep a removed webhook alive.
  """
  @spec put_push_config(t(), AshA2A.Protocol.PushNotificationConfig.t()) ::
          {t(), {:ok, AshA2A.Protocol.PushNotificationConfig.t()} | {:error, term()}}
  def put_push_config(%{task_store: {mod, ref}} = state, config) do
    if exports?(mod, :set_push_config, 2) do
      {state, mod.set_push_config(ref, config)}
    else
      put_push_config_in_memory(state, config)
    end
  end

  def put_push_config(state, config), do: put_push_config_in_memory(state, config)

  @doc """
  Retrieves a push notification config by task ID and config ID.
  """
  @spec get_push_config(t(), String.t(), String.t()) ::
          {:ok, AshA2A.Protocol.PushNotificationConfig.t()} | {:error, :not_found}
  def get_push_config(%{task_store: {mod, ref}} = state, task_id, config_id) do
    if exports?(mod, :get_push_config, 3) do
      mod.get_push_config(ref, task_id, config_id)
    else
      get_push_config_in_memory(state, task_id, config_id)
    end
  end

  def get_push_config(state, task_id, config_id) do
    get_push_config_in_memory(state, task_id, config_id)
  end

  @doc """
  Lists every push notification config registered for a task.
  """
  @spec list_push_configs(t(), String.t()) :: {:ok, [AshA2A.Protocol.PushNotificationConfig.t()]}
  def list_push_configs(%{task_store: {mod, ref}} = state, task_id) do
    if exports?(mod, :list_push_configs, 2) do
      mod.list_push_configs(ref, task_id)
    else
      list_push_configs_in_memory(state, task_id)
    end
  end

  def list_push_configs(state, task_id), do: list_push_configs_in_memory(state, task_id)

  @doc """
  Deletes a push notification config. Idempotent.
  """
  @spec delete_push_config(t(), String.t(), String.t()) :: {t(), :ok}
  def delete_push_config(%{task_store: {mod, ref}} = state, task_id, config_id) do
    if exports?(mod, :delete_push_config, 3) do
      {state, mod.delete_push_config(ref, task_id, config_id)}
    else
      delete_push_config_in_memory(state, task_id, config_id)
    end
  end

  def delete_push_config(state, task_id, config_id) do
    delete_push_config_in_memory(state, task_id, config_id)
  end

  defp put_push_config_in_memory(state, config) do
    :telemetry.execute([:a2a, :push_config, :volatile], %{count: 1}, %{
      task_id: config.task_id,
      config_id: config.id
    })

    key = {config.task_id, config.id}
    {%{state | push_configs: Map.put(state.push_configs, key, config)}, {:ok, config}}
  end

  defp get_push_config_in_memory(state, task_id, config_id) do
    case Map.fetch(state.push_configs, {task_id, config_id}) do
      {:ok, config} -> {:ok, config}
      :error -> {:error, :not_found}
    end
  end

  defp list_push_configs_in_memory(state, task_id) do
    configs =
      state.push_configs
      |> Enum.filter(fn {{tid, _config_id}, _config} -> tid == task_id end)
      |> Enum.map(fn {_key, config} -> config end)

    {:ok, configs}
  end

  defp delete_push_config_in_memory(state, task_id, config_id) do
    {%{state | push_configs: Map.delete(state.push_configs, {task_id, config_id})}, :ok}
  end

  # See the note on `AshA2A.Protocol.JSONRPC.exports?/3`: an unloaded store module would
  # otherwise read as one that implements no optional callbacks.
  defp exports?(mod, fun, arity) do
    Code.ensure_loaded?(mod) and function_exported?(mod, fun, arity)
  end

  defp list_from_memory(state, params) do
    state.tasks
    |> Map.values()
    |> AshA2A.Protocol.Task.Filter.apply(params_to_list_opts(params))
  end

  defp decode_state(str) do
    case AshA2A.Protocol.JSON.decode_state(str) do
      # TASK_STATE_UNSPECIFIED (proto zero value) means "no status filter".
      {:ok, :unknown} -> nil
      {:ok, atom} -> atom
      {:error, _} -> nil
    end
  end

  defp list_history_length(params) do
    case AshA2A.Protocol.JSONRPC.Request.history_length(params) do
      n when is_integer(n) and n >= 0 -> n
      _ -> 0
    end
  end

  defp parse_datetime(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp params_to_list_opts(params) do
    status_atom =
      case params["status"] do
        nil -> nil
        s -> decode_state(s)
      end

    timestamp_after =
      case params["statusTimestampAfter"] do
        nil -> nil
        s -> parse_datetime(s)
      end

    [
      context_id: params["contextId"],
      status: status_atom,
      status_timestamp_after: timestamp_after,
      page_size: params["pageSize"] || 50,
      page_token: params["pageToken"],
      # ListTasksRequest.history_length: unset keeps the default (0 = clear
      # history); N keeps the last N entries per returned task.
      history_length: list_history_length(params),
      # v1.1 ListTasksRequest.timeline_length: unset keeps the whole timeline.
      timeline_length:
        case params["timelineLength"] do
          n when is_integer(n) and n >= 0 -> n
          _ -> nil
        end,
      include_artifacts: params["includeArtifacts"] || false
    ]
  end
end
