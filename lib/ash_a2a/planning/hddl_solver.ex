defmodule AshA2A.Planning.HddlSolver do
  @moduledoc """
  Real subprocess invocation of the native `hddl_cli` (`ferroplan`) binary
  over generated HDDL domain/problem text.

  Mirrors the exact real, non-mocked subprocess pattern already established
  by `test/support/semantic_hddl_verification.ex` and
  `test/support/freedom_gym_meeting_plan.ex`: writes the given domain/problem
  text to two real temporary files, shells out to the real `hddl_cli` binary
  via `System.cmd/3`, and decodes its real stdout JSON via the built-in
  `JSON` module (this repo's own convention at every existing call site of
  this binary -- never `Jason`). No part of this module simulates, stubs, or
  hand-constructs a plan result -- every `{:ok, decoded}` this returns came
  from a real OS subprocess actually running the real solver.
  """

  @default_cli_path Path.expand("../../../native/hddl_cli/target/release/hddl_cli", __DIR__)
  @default_timeout_ms 30_000
  @default_max_output_bytes 8_000_000

  @doc """
  Resolves the real `hddl_cli` binary path: `opts[:cli_path]`, else
  `Application.get_env(:ash_a2a, :hddl_cli_path, ...)`, else a default
  computed relative to this file. Configurable (not hardcoded) because
  `native/` is excluded from the published hex package (see `mix.exs`'s
  `package: [files: ...]`) -- the computed default only resolves inside a
  source checkout of this repo, never inside an installed hex dependency.
  """
  @spec cli_path(keyword()) :: String.t()
  def cli_path(opts \\ []) do
    Keyword.get(opts, :cli_path) ||
      Application.get_env(:ash_a2a, :hddl_cli_path, @default_cli_path)
  end

  @doc """
  Resolved subprocess timeout: `opts[:timeout_ms]`, else
  `config :ash_a2a, :hddl_timeout_ms` (default `30_000`).
  """
  @spec timeout_ms(keyword()) :: pos_integer()
  def timeout_ms(opts \\ []) do
    Keyword.get(opts, :timeout_ms) ||
      Application.get_env(:ash_a2a, :hddl_timeout_ms, @default_timeout_ms)
  end

  @doc """
  Resolved subprocess output cap: `opts[:max_output_bytes]`, else
  `config :ash_a2a, :hddl_max_output_bytes` (default `8_000_000`).
  """
  @spec max_output_bytes(keyword()) :: pos_integer()
  def max_output_bytes(opts \\ []) do
    Keyword.get(opts, :max_output_bytes) ||
      Application.get_env(:ash_a2a, :hddl_max_output_bytes, @default_max_output_bytes)
  end

  @doc """
  Writes `domain_text`/`problem_text` to two real temporary files (under
  `opts[:tmp_dir]`, default `System.tmp_dir!/0`), invokes the real
  `hddl_cli` binary over them via a real `System.cmd/3` subprocess call, and
  decodes its real stdout JSON.

  Returns `{:ok, decoded}` iff the real subprocess exits `0`, its real
  stdout decodes as JSON, `decoded["solved"] == true`, and `decoded` carries
  no `"error"` key -- exactly `test/support/semantic_hddl_verification.ex`'s
  own success criterion. Returns `{:error, map}` (always carrying a `:code`
  key) for every other real outcome: a missing/unbuilt binary
  (`:hddl_cli_not_built`), non-JSON stdout (`:non_json_stdout`), a real
  solver-reported error (`:hddl_solve_error`), or a real unsolved plan
  (`:hddl_unsolved`).

  The two temp files are always removed afterward (`after` block), whether
  the subprocess succeeds or raises.
  """
  @spec solve(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def solve(domain_text, problem_text, opts \\ [])
      when is_binary(domain_text) and is_binary(problem_text) do
    path = cli_path(opts)

    result =
      if File.exists?(path) do
        run(path, domain_text, problem_text, opts)
      else
        {:error,
         %{
           code: :hddl_cli_not_built,
           message:
             "hddl_cli binary not built at #{path}. " <>
               "Run: cd native/hddl_cli && cargo build --release"
         }}
      end

    emit_planner_invoke(result)
  end

  # `[:ash_a2a, :planner, :invoke]`: one planner invocation and its outcome
  # (RFC-SA2A-002 §43 PlannerInvocations). Observational only.
  defp emit_planner_invoke(result) do
    {outcome, refusal_code} =
      case result do
        {:ok, _decoded} -> {:solved, nil}
        {:error, %{code: code}} -> {:refused, code}
      end

    :telemetry.execute([:ash_a2a, :planner, :invoke], %{count: 1}, %{
      planner: :hddl_cli,
      outcome: outcome,
      code: refusal_code
    })

    result
  end

  defp run(path, domain_text, problem_text, opts) do
    tmp_dir = Keyword.get(opts, :tmp_dir, System.tmp_dir!())
    unique = crossvm_unique()
    domain_path = Path.join(tmp_dir, "ash_a2a_hddl_domain_#{unique}.hddl")
    problem_path = Path.join(tmp_dir, "ash_a2a_hddl_problem_#{unique}.hddl")

    File.write!(domain_path, domain_text)
    File.write!(problem_path, problem_text)

    try do
      case run_bounded(path, [domain_path, problem_path], opts) do
        {:ok, stdout, exit_code} -> decode_result(stdout, exit_code)
        {:error, _} = refusal -> refusal
      end
    after
      File.rm(domain_path)
      File.rm(problem_path)
    end
  end

  @default_timeout_ms 30_000
  @default_max_output_bytes 8_000_000

  # CWE-770: wall-clock timeout + stdout size cap. On breach the OS process is
  # killed and a typed refusal (`:hddl_timeout` / `:hddl_output_too_large`)
  # is returned.
  defp run_bounded(path, args, opts) do
    timeout =
      Keyword.get(
        opts,
        :timeout_ms,
        Application.get_env(:ash_a2a, :hddl_timeout_ms, @default_timeout_ms)
      )

    cap =
      Keyword.get(
        opts,
        :max_output_bytes,
        Application.get_env(:ash_a2a, :hddl_max_output_bytes, @default_max_output_bytes)
      )

    port =
      Port.open({:spawn_executable, path}, [:binary, :exit_status, :use_stdio, args: args])

    os_pid = Port.info(port, :os_pid)
    deadline = System.monotonic_time(:millisecond) + timeout
    collect(port, os_pid, deadline, timeout, cap, [], 0)
  end

  defp collect(port, os_pid, deadline, timeout, cap, acc, size) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        size = size + byte_size(data)

        if size > cap do
          kill(port, os_pid)

          {:error,
           %{
             code: :hddl_output_too_large,
             message: "hddl_cli stdout exceeded #{cap} bytes; process killed"
           }}
        else
          collect(port, os_pid, deadline, timeout, cap, [acc, data], size)
        end

      {^port, {:exit_status, status}} ->
        {:ok, IO.iodata_to_binary(acc), status}
    after
      remaining ->
        kill(port, os_pid)

        {:error,
         %{
           code: :hddl_timeout,
           message: "hddl_cli exceeded #{timeout}ms wall-clock; process killed"
         }}
    end
  end

  defp kill(port, os_pid) do
    case os_pid do
      {:os_pid, pid} -> System.cmd("kill", ["-9", Integer.to_string(pid)], stderr_to_stdout: true)
      _ -> :ok
    end

    try do
      Port.close(port)
    catch
      _, _ -> :ok
    end

    receive do
      {^port, _} -> :ok
    after
      0 -> :ok
    end
  end

  # `System.unique_integer/1` is unique only within one BEAM VM. The
  # v26.9.17 multinode stress wave (real `:peer` nodes on one shared host,
  # all resolving the same `System.tmp_dir!/0`) showed two fresh VMs'
  # monotonic counters emit identical sequences, so same-sequence solves on
  # different nodes derived the SAME absolute temp paths and the concurrent
  # `File.write!/2` + `File.rm/1` pairs corrupted each other's solve (see
  # `AshA2A.PlanningHddlSolverCrossvmTest`, which reproduces the
  # contamination and is red on the old node-blind naming). Prefixing a
  # sanitized `node()` tag makes the paths unique ACROSS VMs, not just
  # within one: distinct nodes always have distinct names, so tags cannot
  # collide by construction, and within one node `System.unique_integer/1`
  # keeps its per-invocation uniqueness. Cleanup is unchanged -- each owner
  # removes exactly the paths it wrote.
  defp crossvm_unique do
    node_tag =
      node()
      |> Atom.to_string()
      |> String.replace(~r/[^A-Za-z0-9_@.-]/, "_")

    "#{node_tag}-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp decode_result(stdout, exit_code) do
    case JSON.decode(stdout) do
      {:ok, decoded} ->
        cond do
          exit_code == 0 and decoded["solved"] == true and not Map.has_key?(decoded, "error") ->
            {:ok, decoded}

          Map.has_key?(decoded, "error") ->
            {:error, Map.put(decoded, :code, :hddl_solve_error)}

          true ->
            {:error, Map.put(decoded, :code, :hddl_unsolved)}
        end

      {:error, reason} ->
        {:error, %{code: :non_json_stdout, reason: reason, stdout: stdout}}
    end
  end
end
