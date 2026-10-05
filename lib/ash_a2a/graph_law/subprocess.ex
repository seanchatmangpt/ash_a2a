# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.GraphLaw.Subprocess do
  @moduledoc """
  The one bounded way the GraphLaw `node` transports run a subprocess
  (PERF-03).

  `System.cmd/3` has no wall-clock bound and no admission control: a hung
  `node` blocks its caller forever, and an inbound burst can fork an unbounded
  number of ~100 ms, tens-of-MB engine processes. `run/3` fixes both:

    * **Deadline.** The command runs under a `Port`; output is collected until
      the exit status arrives or `:timeout_ms` elapses (default
      `config :ash_a2a, :graphlaw_subprocess_timeout_ms`, else 30 s). On
      timeout the OS process is killed (`kill -9 <os_pid>`) and the port
      closed; the caller gets `{:error, %{code: :graphlaw_host_timeout}}`.
    * **Concurrency cap.** A node-wide counting semaphore (an `:atomics`
      counter in `:persistent_term`) admits at most `:max_concurrency`
      subprocesses at once (default `config :ash_a2a,
      :graphlaw_subprocess_max_concurrency`, else
      `System.schedulers_online/0`). A spawn over the cap is shed with
      `{:error, %{code: :graphlaw_host_saturated}}` -- never queued.

  stderr is NOT merged into stdout (the engine hosts write their JSON envelope
  to stdout; a node warning on stderr must not corrupt it). stderr goes to
  the BEAM's own stderr, as with `System.cmd/3`'s default.

  Returns `{:ok, {stdout, exit_status}}` for a process that exited on its own
  (any status -- callers keep their own exit-status typing), or a typed
  `{:error, map}`.
  """

  @default_timeout 30_000

  @doc false
  def __sa2a_refusal_codes__,
    do: %{
      graphlaw_host_timeout: :blocked_resource,
      graphlaw_host_saturated: :blocked_resource,
      graphlaw_host_spawn_failed: :blocked_resource
    }

  @doc """
  Runs `executable` (an absolute path or a name resolved on `PATH`) with
  `args`. Options: `:timeout_ms`, `:max_concurrency`, `:env`
  (`[{"NAME", "value"}]`).
  """
  @spec run(String.t(), [String.t()], keyword()) ::
          {:ok, {binary(), non_neg_integer()}} | {:error, map()}
  def run(executable, args, opts \\ []) when is_binary(executable) and is_list(args) do
    timeout = timeout_ms(opts)
    max = max_concurrency(opts)

    case resolve(executable) do
      nil ->
        {:error, %{code: :graphlaw_host_spawn_failed, executable: executable, reason: :enoent}}

      path ->
        with_slot(max, fn -> spawn_and_collect(path, args, timeout, opts) end)
    end
  end

  @doc "Subprocesses currently holding a slot on this node."
  @spec in_flight() :: non_neg_integer()
  def in_flight, do: :atomics.get(counter(), 1)

  @doc "The resolved per-call wall-clock bound in ms."
  @spec timeout_ms(keyword()) :: pos_integer()
  def timeout_ms(opts \\ []) do
    Keyword.get(opts, :timeout_ms) ||
      Application.get_env(:ash_a2a, :graphlaw_subprocess_timeout_ms, @default_timeout)
  end

  @doc "The resolved concurrency cap."
  @spec max_concurrency(keyword()) :: pos_integer()
  def max_concurrency(opts \\ []) do
    Keyword.get(opts, :max_concurrency) ||
      Application.get_env(:ash_a2a, :graphlaw_subprocess_max_concurrency) ||
      System.schedulers_online()
  end

  defp resolve(executable) do
    if Path.type(executable) == :absolute and File.exists?(executable),
      do: executable,
      else: System.find_executable(executable)
  end

  # The slot is released by a watcher process, never by the caller alone: an
  # `after` block does not run when the caller is killed (a linked task that
  # dies, a `Task.shutdown(:brutal_kill)`), which would leak the slot for the
  # node's lifetime and eventually shed every spawn. The watcher monitors the
  # caller; on `:release` or on the caller's `:DOWN` it decrements exactly
  # once, and on `:DOWN` it also kills the OS process the caller had started.
  defp with_slot(max, fun) do
    ref = counter()

    if :atomics.add_get(ref, 1, 1) > max do
      :atomics.sub(ref, 1, 1)
      {:error, %{code: :graphlaw_host_saturated, max_concurrency: max}}
    else
      caller = self()
      watcher = spawn(fn -> watch(caller, ref) end)
      Process.put({__MODULE__, :watcher}, watcher)

      try do
        fun.()
      after
        Process.delete({__MODULE__, :watcher})
        release_and_wait(watcher)
      end
    end
  end

  # Release synchronously on normal completion: `run/3` must not return while
  # `in_flight/0` still counts its slot, or an immediate re-run at the cap is
  # spuriously shed. The wait is bounded; if the watcher is already gone (it
  # only exits after releasing) the monitor fires and we proceed.
  defp release_and_wait(watcher) do
    tag = make_ref()
    mon = Process.monitor(watcher)
    send(watcher, {:release, self(), tag})

    receive do
      {:released, ^tag} -> Process.demonitor(mon, [:flush])
      {:DOWN, ^mon, :process, ^watcher, _} -> :ok
    after
      5_000 -> Process.demonitor(mon, [:flush])
    end
  end

  defp watch(caller, ref) do
    monitor = Process.monitor(caller)
    watch_loop(caller, ref, monitor, nil)
  end

  defp watch_loop(caller, ref, monitor, os_pid) do
    receive do
      {:os_pid, pid} ->
        watch_loop(caller, ref, monitor, pid)

      {:release, from, tag} ->
        Process.demonitor(monitor, [:flush])
        :atomics.sub(ref, 1, 1)
        send(from, {:released, tag})

      {:DOWN, ^monitor, :process, ^caller, _reason} ->
        if is_integer(os_pid), do: System.cmd("kill", ["-9", Integer.to_string(os_pid)])
        :atomics.sub(ref, 1, 1)
    end
  end

  defp counter do
    key = {__MODULE__, :in_flight}

    case :persistent_term.get(key, nil) do
      nil ->
        ref = :atomics.new(1, signed: true)
        # First writer wins; a concurrent racer re-reads the stored ref.
        :global.trans({key, self()}, fn ->
          case :persistent_term.get(key, nil) do
            nil -> :persistent_term.put(key, ref)
            _ -> :ok
          end
        end)

        :persistent_term.get(key)

      ref ->
        ref
    end
  end

  defp spawn_and_collect(path, args, timeout, opts) do
    env = Enum.map(Keyword.get(opts, :env, []), fn {k, v} -> {~c"#{k}", ~c"#{v}"} end)

    port =
      Port.open({:spawn_executable, path}, [
        :binary,
        :exit_status,
        :use_stdio,
        :hide,
        args: args,
        env: env
      ])

    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        _ -> nil
      end

    case Process.get({__MODULE__, :watcher}) do
      watcher when is_pid(watcher) and is_integer(os_pid) -> send(watcher, {:os_pid, os_pid})
      _ -> :ok
    end

    deadline = System.monotonic_time(:millisecond) + timeout
    collect(port, os_pid, deadline, timeout, [])
  rescue
    error ->
      {:error,
       %{code: :graphlaw_host_spawn_failed, executable: path, reason: Exception.message(error)}}
  end

  defp collect(port, os_pid, deadline, timeout, acc) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        collect(port, os_pid, deadline, timeout, [acc | data])

      {^port, {:exit_status, status}} ->
        {:ok, {IO.iodata_to_binary(acc), status}}
    after
      remaining ->
        kill(port, os_pid)
        {:error, %{code: :graphlaw_host_timeout, timeout_ms: timeout, os_pid: os_pid}}
    end
  end

  defp kill(port, os_pid) do
    if is_integer(os_pid), do: System.cmd("kill", ["-9", Integer.to_string(os_pid)])

    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end

    drain(port)
  end

  # Drop anything the port delivered before it closed, so a timed-out call
  # leaves nothing behind in the caller's mailbox.
  defp drain(port) do
    receive do
      {^port, _} -> drain(port)
    after
      0 -> :ok
    end
  end
end
