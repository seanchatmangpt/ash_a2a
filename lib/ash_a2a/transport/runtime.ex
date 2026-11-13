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
      behavior. `tasks/cancel` on a task whose handler is still running
      interrupts it (`cancel_in_flight/3`): the worker is killed before its
      result is applied, the pending send replies with the `:canceled` task,
      and the late worker result is a no-op. Opt back into the refusal with
      `execution: [cancel_in_flight: :refuse]` (`:not_cancelable`). In
      `:inline` mode and under `adapter: :pplan` a cancel can only arrive
      after the run finished, so the terminal-state answer applies.
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
  alias AshA2A.Transport.{Principal, SafeError, WireCompat}

  @owner_key "ash_a2a.owner"
  @tenant_key "ash_a2a.tenant"
  @in_flight_key :ash_a2a_in_flight
  @workers_key :ash_a2a_in_flight_workers
  @buckets_key :ash_a2a_rate_buckets
  @max_buckets 10_000
  @sweep_key :ash_a2a_orphan_sweep
  @sweep_msg :ash_a2a_orphan_sweep
  @default_sweep_interval_ms 10_000
  @default_lease_ms 60_000

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
  @spec owned_by?(AshA2A.Protocol.Task.t(), Principal.key() | {Principal.key(), String.t()}) ::
          boolean()
  def owned_by?(task, {key, tenant}), do: owner(task) == key and task_tenant(task) == tenant
  # An untenanted call never sees a tenanted task (tenant isolation).
  def owned_by?(task, principal), do: owner(task) == principal and task_tenant(task) == nil

  @doc "Tenant recorded on `task` at creation (`nil` when untenanted)."
  @spec task_tenant(AshA2A.Protocol.Task.t()) :: String.t() | nil
  def task_tenant(%AshA2A.Protocol.Task{metadata: metadata}) when is_map(metadata),
    do: Map.get(metadata, @tenant_key)

  def task_tenant(_task), do: nil

  @doc """
  Removes transport-internal metadata (verified auth, owner key, stream ref)
  from a task before it is encoded onto the wire.
  """
  @spec wire_task(AshA2A.Protocol.Task.t()) :: AshA2A.Protocol.Task.t()
  def wire_task(%AshA2A.Protocol.Task{metadata: metadata} = task) when is_map(metadata) do
    %{task | metadata: Map.drop(metadata, ["a2a.auth", @owner_key, @tenant_key, :stream])}
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
    # Wire boundary: `A2A.Plug` (hex `a2a` 0.3.0) delivers
    # decoded wire `%A2A.Message{}` structs. Convert wire -> protocol before
    # `prepare_task/4` history folding and `__dispatch__/4`, and remember the
    # direction so the reply is converted back (wire in -> wire out,
    # protocol in -> protocol out) before `A2A.JSONRPC.encode_send_result/2`
    # encodes it.
    wire? = WireCompat.wire_message?(message)
    message = WireCompat.to_protocol(message)

    config = config(agent_opts)
    metadata = call_metadata(opts)
    caller = Principal.from_metadata(metadata)
    state = ensure_sweep(config, state)

    immediate? = Keyword.get(opts, :return_immediately, false) == true
    continuing? = Keyword.get(opts, :task_id) != nil

    with :ok <- check_rate(caller, config),
         :ok <- check_capacity(config),
         :ok <- validate_input_modes(module, message, opts, config),
         {:ok, updates} <- admit_artifact_updates(module, opts),
         {:ok, task, message} <- prepare_task(message, opts, metadata, caller, wire?, state) do
      # A2A v1.1 client-written artifacts: applied in request order AFTER the
      # client message was appended (prepare_task), role :user, client
      # generation ignored (ClientArtifacts.apply_updates/2).
      task = AshA2A.Protocol.ClientArtifacts.apply_updates(task, updates)

      # returnImmediately: a NEW task is stored `:submitted`, a continuation
      # `:working`; the non-immediate path always runs the task `:working`.
      task =
        if immediate? and not continuing?,
          do: task,
          else: State.transition(task, :working)

      remember_output_modes(task, opts)
      state = state |> State.put_task(task) |> State.track_context(task)
      publish_message_update(task, message, config)
      state = wake_waiters(state)

      # `adapter:` selects WHAT runs (the agent's own handler, or a durable
      # ash_pplan run via `AshA2A.Execution.PPlan`); `mode:` selects WHERE the
      # chosen unit runs (inline on this GenServer, or off-mailbox in a
      # monitored worker — the pplan unit included).
      handler =
        case Keyword.get(config, :adapter) do
          :pplan -> fn -> pplan_reply(message, task, config) end
          _local -> fn -> run_handler(module, message, context(task)) end
        end

      mode = if immediate?, do: :async, else: Keyword.get(config, :mode)

      case mode do
        _ when immediate? ->
          # Reply with the stored task now; the worker's result folds into the
          # stored task later (`finish/6`, which never overwrites a terminal
          # state). `:detached` has no caller to answer.
          spawn_worker(handler, task, :detached, wire?)
          {:reply, wire_reply({:ok, task}, wire?), state}

        :inline ->
          task.id |> finish(from, handler.(), state, :inline, wire?) |> wake_reply()

        _async ->
          spawn_worker(handler, task, from, wire?)
          {:noreply, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  # v1.1 `artifactUpdates` admission: gated on the agent card's
  # `user_artifacts` capability BEFORE any task is created or mutated.
  # `opts[:artifact_updates]` is either `ClientArtifacts.decode_updates/1`
  # output (`[{artifact, append?, last_chunk}]`) or the raw wire list.
  defp admit_artifact_updates(module, opts) do
    with {:ok, decoded} <- decode_artifact_updates(Keyword.get(opts, :artifact_updates)) do
      card =
        if function_exported?(module, :agent_card, 0), do: module.agent_card(), else: nil

      case AshA2A.Protocol.ClientArtifacts.check_user_artifacts(card, decoded) do
        :ok -> {:ok, decoded}
        {:error, _} = error -> error
      end
    end
  end

  defp decode_artifact_updates(nil), do: {:ok, []}
  defp decode_artifact_updates([]), do: {:ok, []}

  defp decode_artifact_updates([first | _] = updates) when is_tuple(first),
    do: {:ok, updates}

  defp decode_artifact_updates([first | _] = updates) when is_map(first),
    do: AshA2A.Protocol.ClientArtifacts.decode_updates(updates)

  defp decode_artifact_updates(_other), do: {:error, :invalid_artifact_update}

  # v1.1 message_update: the appended client message is published to the
  # per-task event log (`AshA2A.A2ATransport.TaskEvents`) as a stamped
  # `Event.MessageUpdate` (wire kind `"message-update"`). Delivery gating to
  # >= 1.1 consumers is the event log/SSE layer's job. No-op when
  # the agent is not wired to an events transport
  # (`execution: [events_transport: name]` or `config :ash_a2a,
  # :events_transport`), which is the in-process default.
  @doc false
  @spec publish_message_update(AshA2A.Protocol.Task.t(), AshA2A.Protocol.Message.t(), keyword()) ::
          :ok
  def publish_message_update(task, message, config) do
    transport =
      Keyword.get(config, :events_transport) || Application.get_env(:ash_a2a, :events_transport)

    if is_atom(transport) and transport != nil do
      event = message_update_event(task, message)

      payload =
        case AshA2A.Protocol.JSON.encode(event) do
          {:ok, map} when is_map(map) -> %{"messageUpdate" => map}
          map when is_map(map) -> %{"messageUpdate" => map}
          _ -> %{"messageUpdate" => %{"taskId" => task.id}}
        end

      _ = AshA2A.A2ATransport.TaskEvents.publish(transport, task.id, "message-update", payload)
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @doc "The `Event.MessageUpdate` for a client message, stamped with the task's generation."
  @spec message_update_event(AshA2A.Protocol.Task.t(), AshA2A.Protocol.Message.t()) ::
          AshA2A.Protocol.Event.MessageUpdate.t()
  def message_update_event(task, message) do
    AshA2A.Protocol.Event.MessageUpdate.new(task.id, message,
      context_id: task.context_id,
      generation: AshA2A.Protocol.Task.Generation.generation_of(task)
    )
  end

  @doc "The `Event.StatusUpdate` for the task's current status, stamped with its generation."
  @spec status_event(AshA2A.Protocol.Task.t()) :: AshA2A.Protocol.Event.StatusUpdate.t()
  def status_event(task) do
    AshA2A.Protocol.Event.StatusUpdate.new(task.id, task.status,
      context_id: task.context_id,
      final: AshA2A.Protocol.Task.terminal?(task),
      generation: AshA2A.Protocol.Task.Generation.generation_of(task)
    )
  end

  @doc """
  The `Event.ArtifactUpdate` for a stored artifact; generation is
  `artifact.end_generation || artifact.start_generation` (falling back to the
  task generation).
  """
  @spec artifact_event(AshA2A.Protocol.Task.t(), AshA2A.Protocol.Artifact.t()) ::
          AshA2A.Protocol.Event.ArtifactUpdate.t()
  def artifact_event(task, artifact) do
    AshA2A.Protocol.Event.ArtifactUpdate.new(task.id, artifact,
      context_id: task.context_id,
      generation:
        artifact.end_generation || artifact.start_generation ||
          AshA2A.Protocol.Task.Generation.generation_of(task)
    )
  end

  defp call_metadata(opts) do
    case Keyword.get(opts, :metadata) do
      %{} = metadata -> metadata
      _ -> %{}
    end
  end

  # Input-mode admission against the agent card (opt out with
  # `validate_input_modes: false` per call or in the agent's `execution:` opts).
  defp validate_input_modes(module, message, opts, config) do
    card =
      if function_exported?(module, :agent_card, 0), do: module.agent_card(), else: nil

    vopts =
      case Keyword.fetch(opts, :validate_input_modes) do
        {:ok, v} -> [validate_input_modes: v, skill_id: Keyword.get(opts, :skill_id)]
        :error -> [validate_input_modes: Keyword.get(config, :validate_input_modes, true)]
      end

    AshA2A.Protocol.InputModeValidator.validate_input(message, card, vopts)
  end

  @modes_key :ash_a2a_accepted_output_modes

  defp remember_output_modes(task, opts) do
    case Keyword.get(opts, :accepted_output_modes) do
      [_ | _] = modes ->
        Process.put(@modes_key, Map.put(Process.get(@modes_key, %{}), task.id, modes))

      _ ->
        :ok
    end
  end

  defp apply_output_modes(task) do
    {modes, rest} = Map.pop(Process.get(@modes_key, %{}), task.id)
    Process.put(@modes_key, rest)

    case AshA2A.Protocol.InputModeValidator.apply_output_modes(task, modes) do
      {:ok, %AshA2A.Protocol.Task{} = filtered} -> filtered
      _ -> task
    end
  end

  # referenceTaskIds: every id must exist and be visible to the caller (same
  # owner + tenant rule as a continuation); unknown and foreign are the same
  # `{:error, :not_found}`. Returns the first referenced task's context id.
  defp resolve_references(message, metadata, caller, state) do
    principal = {caller, Principal.tenant(metadata)}

    message.reference_task_ids
    |> List.wrap()
    |> Enum.reduce_while({:ok, nil}, fn ref_id, {:ok, inherited} ->
      with {:ok, ref} <- State.get_task(state, ref_id),
           true <- owned_by?(ref, principal) do
        {:cont, {:ok, inherited || ref.context_id}}
      else
        _ -> {:halt, {:error, :not_found}}
      end
    end)
  end

  defp prepare_task(message, opts, metadata, caller, wire?, state) do
    explicit =
      explicit_context_id(Keyword.get(opts, :context_id)) ||
        explicit_context_id(message.context_id)

    with {:ok, inherited} <- resolve_references(message, metadata, caller, state) do
      case Keyword.get(opts, :task_id) do
        nil ->
          metadata = metadata |> put_owner(caller) |> put_tenant()

          task =
            AshA2A.Protocol.Task.new(
              id: secure_task_id(),
              context_id: explicit || inherited || secure_context_id(),
              metadata: metadata
            )

          # v1.1: the initial client message is a generation-bumping timeline
          # entry (mirrors the bare agent's `admit_new_immediately/6`);
          # `ifGenerationMatch` is ignored for new tasks.
          {:ok, AshA2A.Protocol.Task.Generation.append_message(task, message), message}

        task_id ->
          continue(
            task_id,
            message,
            metadata,
            caller,
            explicit,
            wire?,
            state,
            Keyword.get(opts, :if_generation_match)
          )
      end
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

  defp continue(task_id, message, metadata, caller, explicit_ctx, wire?, state, if_generation) do
    with {:ok, task} <- State.get_task(state, task_id),
         :ok <- ensure(owner(task) == caller, :not_found),
         # Tenant isolation: a task created under tenant T is invisible to a
         # call under another tenant (or none); untenanted stays untenanted.
         :ok <- ensure(task_tenant(task) == Principal.tenant(metadata), :not_found),
         # A mismatching explicit contextId must be indistinguishable from an
         # unknown task id (owner-scope convention): same `{:error,
         # :not_found}` the `State.get_task/2` arm above returns, never a
         # shape that reveals the task exists (V24 gap 1; A2A v1.0
         # S3.4.3/S4.1.4 MUST).
         # (owner + tenant already passed above, so `:context_mismatch` reveals
         # nothing to a foreign caller. Wire-originated requests keep the
         # pinned V24 `:not_found` envelope.)
         :ok <- ensure(matching_context?(task, explicit_ctx), mismatch_reason(wire?)),
         :ok <- ensure(not AshA2A.Protocol.Task.terminal?(task), :not_continuable),
         :ok <- ensure(task.status.state != :working, %{code: :task_in_progress}),
         # v1.1 ifGenerationMatch (existing tasks only), checked after the
         # ownership/context gates so a foreign caller learns nothing.
         :ok <- AshA2A.Protocol.ClientArtifacts.check_generation(task, if_generation) do
      task_metadata =
        task.metadata
        |> Map.delete(:stream)
        |> rebind_auth(metadata)

      task =
        AshA2A.Protocol.Task.Generation.append_message(%{task | metadata: task_metadata}, message)

      {:ok, task, message}
    end
  end

  defp ensure(true, _reason), do: :ok
  defp ensure(false, reason), do: {:error, reason}

  defp mismatch_reason(true), do: :not_found
  defp mismatch_reason(false), do: :context_mismatch

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

  # Normalizes the call's tenant (either accepted metadata key) onto the one
  # stored key; absent tenant leaves metadata untouched (default behaviour).
  defp put_tenant(metadata) do
    case Principal.tenant(metadata) do
      nil -> Map.delete(metadata, @tenant_key)
      tenant -> Map.put(metadata, @tenant_key, tenant)
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

  defp spawn_worker(handler, task, from, wire?) when is_function(handler, 0) do
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
    #
    # The watcher also monitors the agent itself: if the agent dies the
    # worker is killed, so no handler keeps running (and acting) with no one
    # left to receive its result.
    spawn(fn ->
      wref = Process.monitor(pid)
      pref = Process.monitor(parent)

      receive do
        {:DOWN, ^wref, _, _, :normal} ->
          :ok

        {:DOWN, ^wref, _, _, reason} ->
          error = SafeError.internal(:internal_error, {:worker_exit, reason})
          send(parent, {:ash_a2a_task_done, token, {:error, error}})

        {:DOWN, ^pref, _, _, _} ->
          Process.exit(pid, :kill)
      end
    end)

    Process.put(@in_flight_key, Map.put(in_flight(), token, {mref, from, task.id, wire?}))
    Process.put(@workers_key, Map.put(Process.get(@workers_key, %{}), token, pid))
  end

  @doc """
  Cancels a task whose handler worker is still running (conformance row 21).

  Returns `:not_in_flight` when no worker runs `task_id` (caller falls through
  to the ported cancel path), otherwise a `GenServer` reply tuple. The cancel
  hook runs first (`[:a2a, :agent, :cancel]` span); on `:ok` the task is
  persisted `:canceled`, the worker is demonitored and killed, the pending
  `message/send` caller is answered with the canceled task (never
  `:completed`), and push notifications + subscribers see the transition. The
  popped in-flight token turns a late `:ash_a2a_task_done` / `:DOWN` into a
  no-op in `handle_info/2`.
  """
  @spec cancel_in_flight(module(), State.t(), String.t()) ::
          :not_in_flight | {:reply, term(), State.t()}
  def cancel_in_flight(module, state, task_id) do
    with {token, {mref, from, _id, wire?}} <- find_in_flight(task_id),
         {:ok, task} <- State.get_task(state, task_id),
         false <- AshA2A.Protocol.Task.terminal?(task) do
      context = %{
        task_id: task.id,
        context_id: task.context_id,
        history: task.history,
        metadata: task.metadata,
        extensions: %{}
      }

      span_meta = %{agent: module, task_id: task.id, context_id: task.context_id}

      result =
        :telemetry.span([:a2a, :agent, :cancel], span_meta, fn ->
          {AshA2A.Protocol.Agent.Runtime.run_cancel(module, context), span_meta}
        end)

      case result do
        :ok ->
          canceled = State.transition(task, :canceled)

          case State.put_task_checked(state, canceled) do
            {:ok, state} ->
              kill_worker(token)
              _ = pop_in_flight(token)
              Process.demonitor(mref, [:flush])

              # The pending send answers with the canceled task.
              {:noreply, state} = respond(:async, from, {:ok, canceled}, state, wire?)

              AshA2A.Protocol.PushNotification.deliver(state, canceled)

              snapshot = AshA2A.Protocol.Task.strip_stream_metadata(canceled)

              for pid <- State.subscribers_for(state, canceled.id) do
                send(pid, {:a2a_task_event, canceled.id, snapshot})
              end

              {:reply, :ok, state |> State.drop_subscribers(canceled.id) |> wake_waiters()}

            {:error, reason} ->
              {:reply, {:error, reason}, state}
          end

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      _ -> :not_in_flight
    end
  end

  defp find_in_flight(task_id) do
    Enum.find(in_flight(), fn {_token, {_mref, _from, id, _wire?}} -> id == task_id end)
  end

  defp kill_worker(token) do
    workers = Process.get(@workers_key, %{})

    case Map.pop(workers, token) do
      {pid, rest} when is_pid(pid) ->
        Process.put(@workers_key, rest)
        Process.exit(pid, :kill)

      {nil, _} ->
        :ok
    end
  end

  # -- orphan sweep + heartbeat ------------------------------------------------
  #
  # `:orphan_sweep_interval_ms` (default 10s, `false` disables) and
  # `:orphan_lease_ms` (default 60s; keep interval well below it). Armed
  # lazily on the first message call (the agent has no init hook this module
  # owns) via `Process.send_after` -- no sleeping. Needs an external
  # `task_store`; without one there is nothing durable to sweep.

  @doc false
  @spec ensure_sweep(keyword(), State.t()) :: State.t()
  def ensure_sweep(config, %{task_store: {_mod, _ref}} = state) do
    interval = Keyword.get(config, :orphan_sweep_interval_ms, @default_sweep_interval_ms)

    cond do
      Process.get(@sweep_key) != nil ->
        state

      is_integer(interval) and interval > 0 ->
        cfg = %{
          interval: interval,
          lease_ms: Keyword.get(config, :orphan_lease_ms, @default_lease_ms),
          timer: Process.send_after(self(), @sweep_msg, interval)
        }

        Process.put(@sweep_key, cfg)
        # start-time sweep: recovers tasks orphaned by a previous node
        sweep_orphans(state, cfg)

      true ->
        state
    end
  end

  def ensure_sweep(_config, state), do: state

  @doc false
  # Fails orphaned `:working` tasks in the store and mirrors the failure into
  # the in-memory task map (which `State.get_task/2` consults first).
  @spec sweep_orphans(State.t(), map()) :: State.t()
  def sweep_orphans(%{task_store: {mod, ref} = store} = state, %{lease_ms: lease_ms}) do
    case AshA2A.Protocol.Task.OrphanSweep.sweep(store,
           lease_ms: lease_ms,
           live?: &worker_alive?/1
         ) do
      {:ok, ids} ->
        Enum.reduce(ids, state, fn id, acc ->
          case mod.get(ref, id) do
            {:ok, task} -> %{acc | tasks: Map.put(acc.tasks, id, task)}
            _ -> acc
          end
        end)

      {:error, _reason} ->
        state
    end
  end

  def sweep_orphans(state, _cfg), do: state

  @doc false
  # Refreshes the status timestamp of every task with a live in-flight worker
  # (checked write path), keeping it inside the lease.
  @spec heartbeat(State.t()) :: State.t()
  def heartbeat(state) do
    Enum.reduce(in_flight(), state, fn {_token, {_mref, _from, task_id, _wire?}}, acc ->
      case Map.fetch(acc.tasks, task_id) do
        {:ok, %{status: %{state: :working} = status} = task} ->
          beat = %{task | status: %{status | timestamp: DateTime.utc_now()}}

          case State.put_task_checked(acc, beat) do
            {:ok, acc} -> acc
            {:error, _} -> acc
          end

        _ ->
          acc
      end
    end)
  end

  @doc false
  @spec worker_alive?(String.t()) :: boolean()
  def worker_alive?(task_id), do: in_flight?(task_id)

  @doc false
  @spec handle_info(term(), State.t()) :: {:noreply, State.t()} | :unhandled
  def handle_info({:ash_a2a_task_done, token, reply}, state) do
    case pop_in_flight(token) do
      {mref, from, task_id, wire?} ->
        Process.demonitor(mref, [:flush])
        task_id |> finish(from, reply, state, :async, wire?) |> wake_reply()

      nil ->
        {:noreply, state}
    end
  end

  # Long-poll deadline for a parked `tasks/get`: answer with the current task.
  def handle_info({:ash_a2a_long_poll_timeout, token}, state) do
    case pop_waiter(token) do
      nil ->
        {:noreply, state}

      waiter ->
        reply_waiter(waiter, state)
        {:noreply, state}
    end
  end

  def handle_info(@sweep_msg, state) do
    case Process.get(@sweep_key) do
      %{interval: interval} = cfg ->
        state = state |> heartbeat() |> sweep_orphans(cfg)
        Process.put(@sweep_key, %{cfg | timer: Process.send_after(self(), @sweep_msg, interval)})
        {:noreply, wake_waiters(state)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, mref, :process, _pid, reason}, state) do
    case Enum.find(in_flight(), fn {_token, {ref, _from, _id, _wire?}} -> ref == mref end) do
      {token, {_mref, from, task_id, wire?}} ->
        _ = pop_in_flight(token)
        error = SafeError.internal(:internal_error, {:worker_exit, reason})
        task_id |> finish(from, {:error, error}, state, :async, wire?) |> wake_reply()

      nil ->
        # A parked long-poll caller that died: drop its waiter (its timer is
        # cancelled); anything else is not ours.
        case Enum.find(waiters(), fn {_token, w} -> w.mref == mref end) do
          {token, _w} ->
            _ = pop_waiter(token)
            {:noreply, state}

          nil ->
            :unhandled
        end
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

    if entry != nil and Process.get(@workers_key) do
      Process.put(@workers_key, Map.delete(Process.get(@workers_key), token))
    end

    entry
  end

  # adapter: :pplan — maps `AshA2A.Execution.PPlan.run/3`'s result onto the
  # reply shapes `apply_reply/2` understands. `AshA2A.Execution.PPlan`
  # fail-closes with `{:error, {:unsupported, :ash_pplan}}` when the optional
  # dependency is absent, so this path never raises for a missing dep.
  defp pplan_reply(message, task, config) do
    result = AshA2A.Execution.PPlan.run(task.id, message, config)
    map_pplan_result(result)
  rescue
    exception ->
      {:error, SafeError.internal(:internal_error, {:pplan_exception, exception.__struct__})}
  catch
    kind, reason ->
      {:error, SafeError.internal(:internal_error, {:pplan_caught, kind, reason})}
  end

  # Every `AshA2A.Execution.PPlan.run/3` result shape maps to a typed,
  # fail-closed reply — no CaseClauseError, no raw terms leaked.
  defp map_pplan_result({:ok, %{state: :completed, detail: detail}}),
    do: {:reply, [to_part(detail)]}

  defp map_pplan_result({:ok, %{state: :input_required, detail: waiters}}),
    do: {:input_required, [to_part(%{pplan_waiters: waiters})]}

  defp map_pplan_result({:ok, %{state: :working, detail: detail}}),
    do: {:working, [to_part(detail)]}

  defp map_pplan_result({:ok, %{state: :canceled, detail: detail}}),
    do: {:canceled, [to_part(%{pplan_run: detail})]}

  defp map_pplan_result({:ok, %{state: :failed, detail: detail}}),
    do: {:error, {:pplan_run_failed, detail}}

  # `:submitted` is a pre-attempt state; a finished dispatch never lawfully
  # ends there, so it is a typed refusal rather than a silent pass.
  defp map_pplan_result({:ok, %{state: :submitted}}),
    do: {:error, {:pplan, {:unexpected_state, :submitted}}}

  defp map_pplan_result({:ok, other}), do: {:error, {:pplan, {:unexpected_result, other}}}

  defp map_pplan_result({:error, {:unsupported, :ash_pplan}}),
    do: {:error, {:pplan, {:unsupported, :ash_pplan}}}

  defp map_pplan_result({:error, {:missing_opt, _} = reason}), do: {:error, {:pplan, reason}}
  defp map_pplan_result({:error, {:invalid_opt, _} = reason}), do: {:error, {:pplan, reason}}
  defp map_pplan_result({:error, %{reason: reason}}), do: {:error, {:pplan, reason}}
  defp map_pplan_result({:error, reason}), do: {:error, {:pplan, reason}}
  defp map_pplan_result(other), do: {:error, {:pplan, {:unexpected_result, other}}}

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
    Enum.any?(in_flight(), fn {_token, {_mref, _from, id, _wire?}} -> id == task_id end)
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

  defp finish(task_id, from, reply, state, mode, wire?) do
    case State.get_task(state, task_id) do
      {:ok, task} ->
        if AshA2A.Protocol.Task.terminal?(task) do
          # Defensive: `tasks/cancel` is refused while a worker runs (see
          # `in_flight?/1` and `AshA2a.Agent`), so a task reaching here
          # terminal was finalized by another path; never overwrite it.
          respond(mode, from, {:ok, task}, state, wire?)
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
              respond(mode, from, {:ok, message}, state, wire?)

            _ ->
              task =
                task
                |> apply_reply(reply)
                |> maybe_wrap_stream()
                |> drop_terminal_auth()
                |> apply_output_modes()

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
                respond(mode, from, {:ok, task}, state, wire?)
              else
                respond(mode, from, {:ok, task}, state, wire?)
              end
          end
        end

      {:error, :not_found} ->
        respond(mode, from, {:error, :not_found}, state, wire?)
    end
  end

  # returnImmediately: the caller was already answered with the stored task.
  defp respond(_mode, :detached, _result, state, _wire?), do: {:noreply, state}

  defp respond(:inline, _from, result, state, wire?) do
    {:reply, wire_reply(result, wire?), state}
  end

  defp respond(:async, from, result, state, wire?) do
    GenServer.reply(from, wire_reply(result, wire?))
    {:noreply, state}
  end

  # Wire boundary: wire-originated requests get wire
  # structs back so `A2A.JSONRPC.encode_send_result/2` has a matching
  # clause; protocol-originated requests keep protocol structs.
  defp wire_reply(result, false), do: result
  defp wire_reply(result, true), do: WireCompat.to_wire(result)

  # Mirrors `AshA2A.Protocol.Agent.Runtime.handle_reply/2`, except that an error reason
  # is redacted (SEC-08) before it becomes the wire-visible status message.
  defp apply_reply(task, {:reply, parts}) do
    artifact = AshA2A.Protocol.Artifact.new(parts)
    agent_msg = AshA2A.Protocol.Message.new_agent(parts)
    # v1.1: the artifact add is a generation-bumping mutation (completed, so
    # `end_generation` is set), followed by the status append in `transition`.
    {task, _stored} = AshA2A.Protocol.Task.Generation.record_artifact(task, artifact, true)
    task = %{task | history: task.history ++ [agent_msg]}
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
        error_msg =
          AshA2A.Protocol.Message.new_agent("Rejected: #{inspect(SafeError.redact(reason))}")

        State.transition(task, :rejected, error_msg)

      auth_failure?(reason) ->
        error_msg =
          AshA2A.Protocol.Message.new_agent("Auth required: #{inspect(SafeError.redact(reason))}")

        State.transition(task, :auth_required, error_msg)

      true ->
        error_msg =
          AshA2A.Protocol.Message.new_agent("Error: #{inspect(SafeError.redact(reason))}")

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

  @waiters_key :ash_a2a_long_poll_waiters

  defp waiters, do: Process.get(@waiters_key, %{})

  @doc """
  `tasks/get` with v1.1 options (`timeline_length:`, `current_generation:`,
  `long_poll_timeout_ms:`), as the `{:ash_a2a_get_task, principal, task_id,
  opts}` call.

  `current_generation` unset, or below the task's generation, answers now. At
  or above it the caller is parked in a monitor-based waiting list and
  answered by `wake_waiters/1` when the generation advances, or at the
  `config :ash_a2a, :long_poll_timeout_ms` deadline (`Process.send_after`, no
  sleeping) with the current task. A terminal task never advances, so it
  answers immediately.
  """
  @spec get_task_call(State.t(), Principal.key(), String.t(), keyword(), GenServer.from()) ::
          {:reply, term(), State.t()} | {:noreply, State.t()}
  def get_task_call(state, principal, task_id, opts, {pid, _tag} = from) do
    case get_task_for(state, principal, task_id) do
      {:ok, task} ->
        current = Keyword.get(opts, :current_generation)
        timeline_length = Keyword.get(opts, :timeline_length)

        if is_integer(current) and not AshA2A.Protocol.Task.terminal?(task) and
             AshA2A.Protocol.Task.Generation.generation_of(task) <= current do
          token = make_ref()

          timeout =
            AshA2A.Protocol.ClientArtifacts.long_poll_timeout_ms(
              Keyword.get(opts, :long_poll_timeout_ms)
            )

          waiter = %{
            from: from,
            principal: principal,
            task_id: task_id,
            current: current,
            timeline_length: timeline_length,
            mref: Process.monitor(pid),
            # SLEEP-CLASS: SCHEDULING (long-poll deadline; the process has
            # nothing to do until a generation advance or this timer)
            timer: Process.send_after(self(), {:ash_a2a_long_poll_timeout, token}, timeout)
          }

          Process.put(@waiters_key, Map.put(waiters(), token, waiter))
          {:noreply, state}
        else
          {:reply, {:ok, truncate(task, timeline_length)}, state}
        end

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  defp truncate(task, timeline_length),
    do: AshA2A.Protocol.Task.Generation.truncate_timeline(task, timeline_length)

  defp pop_waiter(token) do
    {waiter, rest} = Map.pop(waiters(), token)
    Process.put(@waiters_key, rest)

    if waiter do
      Process.cancel_timer(waiter.timer)
      Process.demonitor(waiter.mref, [:flush])
    end

    waiter
  end

  defp reply_waiter(waiter, state) do
    reply =
      case get_task_for(state, waiter.principal, waiter.task_id) do
        {:ok, task} -> {:ok, truncate(task, waiter.timeline_length)}
        {:error, _} = error -> error
      end

    GenServer.reply(waiter.from, reply)
  end

  @doc false
  # Releases every parked long-poll whose task generation now exceeds the
  # generation it supplied (or whose task went terminal / vanished). Called
  # after every state change this runtime or the generated agent applies.
  @spec wake_waiters(State.t()) :: State.t()
  def wake_waiters(state) do
    for {token, waiter} <- waiters() do
      ready? =
        case get_task_for(state, waiter.principal, waiter.task_id) do
          {:ok, task} ->
            AshA2A.Protocol.Task.Generation.generation_of(task) > waiter.current or
              AshA2A.Protocol.Task.terminal?(task)

          {:error, _} ->
            true
        end

      if ready? do
        _ = pop_waiter(token)
        reply_waiter(waiter, state)
      end
    end

    state
  end

  @doc false
  @spec wake_reply(term()) :: term()
  def wake_reply({:reply, reply, state}), do: {:reply, reply, wake_waiters(state)}
  def wake_reply({:noreply, state}), do: {:noreply, wake_waiters(state)}
  def wake_reply({:noreply, state, extra}), do: {:noreply, wake_waiters(state), extra}
  def wake_reply({:reply, reply, state, extra}), do: {:reply, reply, wake_waiters(state), extra}
  def wake_reply(other), do: other

  @doc false
  @spec waiter_count() :: non_neg_integer()
  def waiter_count, do: map_size(waiters())

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
        # Store read-through: the store's tasks join the page
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
