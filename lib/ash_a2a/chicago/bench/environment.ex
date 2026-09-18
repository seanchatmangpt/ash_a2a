defmodule AshA2A.Chicago.Bench.Environment do
  @moduledoc """
  RFC-SA2A-002 §102 benchmark environment receipt.

  `capture/1` records, from the real host, enough to make a benchmark result
  interpretable: CPU model and count, memory, OS / kernel, BEAM / Elixir
  runtime, WASM engine versions (`wasmex`, the `wasmtime` CLI when present,
  the Node host and GraphLaw wasm artifact the admission engine runs on),
  storage type of the evidence/receipt volume (best effort), network topology
  of the measured paths, container/cgroup limits when any, and the
  model/provider identity (not applicable: no benchmark here resolves
  UNKNOWN through a model).

  Every probe is best effort and fails soft to `nil` -- an unavailable fact
  is recorded as unavailable, never invented.

  `"identity"` is sha256 over the canonical JSON of the stable fields only
  (`"volatile"` -- capture time, free memory, BEAM memory in use -- is
  excluded), so two captures on the same machine and runtime share an identity
  and §122 comparisons can refuse results whose environments differ. The host
  name is recorded only as a sha256 (§124).
  """

  alias AshA2A.Chicago.Json

  @cmd_timeout_ms 5_000

  @doc """
  Captures the environment. Options: `:storage_path` (default
  `System.tmp_dir!/0`, where evidence and the receipt outbox live),
  `:graphlaw_opts` (passed to `AshA2A.GraphLaw.Wasm`).
  """
  @spec capture(keyword()) :: map()
  def capture(opts \\ []) do
    os_family = os_family()
    storage_path = Keyword.get(opts, :storage_path, System.tmp_dir!())

    stable = %{
      "cpu" => cpu(os_family),
      "memory" => %{"total_bytes" => memory_total(os_family)},
      "os" => os(os_family),
      "runtime" => runtime(),
      "wasm" => wasm(Keyword.get(opts, :graphlaw_opts, [])),
      "storage" => storage(os_family, storage_path),
      "network" => network(),
      "container" => container(os_family),
      "model_provider" => %{
        "status" => "not_applicable",
        "reason" =>
          "all 10 RFC-SA2A-002 benchmark categories (B1-B10) measure deterministic engine/broker/solver/replay paths; no UNKNOWN resolution through a model is benchmarked"
      },
      "host" => %{"hostname_sha256" => hostname_digest()}
    }

    stable
    |> Map.put("identity", identity(stable))
    |> Map.put("volatile", %{
      "captured_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "beam_memory_total_bytes" => :erlang.memory(:total),
      "free_memory_bytes" => free_memory(os_family)
    })
  end

  @doc "sha256 over the canonical JSON of the stable environment fields."
  @spec identity(map()) :: String.t()
  def identity(env) when is_map(env) do
    env
    |> Map.drop(["identity", "volatile"])
    |> Json.canonical()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # --- CPU -------------------------------------------------------------------

  defp cpu(:darwin) do
    %{
      "model" => cmd("sysctl", ["-n", "machdep.cpu.brand_string"]),
      "logical_count" => int(cmd("sysctl", ["-n", "hw.logicalcpu"])),
      "physical_count" => int(cmd("sysctl", ["-n", "hw.physicalcpu"])),
      "performance_cores" => int(cmd("sysctl", ["-n", "hw.perflevel0.physicalcpu"])),
      "efficiency_cores" => int(cmd("sysctl", ["-n", "hw.perflevel1.physicalcpu"]))
    }
    |> Map.merge(beam_cpu())
  end

  defp cpu(:linux) do
    info = read("/proc/cpuinfo") || ""
    lines = String.split(info, "\n")

    model =
      Enum.find_value(lines, fn line ->
        case String.split(line, ":", parts: 2) do
          [key, value] ->
            if String.trim(key) in ["model name", "Model", "cpu model"], do: String.trim(value)

          _ ->
            nil
        end
      end)

    %{
      "model" => model,
      "logical_count" => Enum.count(lines, &String.starts_with?(&1, "processor")),
      "physical_count" => nil
    }
    |> Map.merge(beam_cpu())
  end

  defp cpu(_other), do: Map.merge(%{"model" => nil, "logical_count" => nil}, beam_cpu())

  defp beam_cpu do
    %{
      "beam_logical_processors" => system_info(:logical_processors),
      "beam_logical_processors_available" => system_info(:logical_processors_available),
      "beam_schedulers_online" => system_info(:schedulers_online),
      "beam_dirty_cpu_schedulers_online" => system_info(:dirty_cpu_schedulers_online)
    }
  end

  # --- memory ------------------------------------------------------------------

  defp memory_total(:darwin), do: int(cmd("sysctl", ["-n", "hw.memsize"]))
  defp memory_total(:linux), do: meminfo("MemTotal")
  defp memory_total(_), do: nil

  defp free_memory(:linux), do: meminfo("MemAvailable")

  defp free_memory(:darwin) do
    with out when is_binary(out) <- cmd("vm_stat", []),
         [_, page] <- Regex.run(~r/page size of (\d+) bytes/, out),
         [_, free] <- Regex.run(~r/Pages free:\s+(\d+)/, out) do
      String.to_integer(page) * String.to_integer(free)
    else
      _ -> nil
    end
  end

  defp free_memory(_), do: nil

  defp meminfo(key) do
    with text when is_binary(text) <- read("/proc/meminfo"),
         [_, kb] <- Regex.run(~r/^#{key}:\s+(\d+)\s+kB/m, text) do
      String.to_integer(kb) * 1024
    else
      _ -> nil
    end
  end

  # --- OS ----------------------------------------------------------------------

  defp os(family) do
    %{
      "family" => Atom.to_string(family),
      "kernel_name" => cmd("uname", ["-s"]),
      "kernel_release" => cmd("uname", ["-r"]),
      "machine" => cmd("uname", ["-m"]),
      "distribution" => distribution(family)
    }
  end

  defp distribution(:darwin) do
    case {cmd("sw_vers", ["-productName"]), cmd("sw_vers", ["-productVersion"])} do
      {nil, _} -> nil
      {name, version} -> "#{name} #{version}"
    end
  end

  defp distribution(:linux) do
    with text when is_binary(text) <- read("/etc/os-release"),
         [_, pretty] <- Regex.run(~r/^PRETTY_NAME="?([^"\n]+)"?/m, text) do
      pretty
    else
      _ -> nil
    end
  end

  defp distribution(_), do: nil

  # --- runtime -------------------------------------------------------------------

  defp runtime do
    %{
      "otp_release" => to_string(:erlang.system_info(:otp_release)),
      "erts" => to_string(:erlang.system_info(:version)),
      "elixir" => System.version(),
      "system_architecture" => to_string(:erlang.system_info(:system_architecture)),
      "emu_flavor" => system_info(:emu_flavor),
      "build_type" => system_info(:build_type),
      "wordsize_bytes" => :erlang.system_info({:wordsize, :external}),
      "beam_limits" => %{
        "process_limit" => system_info(:process_limit),
        "port_limit" => system_info(:port_limit),
        "atom_limit" => system_info(:atom_limit),
        "ets_limit" => system_info(:ets_limit)
      },
      "ash_a2a" => app_vsn(:ash_a2a),
      "ash" => app_vsn(:ash)
    }
  end

  # --- WASM ----------------------------------------------------------------------

  defp wasm(graphlaw_opts) do
    wasm_path = AshA2A.GraphLaw.Wasm.wasm_path(graphlaw_opts)

    %{
      "wasmex" => app_vsn(:wasmex),
      "wasmtime_cli" => cmd("wasmtime", ["--version"]),
      "graphlaw_host_runtime" => node_version(),
      "graphlaw_wasm_sha256" => file_sha256(wasm_path),
      "graphlaw_available" => AshA2A.GraphLaw.Wasm.availability(graphlaw_opts) == :ok
    }
  end

  defp node_version do
    case cmd("node", ["--version"]) do
      nil -> nil
      version -> "node " <> version
    end
  end

  # --- storage -------------------------------------------------------------------

  defp storage(family, path) do
    {device, mount_point} = df(path)

    %{
      "path_role" => "evidence and receipt-outbox volume (System.tmp_dir!/0 unless overridden)",
      "mount_point" => mount_point,
      "filesystem" => filesystem(family, device, mount_point),
      "medium" => medium(family, device)
    }
  end

  defp df(path) do
    with out when is_binary(out) <- cmd("df", ["-P", path]),
         [_header, line | _] <- String.split(out, "\n", trim: true),
         [device | rest] <- String.split(line) do
      {device, List.last(rest)}
    else
      _ -> {nil, nil}
    end
  end

  defp filesystem(:linux, _device, mount_point) when is_binary(mount_point) do
    with text when is_binary(text) <- read("/proc/mounts") do
      text
      |> String.split("\n", trim: true)
      |> Enum.map(&String.split/1)
      |> Enum.filter(&match?([_, ^mount_point, _ | _], &1))
      |> List.last()
      |> case do
        [_, _, type | _] -> type
        _ -> nil
      end
    end
  end

  defp filesystem(_family, device, _mount_point) when is_binary(device) do
    with out when is_binary(out) <- cmd("mount", []),
         line when is_binary(line) <-
           Enum.find(String.split(out, "\n"), &String.starts_with?(&1, device <> " on ")),
         [_, flags] <- Regex.run(~r/\(([^)]*)\)\s*$/, line) do
      flags |> String.split(",") |> List.first() |> String.trim()
    else
      _ -> nil
    end
  end

  defp filesystem(_, _, _), do: nil

  defp medium(:darwin, device) when is_binary(device) do
    with out when is_binary(out) <- cmd("diskutil", ["info", device]) do
      %{
        "solid_state" => diskutil_field(out, "Solid State"),
        "protocol" => diskutil_field(out, "Protocol"),
        "device_location" => diskutil_field(out, "Device Location")
      }
    end
  end

  defp medium(:linux, device) when is_binary(device) do
    base = device |> Path.basename() |> String.replace(~r/p?\d+$/, "")

    case read("/sys/block/#{base}/queue/rotational") do
      "0" <> _ -> %{"solid_state" => "Yes"}
      "1" <> _ -> %{"solid_state" => "No"}
      _ -> nil
    end
  end

  defp medium(_, _), do: nil

  defp diskutil_field(out, key) do
    case Regex.run(~r/^\s*#{Regex.escape(key)}:\s+(.+)$/m, out) do
      [_, value] -> String.trim(value)
      _ -> nil
    end
  end

  # --- network / container -----------------------------------------------------------

  defp network do
    %{
      "topology" =>
        "single BEAM node; SUT boundaries (AdmissionPipeline, Authority.Grant, CommandBus, Observer) in-process; " <>
          "GraphLaw engine via a local OS subprocess over stdio; receipt outbox on local disk; no network hop in any measured path",
      "distributed_node" => Node.alive?(),
      "connected_nodes" => length(Node.list())
    }
  end

  defp container(:linux) do
    %{
      "dockerenv" => File.exists?("/.dockerenv"),
      "cgroup" => read("/proc/1/cgroup") |> trim_or_nil(),
      "cpu_max" => read("/sys/fs/cgroup/cpu.max") |> trim_or_nil(),
      "memory_max" => read("/sys/fs/cgroup/memory.max") |> trim_or_nil(),
      "cpu_cfs_quota_us" => read("/sys/fs/cgroup/cpu/cpu.cfs_quota_us") |> trim_or_nil(),
      "memory_limit_in_bytes" =>
        read("/sys/fs/cgroup/memory/memory.limit_in_bytes") |> trim_or_nil()
    }
  end

  defp container(family) do
    %{
      "detected" => false,
      "reason" => "#{family} host: no Linux cgroup limits apply to this BEAM"
    }
  end

  # --- helpers -----------------------------------------------------------------------

  defp os_family do
    case :os.type() do
      {:unix, :darwin} -> :darwin
      {:unix, :linux} -> :linux
      {family, _} -> family
    end
  end

  defp hostname_digest do
    case :inet.gethostname() do
      {:ok, name} ->
        :crypto.hash(:sha256, to_string(name)) |> Base.encode16(case: :lower)

      _ ->
        nil
    end
  end

  defp system_info(key) do
    value = :erlang.system_info(key)
    if is_atom(value), do: Atom.to_string(value), else: value
  rescue
    _ -> nil
  end

  defp app_vsn(app) do
    case Application.spec(app, :vsn) do
      nil -> nil
      vsn -> to_string(vsn)
    end
  end

  defp file_sha256(path) do
    case File.read(path) do
      {:ok, bytes} -> :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
      _ -> nil
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, text} -> text
      _ -> nil
    end
  end

  defp trim_or_nil(nil), do: nil
  defp trim_or_nil(text), do: String.trim(text)

  defp int(nil), do: nil

  defp int(text) do
    case Integer.parse(String.trim(text)) do
      {n, _} -> n
      :error -> nil
    end
  end

  # A best-effort probe: a missing executable, a non-zero exit, or a probe that
  # does not answer within @cmd_timeout_ms is recorded as unavailable (nil).
  defp cmd(exe, args) do
    case System.find_executable(exe) do
      nil ->
        nil

      path ->
        task =
          Task.async(fn ->
            try do
              System.cmd(path, args, stderr_to_stdout: true)
            rescue
              _ -> {"", 1}
            end
          end)

        case Task.yield(task, @cmd_timeout_ms) || Task.shutdown(task, :brutal_kill) do
          {:ok, {out, 0}} ->
            case String.trim(out) do
              "" -> nil
              trimmed -> trimmed
            end

          _ ->
            nil
        end
    end
  end
end
