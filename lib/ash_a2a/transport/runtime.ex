defmodule AshA2A.Transport.Runtime do
  @moduledoc """
  Execution runtime behind every `use AshA2A.Agent` GenServer: task
  ownership, admission limits, and off-mailbox execution.

  `A2A.Agent`'s own `handle_call({:message, ...})` runs the handler inside the
  agent GenServer and continues a task under the *stored* task metadata. Both
  are production hazards, so `AshA2A.Agent` overrides that clause and routes
  it here:

    * **Ownership (SEC-01).** A task records its owner key
      (`AshA2A.Transport.Principal`) at creation. Continuing a task
      (`task_id:`) with a different verified principal is refused as
      `{:error, :not_found}` -- identical to an unknown id, so the refusal does
      not reveal that the task exists. On a matching principal the stored
      `"a2a.auth"` is rebound to the *current* call's verified auth, so a
      continuation never runs under stale or foreign credentials. Task ids
      come from `:crypto.strong_rand_bytes/1` (128 bits), not `Enum.random/1`.
    * **Off-mailbox execution (SEC-03).** In the default `:async` mode the
      handler runs in a monitored worker process; the agent marks the task
      `:working`, keeps serving `tasks/get`/`tasks/list`/`tasks/cancel`, and
      replies to the original caller with `GenServer.reply/2` when the worker
      finishes. A worker that crashes or is killed fails only its own task
      with a typed `internal_error` + ref (SEC-02); the agent and every other
      task survive. `mode: :inline` restores the serialized in-process
      behavior. `tasks/cancel` on a task whose handler is still running is
      refused `:not_cancelable` (the same answer the serialized runtime gave,
      where a cancel could only arrive after the run finished): the handler
      may already have crossed a consequence boundary, so reporting the task
      `:canceled` while its effect commits would be a false standing.
    * **Admission limits (SEC-03).** A global in-flight cap
      (`max_in_flight`, default 256) refuses with `%{code: :server_busy}`, and
      an optional per-principal token bucket (`rate_limit: {count, per_ms}`,
      default off) refuses with `%{code: :rate_limited}`. Both refuse before
      any task is created.

  Configuration: `config :ash_a2a, :execution, mode: :async, max_in_flight:
  256, rate_limit: nil`, overridden per agent with `use AshA2A.Agent,
  execution: [...]`.
  """

  require Logger

  alias A2A.Agent.State
  alias AshA2A.Transport.{Principal, SafeError}

  @owner_key "ash_a2a.owner"
  @in_flight_key :ash_a2a_in_flight
  @buckets_key :ash_a2a_rate_buckets
  @max_buckets 10_000

  @defaults [mode: :async, max_in_flight: 256, rate_limit: nil]

  @doc "Typed refusal codes returned by this runtime, classified for S42 totality."
  @spec __sa2a_refusal_codes__() :: %{atom() => atom()}
  def __sa2a_refusal_codes__ do
    %{
      server_busy: :blocked_resource,
      rate_limited: :refused_bounds,
      task_in_progress: :refused_plan,
      not_continuable: :refused_plan
    }
  end

  @doc "Metadata key holding a task's owner principal key."
  @spec owner_key() :: String.t()
  def owner_key, do: @owner_key

  @doc "Effective execution config: defaults <- app env <- per-agent opts."
  @spec config(keyword()) :: keyword()
  def config(agent_opts) do
    @defaults
    |> Keyword.merge(Application.get_env(:ash_a2a, :execution, []))
    |> Keyword.merge(agent_opts || [])
  end

  @doc "CSPRNG task id (`tsk-` + 128 random bits, url-safe base64)."
  @spec secure_task_id() :: String.t()
  def secure_task_id do
    "tsk-" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
  end

  @doc "Owner key recorded on `task`, or `:anonymous`."
  @spec owner(A2A.Task.t()) :: Principal.key()
  def owner(%A2A.Task{metadata: metadata}) when is_map(metadata) do
    case Map.get(metadata, @owner_key) do
      key when is_binary(key) -> key
      _ -> Principal.from_metadata(metadata)
    end
  end

  def owner(_task), do: :anonymous

  @doc "Whether `principal` may see/act on `task`."
  @spec owned_by?(A2A.Task.t(), Principal.key()) :: boolean()
  def owned_by?(task, principal), do: owner(task) == principal

  @doc """
  Removes transport-internal metadata (verified auth, owner key, stream ref)
  from a task before it is encoded onto the wire.
  """
  @spec wire_task(A2A.Task.t()) :: A2A.Task.t()
  def wire_task(%A2A.Task{metadata: metadata} = task) when is_map(metadata) do
    %{task | metadata: Map.drop(metadata, ["a2a.auth", @owner_key, :stream])}
  end

  def wire_task(task), do: task

  # -- :message ------------------------------------------------------------

  @doc false
  @spec handle_message_call(
          module(),
          keyword(),
          A2A.Message.t(),
          keyword(),
          GenServer.from(),
          State.t()
        ) ::
          {:reply, term(), State.t()} | {:noreply, State.t()}
  def handle_message_call(module, agent_opts, message, opts, from, state) do
    config = config(agent_opts)
    metadata = call_metadata(opts)
    caller = Principal.from_metadata(metadata)

    with :ok <- check_rate(caller, config),
         :ok <- check_capacity(config),
         {:ok, task, message} <- prepare_task(message, opts, metadata, caller, state) do
      task = State.transition(task, :working)
      state = state |> State.put_task(task) |> State.track_context(task)

      case Keyword.get(config, :mode) do
        :inline ->
          reply = run_handler(module, message, context(task))
          finish(task.id, from, reply, state, :inline)

        _async ->
          spawn_worker(module, message, task, from)
          {:noreply, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp call_metadata(opts) do
    case Keyword.get(opts, :metadata) do
      %{} = metadata -> metadata
      _ -> %{}
    end
  end

  defp prepare_task(message, opts, metadata, caller, state) do
    case Keyword.get(opts, :task_id) do
      nil ->
        metadata = put_owner(metadata, caller)

        task =
          A2A.Task.new(
            id: secure_task_id(),
            context_id: Keyword.get(opts, :context_id),
            metadata: metadata
          )

        {:ok, %{task | history: [message]}, message}

      task_id ->
        continue(task_id, message, metadata, caller, state)
    end
  end

  defp continue(task_id, message, metadata, caller, state) do
    with {:ok, task} <- State.get_task(state, task_id),
         :ok <- ensure(owned_by?(task, caller), :not_found),
         :ok <- ensure(not A2A.Task.terminal?(task), :not_continuable),
         :ok <- ensure(task.status.state != :working, %{code: :task_in_progress}) do
      task_metadata =
        task.metadata
        |> Map.delete(:stream)
        |> rebind_auth(metadata)

      {:ok, %{task | history: task.history ++ [message], metadata: task_metadata}, message}
    end
  end

  defp ensure(true, _reason), do: :ok
  defp ensure(false, reason), do: {:error, reason}

  # The continuation runs under the CURRENT call's verified auth (same
  # principal, possibly refreshed credentials) -- never the stored one.
  defp rebind_auth(task_metadata, call_metadata) do
    case Map.fetch(call_metadata, "a2a.auth") do
      {:ok, auth} -> Map.put(task_metadata, "a2a.auth", auth)
      :error -> Map.delete(task_metadata, "a2a.auth")
    end
  end

  defp put_owner(metadata, :anonymous), do: Map.delete(metadata, @owner_key)
  defp put_owner(metadata, key), do: Map.put(metadata, @owner_key, key)

  defp context(task) do
    %{
      task_id: task.id,
      context_id: task.context_id,
      history: task.history,
      metadata: Map.delete(task.metadata, @owner_key)
    }
  end

  # -- admission limits ------------------------------------------------------

  defp check_capacity(config) do
    max = Keyword.get(config, :max_in_flight)

    if is_integer(max) and map_size(in_flight()) >= max,
      do: {:error, %{code: :server_busy}},
      else: :ok
  end

  defp check_rate(caller, config) do
    case Keyword.get(config, :rate_limit) do
      {capacity, per_ms} when is_integer(capacity) and capacity > 0 and per_ms > 0 ->
        take_token(caller, capacity, per_ms)

      _off ->
        :ok
    end
  end

  defp take_token(caller, capacity, per_ms) do
    now = System.monotonic_time(:millisecond)
    buckets = Process.get(@buckets_key, %{})
    {tokens, last} = Map.get(buckets, caller, {capacity * 1.0, now})
    tokens = min(capacity * 1.0, tokens + (now - last) * capacity / per_ms)

    {result, tokens} =
      if tokens >= 1.0, do: {:ok, tokens - 1.0}, else: {{:error, %{code: :rate_limited}}, tokens}

    buckets = Map.put(buckets, caller, {tokens, now})

    buckets =
      if map_size(buckets) > @max_buckets,
        do: prune(buckets, capacity, per_ms, now),
        else: buckets

    Process.put(@buckets_key, buckets)
    result
  end

  defp prune(buckets, capacity, per_ms, now) do
    Map.reject(buckets, fn {_k, {tokens, last}} ->
      tokens + (now - last) * capacity / per_ms >= capacity
    end)
  end

  # -- worker ----------------------------------------------------------------

  defp in_flight, do: Process.get(@in_flight_key, %{})

  defp spawn_worker(module, message, task, from) do
    parent = self()
    callers = [parent | Process.get(:"$callers", [])]
    token = make_ref()
    ctx = context(task)

    {_pid, mref} =
      spawn_monitor(fn ->
        Process.put(:"$callers", callers)
        send(parent, {:ash_a2a_task_done, token, run_handler(module, message, ctx)})
      end)

    Process.put(@in_flight_key, Map.put(in_flight(), token, {mref, from, task.id}))
  end

  @doc false
  @spec handle_info(term(), State.t()) :: {:noreply, State.t()} | :unhandled
  def handle_info({:ash_a2a_task_done, token, reply}, state) do
    case pop_in_flight(token) do
      {mref, from, task_id} ->
        Process.demonitor(mref, [:flush])
        finish(task_id, from, reply, state, :async)

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, mref, :process, _pid, reason}, state) do
    case Enum.find(in_flight(), fn {_token, {ref, _from, _id}} -> ref == mref end) do
      {token, {_mref, from, task_id}} ->
        _ = pop_in_flight(token)
        error = SafeError.internal(:internal_error, {:worker_exit, reason})
        finish(task_id, from, {:error, error}, state, :async)

      nil ->
        :unhandled
    end
  end

  def handle_info(_msg, _state), do: :unhandled

  @doc false
  # GenServer's default `handle_info/2` behavior (log, keep running): calling
  # `super` for a GenServer callback is deprecated.
  @spec unexpected_info(module(), term(), State.t()) :: {:noreply, State.t()}
  def unexpected_info(module, msg, state) do
    Logger.error(
      "#{inspect(module)} received unexpected message in handle_info/2: " <>
        inspect(msg, limit: 20)
    )

    {:noreply, state}
  end

  defp pop_in_flight(token) do
    {entry, rest} = Map.pop(in_flight(), token)
    Process.put(@in_flight_key, rest)
    entry
  end

  @doc false
  @spec in_flight_count() :: non_neg_integer()
  def in_flight_count, do: map_size(in_flight())

  @doc false
  # Whether a worker is still running the handler for `task_id` (must be
  # called from inside the agent process that owns the in-flight table).
  @spec in_flight?(String.t()) :: boolean()
  def in_flight?(task_id) do
    Enum.any?(in_flight(), fn {_token, {_mref, _from, id}} -> id == task_id end)
  end

  # Runs the handler with the same `[:a2a, :agent, :message]` span
  # `A2A.Agent.Runtime.run_task/4` emits, and converts any raise/throw/exit or
  # malformed return into a typed internal error (SEC-02).
  defp run_handler(module, message, ctx) do
    meta = %{agent: module, task_id: ctx.task_id, context_id: ctx.context_id}

    :telemetry.span([:a2a, :agent, :message], meta, fn ->
      result = safe_handle(module, message, ctx)
      {result, Map.put(meta, :reply_type, elem(result, 0))}
    end)
  end

  defp safe_handle(module, message, ctx) do
    case module.handle_message(message, ctx) do
      {tag, _} = reply when tag in [:reply, :stream, :input_required, :error] -> reply
      other -> {:error, SafeError.internal(:internal_error, {:bad_handler_return, other})}
    end
  rescue
    error -> {:error, SafeError.internal(:internal_error, error, __STACKTRACE__)}
  catch
    kind, reason -> {:error, SafeError.internal(:internal_error, {kind, reason}, __STACKTRACE__)}
  end

  defp finish(task_id, from, reply, state, mode) do
    case State.get_task(state, task_id) do
      {:ok, task} ->
        if A2A.Task.terminal?(task) do
          # Defensive: `tasks/cancel` is refused while a worker runs (see
          # `in_flight?/1` and `AshA2A.Agent`), so a task reaching here
          # terminal was finalized by another path; never overwrite it.
          respond(mode, from, {:ok, task}, state)
        else
          task = task |> apply_reply(reply) |> maybe_wrap_stream() |> drop_terminal_auth()
          state = State.put_task(state, task)
          respond(mode, from, {:ok, task}, state)
        end

      {:error, :not_found} ->
        respond(mode, from, {:error, :not_found}, state)
    end
  end

  defp respond(:inline, _from, result, state), do: {:reply, result, state}

  defp respond(:async, from, result, state) do
    GenServer.reply(from, result)
    {:noreply, state}
  end

  # Mirrors `A2A.Agent.Runtime.handle_reply/2`, except that an error reason
  # is redacted (SEC-08) before it becomes the wire-visible status message.
  defp apply_reply(task, {:reply, parts}) do
    artifact = A2A.Artifact.new(parts)
    agent_msg = A2A.Message.new_agent(parts)
    task = %{task | artifacts: task.artifacts ++ [artifact], history: task.history ++ [agent_msg]}
    State.transition(task, :completed)
  end

  defp apply_reply(task, {:input_required, parts}) do
    agent_msg = A2A.Message.new_agent(parts)
    task = %{task | history: task.history ++ [agent_msg]}
    State.transition(task, :input_required, agent_msg)
  end

  defp apply_reply(task, {:error, reason}) do
    error_msg = A2A.Message.new_agent("Error: #{inspect(SafeError.redact(reason))}")
    State.transition(task, :failed, error_msg)
  end

  defp apply_reply(task, {:stream, enum}) do
    %{task | metadata: Map.put(task.metadata, :stream, enum)}
  end

  defp maybe_wrap_stream(%{metadata: %{stream: enum}} = task) do
    wrapped = A2A.Agent.Runtime.wrap_stream(enum, self(), task.id)
    %{task | metadata: Map.put(task.metadata, :stream, wrapped)}
  end

  defp maybe_wrap_stream(task), do: task

  # A terminal task never runs again, so it no longer needs the verified
  # credential; keeping it would only widen what a task store persists.
  defp drop_terminal_auth(task) do
    if A2A.Task.terminal?(task),
      do: %{task | metadata: Map.delete(task.metadata, "a2a.auth")},
      else: task
  end

  # -- owner-scoped reads ----------------------------------------------------

  @doc false
  @spec get_task_for(State.t(), Principal.key(), String.t()) ::
          {:ok, A2A.Task.t()} | {:error, :not_found}
  def get_task_for(state, principal, task_id) do
    with {:ok, task} <- State.get_task(state, task_id),
         true <- owned_by?(task, principal) do
      {:ok, task}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc false
  @spec list_tasks_for(State.t(), Principal.key(), map()) :: {:ok, map()} | {:error, term()}
  def list_tasks_for(state, principal, params) do
    # Anonymous callers share one owner key, so listing would enumerate every
    # other anonymous caller's task ids (which then grant read/continue). An
    # anonymous caller may only address a task by the unguessable id it was
    # given; it never lists.
    owned =
      %{
        state
        | tasks:
            Map.filter(state.tasks, fn {_id, t} ->
              principal != :anonymous and owned_by?(t, principal)
            end)
      }

    # An external store's `list_all/2` cannot be owner-filtered before
    # pagination, so owner-scoped listing always pages over the in-memory map.
    State.list_tasks(%{owned | task_store: nil}, params)
  end
end
