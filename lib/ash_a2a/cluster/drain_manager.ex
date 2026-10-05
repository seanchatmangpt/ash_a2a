# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Cluster.DrainManager do
  @moduledoc """
  Two-phase graceful drain (FR-04 / ARD 3.4): trap `:sigterm`, cordon,
  drain, evacuate, exit clean -- all inside Kubernetes' 30s grace period.

  ## Phases

    * **Phase 1 -- Cordon (immediate)**: `handle_info(:sigterm)` (the OS
      `SIGTERM` delivered as a message by `:os.set_signal(:sigterm, :handle)`
      -- the flag is installed in `init/1`) flips the manager to `:cordoned`.
      From this moment the drain-aware health surface
      (`AshA2A.Cluster.HealthPlug`) answers `503` + `Retry-After` on new
      requests, and new work is refused with `{:error, :cordoned}`, while
      every already-running task keeps running.
    * **Phase 2 -- Drain (`:drain_timeout_ms`, default `25_000`)**: tasks
      registered under the task supervisor via `track/3` are given until the
      deadline to conclude. A task that finishes in time is released (its
      `DOWN` arrives with a `:normal` exit); a task that does not has its
      execution frame checkpointed into the durable task store
      (`AshA2A.Cluster.Checkpoint.land/4` -- landing raises on any store
      failure, so drain never reports a checkpoint it does not have), the
      worker is then stopped, and a cluster handover event is emitted so
      peers rehydrate it (`AshA2A.Cluster.Handover`).
    * **Phase 3 -- Exit**: with no tracked work left, the manager emits its
      drain-complete telemetry with real measured timings and stops
      (`:shutdown`), staying well inside the 30s `SIGKILL` budget
      (cordon 0s + drain <= 25s + exit <= 2s <= 27s).

  With `halt_after_drain: true` (container mode) the manager additionally
  shuts the whole runtime down once the tree is drained, so the container
  really exits instead of leaving an empty supervisor behind.

  ## Wiring a task in

      # inside the task process, right after start:
      :ok = AshA2A.Cluster.DrainManager.track(task_id, frame: my_frame)

      # whenever the frame advances:
      :ok = AshA2A.Cluster.DrainManager.update_frame(task_id, new_frame)

      # when the work concludes (the DOWN on normal exit also releases):
      :ok = AshA2A.Cluster.DrainManager.release(task_id)

  A `track/3` from a task that starts after cordon is refused with
  `{:error, :cordoned}` -- new work is rejected, existing work continues.
  """

  use GenServer, restart: :temporary

  alias AshA2A.Cluster.Checkpoint
  alias AshA2A.Cluster.Handover

  @default_drain_timeout_ms 25_000
  @default_retry_after_s 30
  @default_exit_grace_ms 2_000
  @tick_interval_ms 50

  defstruct [
    :name,
    :task_supervisor,
    :task_store,
    :drain_timeout_ms,
    :retry_after_s,
    :exit_grace_ms,
    :halt_after_drain,
    :deadline,
    :cordon_at,
    :drained_at,
    :signal_handler,
    phase: :serving,
    tracked: %{},
    finished: %{},
    checkpointed: MapSet.new()
  ]

  @type phase :: :serving | :cordoned | :draining | :exiting

  # -- Supervision

  @doc """
  Starts the manager. Options:

    * `:name` -- registered name (default `AshA2A.Cluster.DrainManager`).
    * `:task_supervisor` -- the `Task.Supervisor` name whose tracked tasks
      belong to this node's drain domain (informational; tracking is
      cooperative via `track/3`).
    * `:task_store` -- `{module, ref}` tuple (e.g.
      `{AshA2A.TaskStore.Ekv, MyStore}`) used to land checkpoints.
    * `:drain_timeout_ms` -- Phase 2 budget (default `25_000`).
    * `:retry_after_s` -- `Retry-After` seconds served while cordoned
      (default `30`).
    * `:exit_grace_ms` -- Phase 3 budget after the drain deadline
      (default `2_000`).
    * `:halt_after_drain` -- when `true`, shut the whole runtime down once
      the drain completes (container mode; default `false`).
    * `:install_signal_handler` -- when `true` (default), `init/1` swaps the
      kernel's default `:erl_signal_handler` out of the `:erl_signal_server`
      `gen_event` manager for `AshA2A.Cluster.DrainManager.SignalHandler`,
      which routes a real OS `SIGTERM` into `drain/2` and delegates every
      other signal to the kernel handler's logic. This is the supported
      interception point on OTP 26+, where `SIGTERM` never reaches
      `:os.set_signal(:sigterm, :handle)` (the kernel handler calls
      `init:stop()` directly). Pass `false` when another component owns the
      node's signal disposition.
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) when is_list(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  # -- Public API

  @doc "Current phase plus effective configuration and live counters."
  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc "`{:ok, cordoned?}` -- is the node cordoned (Phase 1 entered)?"
  @spec cordoned?(GenServer.server()) :: {:ok, boolean()} | {:error, term()}
  def cordoned?(server \\ __MODULE__) do
    GenServer.call(server, :cordoned?)
  catch
    :exit, _reason -> {:error, :drain_manager_unavailable}
  end

  @doc """
  Registers the calling process as the worker for `task_id`.

  Call from inside the task process. Returns `{:error, :cordoned}` once
  Phase 1 has begun -- new work is rejected, existing work continues.
  """
  @spec track(GenServer.server(), String.t(), keyword()) :: :ok | {:error, :cordoned}
  def track(server \\ __MODULE__, task_id, opts \\ []) when is_binary(task_id) do
    GenServer.call(server, {:track, task_id, self(), opts})
  end

  @doc "Publishes the calling task's current resumable execution frame."
  @spec update_frame(GenServer.server(), String.t(), term()) :: :ok
  def update_frame(server \\ __MODULE__, task_id, frame) do
    GenServer.call(server, {:update_frame, task_id, frame})
  end

  @doc "Releases `task_id` (work concluded). The `DOWN` on a normal exit also releases."
  @spec release(GenServer.server(), String.t()) :: :ok
  def release(server \\ __MODULE__, task_id) do
    GenServer.call(server, {:release, task_id})
  end

  @doc """
  `{:ok, task_ids}` -- tasks currently tracked and still running.
  """
  @spec tracked(GenServer.server()) :: {:ok, [String.t()]}
  def tracked(server \\ __MODULE__), do: GenServer.call(server, :tracked)

  @doc "IDs of tasks whose frames were durably checkpointed at the drain deadline."
  @spec checkpointed(GenServer.server()) :: {:ok, [String.t()]}
  def checkpointed(server \\ __MODULE__), do: GenServer.call(server, :checkpointed)

  @doc """
  Initiates the drain (Phase 1) without an OS `SIGTERM` -- the exact state
  transition the signal handler performs. Returns `{:ok, deadline}`.

  With `halt: true` (what the SIGTERM signal handler passes), the runtime
  itself shuts down once Phase 3 completes -- container SIGTERM semantics.
  """
  @spec drain(GenServer.server(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, :already_draining}
  def drain(server \\ __MODULE__, opts \\ []) do
    GenServer.call(server, {:drain, Keyword.get(opts, :halt, false)})
  end

  # -- GenServer callbacks

  @impl true
  def init(opts) do
    install_signal_handler? = Keyword.get(opts, :install_signal_handler, true)
    state = base_state(opts)

    signal_handler =
      if install_signal_handler? do
        install_signal_handler(state.name)
      else
        :not_installed
      end

    state = %{state | signal_handler: signal_handler}

    :telemetry.execute([:ash_a2a, :cluster, :drain, :init], %{count: 1}, %{
      drain_manager: state.name,
      drain_timeout_ms: state.drain_timeout_ms,
      signal_handler: install_signal_handler?
    })

    {:ok, state}
  end

  defp base_state(opts) do
    %__MODULE__{
      name: Keyword.get(opts, :name, __MODULE__),
      task_supervisor: Keyword.get(opts, :task_supervisor),
      task_store: Keyword.get(opts, :task_store),
      drain_timeout_ms: Keyword.get(opts, :drain_timeout_ms, @default_drain_timeout_ms),
      retry_after_s: Keyword.get(opts, :retry_after_s, @default_retry_after_s),
      exit_grace_ms: Keyword.get(opts, :exit_grace_ms, @default_exit_grace_ms),
      halt_after_drain: Keyword.get(opts, :halt_after_drain, false)
    }
  end

  # OTP 26+: SIGTERM is handled by the kernel's `:erl_signal_handler` (which
  # calls `init:stop()` outright) and never reaches `:os.set_signal/2`. The
  # supported interception point is the `:erl_signal_server` gen_event
  # manager: swap the default handler out and put ours in. Every signal we
  # do not own is delegated to the kernel handler's real logic.
  defp install_signal_handler(name) do
    case :gen_event.swap_handler(:erl_signal_server, {:erl_signal_handler, []}, {__MODULE__.SignalHandler, name}) do
      :ok ->
        :ok

      {:error, {:module_already_present, _}} ->
        # Another DrainManager on this node already owns the signal.
        :ok

      {:error, _other} ->
        # Fall back to adding alongside the kernel handler: SIGTERM will
        # both begin our drain and trigger the kernel's init:stop(); the
        # drain deadline still bounds Phase 2 and System.stop is idempotent.
        :gen_event.add_handler(:erl_signal_server, __MODULE__.SignalHandler, name)
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, status_map(state), state}
  end

  def handle_call(:cordoned?, _from, state) do
    {:reply, {:ok, state.phase != :serving}, state}
  end

  def handle_call({:track, task_id, worker_pid, opts}, _from, %__MODULE__{phase: phase} = state) do
    if phase == :serving do
      ref = Process.monitor(worker_pid)
      entry = %{monitor_ref: ref, pid: worker_pid, frame: Keyword.get(opts, :frame)}

      {:reply, :ok, %{state | tracked: Map.put(state.tracked, task_id, entry)}}
    else
      {:reply, {:error, :cordoned}, state}
    end
  end

  def handle_call({:update_frame, task_id, frame}, _from, %__MODULE__{tracked: tracked} = state) do
    case Map.fetch(tracked, task_id) do
      {:ok, entry} ->
        {:reply, :ok, %{state | tracked: Map.put(tracked, task_id, %{entry | frame: frame})}}

      :error ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:release, task_id}, _from, state) do
    {:reply, :ok, release_task(state, task_id, :released)}
  end

  def handle_call(:tracked, _from, state) do
    {:reply, {:ok, Map.keys(state.tracked)}, state}
  end

  def handle_call(:checkpointed, _from, state) do
    {:reply, {:ok, MapSet.to_list(state.checkpointed)}, state}
  end

  def handle_call({:drain, halt?}, _from, %__MODULE__{phase: :serving} = state) do
    cordoned_state = begin_drain(state, :explicit, halt?)

    {:reply, {:ok, cordoned_state.deadline}, cordoned_state}
  end

  def handle_call({:drain, _halt?}, _from, %__MODULE__{} = state) do
    {:reply, {:error, :already_draining}, state}
  end

  @impl true
  def handle_info(:sigterm, %__MODULE__{phase: :serving} = state) do
    # Message-level path. The OS-level SIGTERM arrives through
    # SignalHandler (below), which calls drain/2 with halt: true.
    {:noreply, begin_drain(state, :sigterm, false)}
  end

  def handle_info(:sigterm, %__MODULE__{} = state), do: {:noreply, state}

  def handle_info(:drain_tick, state) do
    now = System.monotonic_time(:millisecond)

    # finish_drain/2 already returns a valid handle_info result: either
    # {:stop, :shutdown, state} or (container mode) {:noreply, state}.
    cond do
      state.tracked == %{} or now >= state.deadline ->
        finish_drain(state, now)

      true ->
        Process.send_after(self(), :drain_tick, @tick_interval_ms)
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    case Enum.find(state.tracked, fn {_id, entry} -> entry.pid == pid end) do
      {task_id, _entry} ->
        {:noreply, release_task(state, task_id, reason)}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(:halt, %__MODULE__{} = state) do
    # Container mode: the tree is drained, so the runtime itself must exit
    # -- give applications a short window to flush, then halt 0 regardless.
    System.stop(state.exit_grace_ms)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # -- Drain sequencing

  defp begin_drain(%__MODULE__{} = state, reason, halt? \\ false) do
    now = System.monotonic_time(:millisecond)

    Process.send_after(self(), :drain_tick, @tick_interval_ms)

    :telemetry.execute([:ash_a2a, :cluster, :drain, :cordon], %{count: 1}, %{
      drain_manager: state.name,
      reason: reason,
      tracked: map_size(state.tracked),
      drain_timeout_ms: state.drain_timeout_ms
    })

    %{
      state
      | phase: :cordoned,
        cordon_at: now,
        deadline: now + state.drain_timeout_ms,
        halt_after_drain: state.halt_after_drain or halt?
    }
  end

  defp finish_drain(%__MODULE__{} = state, now) do
    {checkpointed, state} =
      state.tracked
      |> Enum.reduce({MapSet.new(), state}, fn {task_id, entry}, {acc, st} ->
        case checkpoint_task(st, task_id, entry) do
          :ok -> {MapSet.put(acc, task_id), %{st | tracked: Map.delete(st.tracked, task_id)}}
          :skip -> {acc, %{st | tracked: Map.delete(st.tracked, task_id)}}
        end
      end)

    state = %{state | phase: :exiting, drained_at: now, checkpointed: checkpointed}

    :telemetry.execute([:ash_a2a, :cluster, :drain, :complete], %{count: 1}, %{
      drain_manager: state.name,
      checkpointed: MapSet.to_list(checkpointed),
      drain_timeout_ms: state.drain_timeout_ms,
      cordon_to_exit_ms: drained_duration(state)
    })

    if state.halt_after_drain do
      Process.send_after(self(), :halt, 50)
      {:noreply, state}
    else
      {:stop, :shutdown, state}
    end
  end

  defp checkpoint_task(%__MODULE__{} = state, task_id, entry) do
    if is_nil(state.task_store) do
      # No durable store configured: the frame cannot be landed, so the
      # drain must not claim evacuation. The task is released untracked
      # (its fate is the tree's ordinary shutdown); a configured tree
      # always lands.
      :skip
    else
      Checkpoint.land(state.task_store, task_id, entry.frame,
        source_node: node(),
        reason: :drain_deadline,
        drain_manager: state.name
      )

      Handover.emit(task_id,
        source_node: node(),
        reason: :drain,
        checkpointed_at: DateTime.utc_now()
      )

      # The frame is durably landed, so the worker may be stopped -- this
      # is the live-eviction semantics (the adopting peer re-runs from the
      # checkpoint, never from this process's memory).
      if entry.pid != self() and Process.alive?(entry.pid) do
        Process.exit(entry.pid, :kill)
      end

      :ok
    end
  end

  defp release_task(%__MODULE__{} = state, task_id, reason) do
    case Map.pop(state.tracked, task_id) do
      {nil, _tracked} ->
        state

      {entry, tracked} ->
        Process.demonitor(entry.monitor_ref, [:flush])
        %{state | tracked: tracked, finished: Map.put(state.finished, task_id, reason)}
    end
  end

  defp drained_duration(%__MODULE__{cordon_at: cordon_at, drained_at: drained_at})
       when is_integer(cordon_at) and is_integer(drained_at),
       do: drained_at - cordon_at

  defp drained_duration(_), do: nil

  defp status_map(state) do
    %{
      phase: state.phase,
      cordoned?: state.phase != :serving,
      drain_timeout_ms: state.drain_timeout_ms,
      retry_after_s: state.retry_after_s,
      exit_grace_ms: state.exit_grace_ms,
      halt_after_drain: state.halt_after_drain,
      task_supervisor: state.task_supervisor,
      tracked: Map.keys(state.tracked),
      finished: Map.to_list(state.finished),
      checkpointed: MapSet.to_list(state.checkpointed),
      deadline: state.deadline,
      signal_handler: state.signal_handler
    }
  end
end

defmodule AshA2A.Cluster.DrainManager.SignalHandler do
  @moduledoc """
  The `:erl_signal_server` handler that gives a drained node its
  `SIGTERM`-initiated two-phase drain.

  Installed by `AshA2A.Cluster.DrainManager` in place of the kernel's
  default `:erl_signal_handler` (which on OTP 26+ answers SIGTERM with an
  immediate `init:stop()` -- no cordon, no drain). Every signal this
  handler does not own is delegated to the kernel handler's real logic, so
  `SIGQUIT`/`SIGUSR1`/`SIGINT` semantics are preserved.
  """

  @impl :gen_event
  def init(name), do: {:ok, name}

  @impl :gen_event
  def handle_event(:sigterm, name) do
    # Fast, non-blocking: drain/2 only flips Phase 1 state and schedules
    # the drain tick loop; Phase 3 calls System.stop/1 itself. A missing
    # manager must not take the node's signal handling down with it.
    try do
      AshA2A.Cluster.DrainManager.drain(name, halt: true)
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end

    {:ok, name}
  end

  @impl :gen_event
  def handle_event(other_signal, name) do
    # Preserve the kernel handler's semantics for every signal we do not
    # own (real kernel logic, not a stub).
    :erl_signal_handler.handle_event(other_signal, {})
    {:ok, name}
  end

  @impl :gen_event
  def handle_info(:sigterm, name) do
    # ERTS delivers the OS signal as a RAW message to the
    # :erl_signal_server process (routed here to handle_info, not
    # handle_event) -- handle both delivery shapes.
    handle_event(:sigterm, name)
  end

  @impl :gen_event
  def handle_info(_info, name), do: {:ok, name}

  @impl :gen_event
  def handle_call(_request, name), do: {:ok, :ok, name}

  @impl :gen_event
  def terminate(_reason, _name), do: :ok
end
