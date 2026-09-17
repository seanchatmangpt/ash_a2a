defmodule AshA2A.RuntimeIdentity.Execution do
  @moduledoc """
  Runtime identity observed from what a live call actually executed on
  (RFC-SA2A-002 §126), and resource metering of that execution (§91).

  `AshA2A.RuntimeIdentity.observe_session/1` walks the session term a runtime
  module returned from `open/1`. That term is authored by the module under
  test, so it can name resources that never execute anything (a decoy process
  next to the real engine) or hide the one that does (an engine reachable only
  through a process whose state holds it). Both were measured against
  `AshA2A.SA2A.Conformance`: a `WasmexSession` wrapper with an idle decoy
  process, and one that ran every call inside an `Agent` holding the
  `WasmexSession` session, were each admitted as a heterogeneous host and
  judged against the very engine they wrapped.

  `observe/2` instead runs a real probe call under an isolated `:trace`
  session (it never disturbs another tracer) and records the resources the
  probe reached:

    * every message the probing process -- and any process it spawns -- sends:
      to a port with an OS process (`"os_process"`, sha256 of the executable
      the OS reports for it) or to a local BEAM process;
    * every port those processes open (`"os_process"`, sha256 of the
      executable file the port was spawned from, observed even when the
      process has already exited).

  A local BEAM process counts as an *engine* only when its application ships
  native code (the embedded-engine NIF case, e.g. `:wasmex`). Any other
  process the probe reached (an `Agent`, a `GenServer` wrapper) is expanded:
  the probe is repeated with that process traced too, until no new process is
  reached (bounded rounds), so an engine reached one hop away is still
  observed. Processes of the OTP runtime itself and the probe's group leader
  are never expanded.

  The result is the set of engine identities. Two runtimes whose engine sets
  intersect executed on the same engine (`disjoint?/2` is false), whatever
  their session terms or labels say. A probe that reached no engine is
  `{:unobservable, detail}` -- never a guessed identity (§130).
  """

  alias AshA2A.RuntimeIdentity

  @system_apps [:kernel, :stdlib, :erts, :logger, :compiler, :sasl]
  @flags [:send, :procs, :set_on_spawn]
  @default_rounds 3
  @max_expanded 32

  @type observation :: %{
          engines: [map()],
          digest: String.t(),
          rounds: pos_integer(),
          expanded: non_neg_integer(),
          probe_latency_us: non_neg_integer()
        }

  @doc """
  Runs `probe` (a zero-arity function issuing one real runtime call) under
  execution tracing and returns the engine identities it executed on.

  The probe runs in the calling process, which must be the process that owns
  the runtime session (a port answers only its connected process).
  Options: `:max_rounds` (default #{@default_rounds}).
  """
  @spec observe((-> term()), keyword()) :: {:ok, observation()} | {:unobservable, String.t()}
  def observe(probe, opts \\ []) when is_function(probe, 0) do
    max_rounds = Keyword.get(opts, :max_rounds, @default_rounds)
    leader = Process.group_leader()
    round(probe, [self()], MapSet.new([self()]), [], nil, 1, max_rounds, leader)
  end

  defp round(probe, traced, seen, engines, latency, n, max_rounds, leader) do
    {_result, elapsed, events} = traced_run(traced, probe, :observe)
    {found, expandable} = classify(events, seen, leader)
    engines = Enum.uniq(engines ++ found)
    latency = latency || elapsed

    new = Enum.reject(expandable, &MapSet.member?(seen, &1))

    if new == [] or n >= max_rounds or MapSet.size(seen) >= @max_expanded do
      finish(engines, n, MapSet.size(seen) - 1, latency)
    else
      seen = Enum.reduce(new, seen, &MapSet.put(&2, &1))
      round(probe, traced ++ new, seen, engines, latency, n + 1, max_rounds, leader)
    end
  end

  defp finish([], rounds, _expanded, _latency),
    do:
      {:unobservable,
       "the probe call reached no engine resource (no OS process and no native-code " <>
         "BEAM process) in #{rounds} round(s)"}

  defp finish(engines, rounds, expanded, latency) do
    if Enum.any?(engines, &unobservable?/1) do
      {:unobservable,
       "an engine resource the probe reached could not be identified: " <>
         inspect(Enum.filter(engines, &unobservable?/1))}
    else
      engines = Enum.sort_by(engines, &AshA2A.Chicago.Json.canonical/1)

      {:ok,
       %{
         engines: engines,
         digest: RuntimeIdentity.digest(engines),
         rounds: rounds,
         expanded: expanded,
         probe_latency_us: latency
       }}
    end
  end

  defp unobservable?(%{"kind" => "os_process"} = identity),
    do: is_nil(identity["executable_sha256"])

  defp unobservable?(%{"kind" => "beam_process"} = identity),
    do: is_nil(identity["emulator_sha256"]) or is_nil(identity["engine_module"])

  @doc "True when two engine sets share no engine identity."
  @spec disjoint?([map()], [map()]) :: boolean()
  def disjoint?(engines_a, engines_b) do
    keys = fn engines -> MapSet.new(engines, &AshA2A.Chicago.Json.canonical/1) end
    MapSet.disjoint?(keys.(engines_a), keys.(engines_b))
  end

  @doc """
  Runs `fun` in the calling process while metering the resources it executes
  on (RFC-SA2A-002 §91 memory per host). Returns `{fun_result, report}`.

  Every OS process the call opens or messages is sampled for resident set
  size while it lives (`ps -o rss=`, every `:interval_ms`, default 25);
  every native-code BEAM engine process it messages is sampled for process
  memory. The report groups peaks by executable / engine identity:

      %{"wall_us" => ..,
        "os_processes" => [%{"executable_sha256" => .., "executable" => ..,
                             "processes" => n, "sampled" => n,
                             "peak_rss_bytes" => ..}],
        "beam_engines" => [%{"engine_module" => .., "engine_native_sha256" => ..,
                             "peak_process_memory_bytes" => ..}]}

  A process that exited before it could be sampled is counted in
  `"processes"` but not in `"sampled"`; its peak is not invented.
  """
  @spec meter((-> result), keyword()) :: {result, map()} when result: var
  def meter(fun, opts \\ []) when is_function(fun, 0) do
    interval = Keyword.get(opts, :interval_ms, 25)
    {result, elapsed, report} = traced_run([self()], fun, {:meter, interval})

    case result do
      {:ok, value} -> {value, Map.put(report, "wall_us", elapsed)}
      {:raised, {kind, reason, stack}} -> :erlang.raise(kind, reason, stack)
    end
  end

  # --- tracing --------------------------------------------------------------

  defp traced_run(pids, fun, mode) do
    traced = Enum.filter(pids, &(node(&1) == node() and Process.alive?(&1)))
    collector = spawn(fn -> collect(mode, initial_state(mode, traced)) end)
    session = :trace.session_create(:ash_a2a_runtime_execution, collector, [])

    try do
      Enum.each(traced, &:trace.process(session, &1, true, @flags))
      :trace.port(session, :new, true, [:ports])

      started = System.monotonic_time(:microsecond)

      result =
        try do
          {:ok, fun.()}
        catch
          kind, reason -> {:raised, {kind, reason, __STACKTRACE__}}
        end

      elapsed = System.monotonic_time(:microsecond) - started

      Enum.each(traced, fn pid ->
        if Process.alive?(pid), do: :trace.process(session, pid, false, @flags)
      end)

      :trace.port(session, :new, false, [:ports])
      ref = :trace.delivered(session, :all)

      receive do
        {:trace_delivered, :all, ^ref} -> :ok
      after
        5_000 -> :ok
      end

      send(collector, {:finish, self()})

      collected =
        receive do
          {:collected, ^collector, collected} -> collected
        after
          60_000 -> if match?({:meter, _}, mode), do: %{}, else: []
        end

      {result, elapsed, collected}
    after
      :trace.session_destroy(session)
      Process.exit(collector, :kill)
    end
  end

  defp initial_state(:observe, _traced), do: []

  defp initial_state({:meter, _}, traced),
    do: %{
      os: %{},
      beam: %{},
      seen_ports: MapSet.new(),
      identities: %{},
      traced: MapSet.new(traced)
    }

  defp collect(:observe, acc) do
    receive do
      {:finish, from} -> send(from, {:collected, self(), Enum.reverse(acc)})
      event -> collect(:observe, [event | acc])
    end
  end

  defp collect({:meter, interval} = mode, state) do
    receive do
      {:finish, from} ->
        send(from, {:collected, self(), meter_report(state)})

      {:trace, _parent, :spawn, child, _mfa} when is_pid(child) ->
        collect(mode, %{state | traced: MapSet.put(state.traced, child)})

      {:trace, _pid, :send, _msg, to} ->
        collect(mode, meter_resource(resolve(to), nil, state, interval))

      # Ports opened by anything outside the traced call (including this
      # collector's own `ps` samplers) are not the call's resources.
      {:trace, port, :open, opener, name} ->
        if MapSet.member?(state.traced, opener),
          do: collect(mode, meter_resource(port, name, state, interval)),
          else: collect(mode, state)

      _other ->
        collect(mode, state)
    end
  end

  defp meter_resource(port, name, state, interval) when is_port(port) do
    if MapSet.member?(state.seen_ports, port) do
      state
    else
      state = %{state | seen_ports: MapSet.put(state.seen_ports, port)}

      case {Port.info(port, :os_pid), executable_of(port, name)} do
        {{:os_pid, os_pid}, {path, sha}} when is_binary(sha) ->
          sampler = spawn(fn -> sample_rss(os_pid, interval, nil, 0) end)
          add_os(state, sha, path, sampler)

        {_, {path, sha}} when is_binary(sha) ->
          add_os(state, sha, path, nil)

        _ ->
          state
      end
    end
  end

  defp meter_resource(pid, _name, state, _interval) when is_pid(pid) do
    {identity, state} =
      case Map.fetch(state.identities, pid) do
        {:ok, identity} ->
          {identity, state}

        :error ->
          identity = local_identity(pid)
          {identity, %{state | identities: Map.put(state.identities, pid, identity)}}
      end

    if identity && engine?(identity) do
      key = Map.take(identity, ["engine_module", "engine_native_sha256"])
      memory = process_memory(pid)
      beam = Map.update(state.beam, key, {pid, memory}, fn {p, m} -> {p, max(m, memory)} end)
      %{state | beam: beam}
    else
      state
    end
  end

  defp meter_resource(_other, _name, state, _interval), do: state

  defp process_memory(pid) do
    case Process.info(pid, :memory) do
      {:memory, bytes} -> bytes
      _ -> 0
    end
  end

  defp add_os(state, sha, path, sampler) do
    entry = Map.get(state.os, sha, %{path: path, samplers: [], processes: 0})

    entry = %{
      entry
      | processes: entry.processes + 1,
        samplers: List.wrap(sampler) ++ entry.samplers
    }

    %{state | os: Map.put(state.os, sha, entry)}
  end

  defp sample_rss(os_pid, interval, peak, samples) do
    receive do
      {:stop, from} -> send(from, {:peak, self(), peak, samples})
    after
      0 ->
        case rss_bytes(os_pid) do
          nil ->
            receive do
              {:stop, from} -> send(from, {:peak, self(), peak, samples})
            end

          bytes ->
            Process.sleep(interval)
            sample_rss(os_pid, interval, max(peak || 0, bytes), samples + 1)
        end
    end
  end

  defp rss_bytes(os_pid) do
    case System.cmd("ps", ["-o", "rss=", "-p", to_string(os_pid)], stderr_to_stdout: true) do
      {out, 0} ->
        case Integer.parse(String.trim(out)) do
          {kb, ""} -> kb * 1024
          _ -> nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp meter_report(state) do
    os =
      state.os
      |> Enum.map(fn {sha, entry} ->
        peaks =
          entry.samplers
          |> Enum.map(fn sampler ->
            send(sampler, {:stop, self()})

            receive do
              {:peak, ^sampler, peak, samples} -> {peak, samples}
            after
              10_000 -> {nil, 0}
            end
          end)
          |> Enum.filter(fn {peak, _} -> is_integer(peak) end)

        %{
          "executable_sha256" => sha,
          "executable" => entry.path,
          "processes" => entry.processes,
          "sampled" => length(peaks),
          "samples" => peaks |> Enum.map(&elem(&1, 1)) |> Enum.sum(),
          "peak_rss_bytes" => peaks |> Enum.map(&elem(&1, 0)) |> Enum.max(fn -> nil end)
        }
      end)
      |> Enum.sort_by(& &1["executable_sha256"])

    beam =
      state.beam
      |> Enum.map(fn {key, {pid, memory}} ->
        Map.put(key, "peak_process_memory_bytes", max(memory, process_memory(pid)))
      end)
      |> Enum.sort_by(& &1["engine_module"])

    %{"os_processes" => os, "beam_engines" => beam}
  end

  # --- classification ---------------------------------------------------------

  # Returns {engine identities, local non-engine processes worth expanding}.
  defp classify(events, seen, leader) do
    spawned = for {:trace, _parent, :spawn, child, _mfa} <- events, is_pid(child), do: child
    traced = Enum.reduce(spawned, seen, &MapSet.put(&2, &1))

    opened =
      for {:trace, port, :open, opener, name} <- events,
          MapSet.member?(traced, opener),
          do: {port, name}

    recipients =
      for {:trace, _from, :send, _msg, to} <- events,
          resource = resolve(to),
          resource != nil,
          uniq: true,
          do: resource

    port_engines =
      opened
      |> Enum.map(fn {port, name} -> executable_of(port, name) end)
      |> Kernel.++(
        recipients
        |> Enum.filter(&is_port/1)
        |> Enum.reject(fn port -> Enum.any?(opened, &(elem(&1, 0) == port)) end)
        |> Enum.map(&executable_of(&1, nil))
      )
      |> Enum.flat_map(fn
        {_path, sha} when is_binary(sha) ->
          [%{"kind" => "os_process", "executable_sha256" => sha}]

        {path, nil} when is_binary(path) ->
          [%{"kind" => "os_process", "executable_sha256" => nil}]

        _ ->
          []
      end)

    {beam_engines, expandable} =
      recipients
      |> Enum.filter(&is_pid/1)
      |> Enum.reject(&(MapSet.member?(traced, &1) or &1 == leader))
      |> Enum.reduce({[], []}, fn pid, {engines, expand} ->
        case local_identity(pid) do
          nil ->
            {engines, expand}

          identity ->
            cond do
              engine?(identity) -> {[identity | engines], expand}
              system?(identity) -> {engines, expand}
              true -> {engines, [pid | expand]}
            end
        end
      end)

    {Enum.uniq(port_engines ++ beam_engines), Enum.reverse(expandable)}
  end

  defp resolve(to) when is_pid(to) or is_port(to), do: to

  defp resolve(name) when is_atom(name),
    do: Process.whereis(name) || Port.list() |> find_named(name)

  defp resolve({name, node}) when is_atom(name) and node == node(), do: resolve(name)
  defp resolve(_), do: nil

  defp find_named(ports, name),
    do: Enum.find(ports, &(Port.info(&1, :registered_name) == {:registered_name, name}))

  defp local_identity(pid) do
    if node(pid) == node() and Process.alive?(pid) do
      RuntimeIdentity.observe_resource(pid)
    end
  end

  defp engine?(%{"kind" => "beam_process"} = identity),
    do: is_binary(identity["engine_native_sha256"])

  defp engine?(_), do: false

  defp system?(identity) do
    app = identity["engine_application"]
    is_binary(app) and app in Enum.map(@system_apps, &Atom.to_string/1)
  end

  # {path | nil, sha256 | nil} of the OS executable behind a port: the live OS
  # pid when the process still runs, else the file the port was spawned from.
  # Ports without an OS process (sockets, drivers, stdio) are `nil`.
  defp executable_of(port, name) do
    live =
      case Port.info(port, :os_pid) do
        {:os_pid, os_pid} ->
          case RuntimeIdentity.os_executable_path(os_pid) do
            nil -> nil
            path -> {path, RuntimeIdentity.file_sha256(path)}
          end

        _ ->
          nil
      end

    live || spawned_executable(name || port_name(port))
  end

  defp port_name(port) do
    case Port.info(port, :name) do
      {:name, name} -> name
      _ -> nil
    end
  end

  defp spawned_executable(nil), do: nil

  defp spawned_executable(name) do
    text = name |> to_string() |> String.trim()
    first = text |> String.split(" ", parts: 2) |> hd()

    path =
      cond do
        text != "" and Path.type(text) == :absolute and File.regular?(text) -> text
        first != "" and Path.type(first) == :absolute and File.regular?(first) -> first
        true -> nil
      end

    if path, do: {path, RuntimeIdentity.file_sha256(path)}
  end
end
