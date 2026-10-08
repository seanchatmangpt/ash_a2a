# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Transport.Runtime do
  @moduledoc """
  Execution runtime behind every `use AshA2A.Agent` GenServer: task
  ownership, admission limits, and off-mailbox execution.

  `AshA2A.Protocol.Agent`'s own `handle_call({:message, ...})` runs the handler inside the
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
    * **Context id integrity (V24).** A continuation whose request carries an
      explicit, non-empty `contextId` that differs from the stored task's
      `context_id` is refused as `{:error, :not_found}` -- identical to an
      unknown task, so the refusal does not reveal that the task exists
      (A2A v1.0 S3.4.3/S4.1.4: "Agents MUST reject messages containing
      mismatching contextId and taskId"). An omitted or empty `contextId`
      still infers the context from the task. When `prepare_task/5` creates a
      NEW task with no client-supplied `contextId`, it mints a stable
      server-side context id (`secure_context_id/0`, same CSPRNG style as
      `secure_task_id/0`) instead of leaving `nil`, so every conversation
      carries a real, non-empty grouping key from turn 1.
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
  execution: [...]`. `adapter:` selects the execution substrate: the default
  local adapter runs the agent's own `handle_message/2` (mode `:inline` on the
  GenServer, `:async` in a monitored off-mailbox worker); `adapter: :pplan`
  routes the async dispatch through a durable ash_pplan run keyed by the task
  id via `AshA2A.Execution.PPlan` — the node-local handler never executes, and
  the durable run's checkpoint tape is the execution record (a follow-up
  message with the same task id resumes the SAME run).
  """

  require Logger

  alias AshA2A.Protocol.Agent.State
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

  @doc """
  CSPRNG server-generated context id (`ctx-` + 128 random bits, url-safe
  base64) -- same generator style as `secure_task_id/0`. Minted when a new
  task is created with no client-supplied `contextId`, so every conversation
  carries a stable, unguessable, non-empty grouping key (A2A v1.0 S3.4.1:
  agents MAY generate a contextId).
  """
  @spec secure_context_id() :: String.t()
  def secure_context_id do
    "ctx-" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
  end

  @doc "Owner key recorded on `task`, or `:anonymous`."
  @spec owner(AshA2A.Protocol.Task.t()) :: Principal.key()
  def owner(%AshA2A.Protocol.Task{metadata: metadata}) when is_map(metadata) do
    case Map.get(metadata, @owner_key) do
      key when is_binary(key) -> key
      _ -> Principal.from_metadata(metadata)
    end
  end

  def owner(_task), do: :anonymous

  @doc "Whether `principal` may see/act on `task`."
  @spec owned_by?(AshA2A.Protocol.Task.t(), Principal.key()) :: boolean()
  def owned_by?(task, principal), do: owner(task) == principal

  @doc """
  Removes transport-internal metadata (verified auth, owner key, stream ref)
  from a task before it is encoded onto the wire.
  """
  @spec wire_task(AshA2A.Protocol.Task.t()) :: AshA2A.Protocol.Task.t()
  def wire_task(%AshA2A.Protocol.Task{metadata: metadata} = task) when is_map(metadata) do
    %{task | metadata: Map.drop(metadata, ["a2a.auth", @owner_key, :stream])}
  end

  def wire_task(task), do: task

  # -- :message ------------------------------------------------------------

  @doc false
  @spec handle_message_call(
          module(),
          keyword(),
          AshA2A.Protocol.Message.t(),
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

      # `adapter:` selects WHAT runs (the agent's own handler, or a durable
      # ash_pplan run via `AshA2A.Execution.PPlan`); `mode:` selects WHERE the
      # chosen unit runs (inline on this GenServer, or off-mailbox in a
      # monitored worker — the pplan unit included).
      handler =
        case Keyword.get(config, :adapter) do
          :pplan -> fn -> pplan_reply(message, task, config) end
          _local -> fn -> run_handler(module, message, context(task)) end
        end

      case Keyword.get(config, :mode) do
        :inline ->
          finish(task.id, from, handler.(), state, :inline)

        _async ->
          spawn_worker(handler, task, from)
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
          AshA2A.Protocol.Task.new(
            id: secure_task_id(),
            context_id: explicit_context_id(Keyword.get(opts, :context_id)) || secure_context_id(),
            metadata: metadata
          )

        {:ok, %{task | history: [message]}, message}

      task_id ->
        continue(
          task_id,
          message,
          metadata,
          caller,
          explicit_context_id(Keyword.get(opts, :context_id)),
          state
        )
    end
  end

  # An explicit continuation contextId is one the request actually delivered
  # (params "contextId" first, else the message's own `context_id`, per the
  # plug's `call_opts/2` + `put_fallback/3`). Both `nil` and `""` mean "not
  # supplied" -- the wire codec emits the REQUIRED-but-empty `""` sentinel for
  # an omitted contextId -- so they infer the context from the task, per
  # A2A v1.0 S4.1.4.
  defp explicit_context_id(id) when is_binary(id) and id != "", do: id
  defp explicit_context_id(_), do: nil

  defp continue(task_id, message, metadata, caller, explicit_ctx, state) do
    with {:ok, task} <- State.get_task(state, task_id),
         :ok <- ensure(owned_by?(task, caller), :not_found),
         # A mismatching explicit contextId must be indistinguishable from an
         # unknown task id (owner-scope convention): same `{:error,
         # :not_found}` the `State.get_task/2` arm above returns, never a
         # shape that reveals the task exists (V24 gap 1; A2A v1.0
         # S3.4.3/S4.1.4 MUST).
         :ok <- ensure(matching_context?(task, explicit_ctx), :not_found),
         :ok <- ensure(not AshA2A.Protocol.Task.terminal?(task), :not_continuable),
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

  defp matching_context?(_task, nil), do: true
  defp matching_context?(task, explicit_ctx), do: task.context_id == explicit_ctx

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

  defp spawn_worker(handler, task, from) when is_function(handler, 0) do
    parent = self()
    callers = [parent | Process.get(:"$callers", [])]
    token = make_ref()

    pid =
      spawn(fn ->
        Process.put(:"$callers", callers)
        send(parent, {:ash_a2a_task_done, token, handler.()})
      end)

    mref = Process.monitor(pid)

    # SEC-02 crash half. A `{:DOWN, ...}` addressed to this process can
    # never reach the DOWN clause in `handle_info/2` below: `use
    # AshA2A.Agent` expands `use AshA2A.Protocol.Agent` first, so the
    # ported agent's own `handle_info({:DOWN, ...})` clause -- subscriber
    # cleanup keyed on its own `:ash_a2a_protocol_task_workers` table,
    # which never holds a transport worker -- precedes the generated
    # catch-all wrapper in clause order and consumes every DOWN as an
    # unknown-subscriber departure. No clause this module (or the
    # generated agent) defines can be ordered ahead of it, so the
    # worker's death must instead arrive as a message the wrapper DOES
    # see. This one-shot watcher re-delivers a non-`:normal` worker exit
    # as the very same `{:ash_a2a_task_done, token, reply}` envelope the
    # worker itself sends, so the primary task_done handler below fails
    # the task with the identical typed `internal_error` and replies to
    # the caller. `:normal` is ignored: the worker only ever exits
    # normally right after delivering its own result, in which case this
    # watcher simply terminates alongside the already-completed cleanup.
    spawn(fn ->
      wref = Process.monitor(pid)

      receive do
        {:DOWN, ^wref, _, _, :normal} ->
          :ok

        {:DOWN, ^wref, _, _, reason} ->
          error = SafeError.internal(:internal_error, {:worker_exit, reason})
          send(parent, {:ash_a2a_task_done, token, {:error, error}})
      end
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

  # adapter: :pplan — maps `AshA2A.Execution.PPlan.run/3`'s result onto the
  # reply shapes `apply_reply/2` understands. `AshA2A.Execution.PPlan`
  # fail-closes with `{:error, {:unsupported, :ash_pplan}}` when the optional
  # dependency is absent, so this path never raises for a missing dep.
  defp pplan_reply(message, task, config) do
    case AshA2A.Execution.PPlan.run(task.id, message, config) do
      {:ok, %{state: :completed, detail: detail}} ->
        {:reply, [to_part(detail)]}

      {:ok, %{state: :input_required, detail: waiters}} ->
        {:input_required, [to_part(%{pplan_waiters: waiters})]}

      {:ok, %{state: :working, detail: detail}} ->
        {:working, [to_part(detail)]}

      {:ok, %{state: :canceled, detail: detail}} ->
        {:canceled, [to_part(%{pplan_run: detail})]}

      {:ok, %{state: :failed, detail: detail}} ->
        {:error, {:pplan_run_failed, detail}}

      {:error, %{reason: reason}} ->
        {:error, {:pplan, reason}}
    end
  end

  defp to_part(detail) when is_map(detail), do: AshA2A.Protocol.Part.Data.new(detail)
  defp to_part(detail), do: AshA2A.Protocol.Part.Data.new(%{result: detail})

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
  # `AshA2A.Protocol.Agent.Runtime.run_task/4` emits, and converts any raise/throw/exit or
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
      {tag, _} = reply when tag in [:reply, :message, :stream, :input_required, :error] ->
        reply

      other ->
        {:error, SafeError.internal(:internal_error, {:bad_handler_return, other})}
    end
  rescue
    error -> {:error, SafeError.internal(:internal_error, error, __STACKTRACE__)}
  catch
    kind, reason -> {:error, SafeError.internal(:internal_error, {kind, reason}, __STACKTRACE__)}
  end

  defp finish(task_id, from, reply, state, mode) do
    case State.get_task(state, task_id) do
      {:ok, task} ->
        if AshA2A.Protocol.Task.terminal?(task) do
          # Defensive: `tasks/cancel` is refused while a worker runs (see
          # `in_flight?/1` and `AshA2A.Agent`), so a task reaching here
          # terminal was finalized by another path; never overwrite it.
          respond(mode, from, {:ok, task}, state)
        else
          # A2A v1.0 `SendMessageResponse` is a Task/Message oneof. A
          # `{:message, parts}` handler reply delivers the agent message as a
          # bare `{:ok, %Message{}}` result — the same convention as the
          # ported `AshA2A.Protocol.Agent.Runtime.handle_reply({:message,
          # _}, _)` (task discarded, agent message answers out-of-band).
          # The transport runtime's task was already persisted `:working`
          # before the handler ran and `State` has no delete, so it is
          # finalized completed instead of stranded `:working`; the wire
          # result is still the bare Message.
          case reply do
            {:message, parts} ->
  
              task =
                task
                |> apply_reply({:reply, parts})
                |> maybe_wrap_stream()
                |> drop_terminal_auth()

              state = State.put_task(state, task)
              message = %{AshA2A.Protocol.Message.new_agent(parts) | context_id: task.context_id}
              respond(mode, from, {:ok, message}, state)

            _ ->
              task = task |> apply_reply(reply) |> maybe_wrap_stream() |> drop_terminal_auth()
              state = State.put_task(state, task)

              # STREAM-SUB-002: a transition persisted here is wire-observable
              # (SSE resubscribe subscribers and registered push webhooks must
              # see it) — mirror the ported protocol agent's completion fold
              # (`apply_default_result`) exactly; finish/5 previously
              # persisted the task silently.
              AshA2A.Protocol.PushNotification.deliver(state, task)

              state =
                case AshA2A.Protocol.Agent.State.subscribers_for(state, task.id) do
                  [] ->
                    state

                  pids ->
                    snapshot = AshA2A.Protocol.Task.strip_stream_metadata(task)

                    for pid <- pids do
                      send(pid, {:a2a_task_event, task.id, snapshot})
                    end

                    state
                end

              if AshA2A.Protocol.Task.terminal?(task) do
                state = AshA2A.Protocol.Agent.State.drop_subscribers(state, task.id)
                respond(mode, from, {:ok, task}, state)
              else
                respond(mode, from, {:ok, task}, state)
              end
          end
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

  # Mirrors `AshA2A.Protocol.Agent.Runtime.handle_reply/2`, except that an error reason
  # is redacted (SEC-08) before it becomes the wire-visible status message.
  defp apply_reply(task, {:reply, parts}) do
    artifact = AshA2A.Protocol.Artifact.new(parts)
    agent_msg = AshA2A.Protocol.Message.new_agent(parts)
    task = %{task | artifacts: task.artifacts ++ [artifact], history: task.history ++ [agent_msg]}
    State.transition(task, :completed)
  end

  defp apply_reply(task, {:input_required, parts}) do
    agent_msg = AshA2A.Protocol.Message.new_agent(parts)
    task = %{task | history: task.history ++ [agent_msg]}
    State.transition(task, :input_required, agent_msg)
  end

  # Mirrors `AshA2A.Protocol.Agent.Runtime.handle_reply({:error, reason}, task)`
  # (protocol/agent/runtime.ex): a refusal produced BEFORE any handler effect
  # (authority-gate/policy denial, capability resolution) is terminal
  # `:rejected` ("refused at admission"); an auth-class failure
  # (:unauthorized / {:unauthorized, _} / {:auth_required, _}) is parked
  # `:auth_required` -- non-terminal, resumable via the same task id -- while
  # everything else stays terminal `:failed`. Reasons are redacted (SEC-08):
  # this is the wire-facing transport path.
  defp apply_reply(task, {:error, reason}) do
    cond do
      admission_refusal?(reason) ->
        error_msg = AshA2A.Protocol.Message.new_agent("Rejected: #{inspect(SafeError.redact(reason))}")
        State.transition(task, :rejected, error_msg)

      auth_failure?(reason) ->
        error_msg = AshA2A.Protocol.Message.new_agent("Auth required: #{inspect(SafeError.redact(reason))}")
        State.transition(task, :auth_required, error_msg)

      true ->
        error_msg = AshA2A.Protocol.Message.new_agent("Error: #{inspect(SafeError.redact(reason))}")
        State.transition(task, :failed, error_msg)
    end
  end

  defp apply_reply(task, {:stream, enum}) do
    %{task | metadata: Map.put(task.metadata, :stream, enum)}
  end

  # adapter: :pplan — the run is still executing (deadline-parked poll): the
  # task stays non-terminal `:working`; the caller polls `tasks/get`. A
  # follow-up message on such a task is refused `:task_in_progress` by
  # `continue/6` — resumption of a polling run is the engine's job, not a
  # message's.
  defp apply_reply(task, {:working, parts}) do
    agent_msg = AshA2A.Protocol.Message.new_agent(parts)
    State.transition(task, :working, agent_msg)
  end

  # adapter: :pplan — the durable run was cancelled (e.g. via
  # `AshA2A.Providers.PPlan.cancel/2`); the A2A task reports the same goal
  # state instead of a divergent `:failed`.
  defp apply_reply(task, {:canceled, parts}) do
    agent_msg = AshA2A.Protocol.Message.new_agent(parts)
    State.transition(task, :canceled, agent_msg)
  end

  # Reproduction of the landed `auth_failure?/1` classifier in
  # `AshA2A.Protocol.Agent.Runtime` (protocol/agent/runtime.ex:154-158); no
  # shared public classifier exists, so both task-finalizing paths carry the
  # identical four-arm classifier.
  defp auth_failure?(:unauthorized), do: true
  defp auth_failure?({:unauthorized, _}), do: true
  defp auth_failure?({:auth_required, _}), do: true
  defp auth_failure?(_), do: false

  # Reproduction of the landed `admission_refusal?/1` classifier in
  # protocol/agent/runtime.ex — refusals produced before any handler effect
  # land the task terminal `:rejected` (v1.0), never `:failed`.
  defp admission_refusal?("forbidden: " <> _), do: true
  defp admission_refusal?(:forbidden), do: true
  defp admission_refusal?({:forbidden, _}), do: true
  defp admission_refusal?(:skill_not_found), do: true
  defp admission_refusal?({:no_skill, _}), do: true
  defp admission_refusal?({:ambiguous_skill, _}), do: true
  defp admission_refusal?(%{code: :consequence_unclassified}), do: true
  defp admission_refusal?(_), do: false

  defp maybe_wrap_stream(%{metadata: %{stream: enum}} = task) do
    # Mint once, share everywhere: the SSE chunk emitter reads the same
    # :stream_artifact_id (it survives strip_stream_metadata) and the
    # stream_done fold folds the merged artifact under it (v1.0 reassembly).
    artifact_id = AshA2A.Protocol.ID.generate("art")
    task = put_in(task.metadata[:stream_artifact_id], artifact_id)
    wrapped = AshA2A.Protocol.Agent.Runtime.wrap_stream(enum, self(), task.id, artifact_id)
    %{task | metadata: Map.put(task.metadata, :stream, wrapped)}
  end

  defp maybe_wrap_stream(task), do: task

  # A terminal task never runs again, so it no longer needs the verified
  # credential; keeping it would only widen what a task store persists.
  defp drop_terminal_auth(task) do
    if AshA2A.Protocol.Task.terminal?(task),
      do: %{task | metadata: Map.delete(task.metadata, "a2a.auth")},
      else: task
  end

  # -- owner-scoped reads ----------------------------------------------------

  @doc false
  @spec get_task_for(State.t(), Principal.key(), String.t()) ::
          {:ok, AshA2A.Protocol.Task.t()} | {:error, :not_found}
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
    # given; it never lists — against the in-memory map OR the store.
    in_memory =
      if principal == :anonymous do
        %{}
      else
        Map.filter(state.tasks, fn {_id, t} -> owned_by?(t, principal) end)
      end

    merged =
      if principal == :anonymous do
        %{}
      else
        # Store read-through (lane F16): the store's tasks join the page
        # through the SAME `owned_by?/2` gate as the in-memory tasks — the
        # persisted `"ash_a2a.owner"` metadata IS the owner key (it survives
        # at rest; the EKV store redacts only `"a2a.auth"` and `:stream`), so
        # owner-scoping is enforced on the merged set, not assumed from the
        # store. In-memory wins on id collision (it is the fresher write; the
        # store copy is the same task one transition behind).
        with {:ok, %{tasks: stored}} <- store_tasks(state) do
          stored
          |> Enum.filter(&owned_by?(&1, principal))
          |> Map.new(&{&1.id, &1})
          |> Map.merge(in_memory)
        else
          {:error, reason} -> {:store_error, reason}
        end
      end

    case merged do
      {:store_error, reason} ->
        # Store failures propagate typed: a listing that silently dropped the
        # durable half would be a false "no tasks" (and the plug maps
        # `{:error, reason}` to `internal_error`).
        {:error, {:store_read_failed, reason}}

      merged ->
        # One `Filter.apply` over the merged set — the same mechanics the
        # Protocol-level `{:list_tasks, params}` path uses — so owner-scoping,
        # context/status filters, sorting, pagination, and `totalSize` (now
        # the MERGED count) are computed once, after the merge. No dup, no
        # gap.
        State.list_tasks(%{state | tasks: merged, task_store: nil}, params)
    end
  end

  # Every task the external store holds, UNPAGINATED (so the merge happens
  # before `Filter.apply` slices pages). Returns `{:error, reason}` for a
  # store whose `list_all/2` fails; a store without the optional callback
  # contributes nothing (the in-memory map is then the whole listing, exactly
  # the pre-F16 shape).
  @spec store_tasks(State.t()) ::
          {:ok, %{tasks: [AshA2A.Protocol.Task.t()]}} | {:error, term()}
  defp store_tasks(%{task_store: {mod, ref}}) do
    if store_exports?(mod, :list_all, 2) do
      mod.list_all(ref, scan_page_size())
    else
      {:ok, %{tasks: []}}
    end
  end

  defp store_tasks(_state), do: {:ok, %{tasks: []}}

  # A page size no single store scan can hit, so `Filter.apply/2` returns
  # every task with the `""` terminator (no next-page token) and the merged
  # set is paginated exactly once, downstream.
  @store_scan_page_size 1_000_000_000

  defp scan_page_size, do: [page_size: @store_scan_page_size]

  # See the note on `AshA2A.Protocol.JSONRPC.exports?/3` (via
  # `AshA2A.Protocol.Agent.State.exports?/3`): an unloaded store module would
  # otherwise read as one that implements no optional callbacks.
  defp store_exports?(mod, fun, arity) do
    Code.ensure_loaded?(mod) and function_exported?(mod, fun, arity)
  end
end
