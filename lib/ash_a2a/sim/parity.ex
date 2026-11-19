# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Sim.Parity do
  @moduledoc """
  Runs the A2A v1.1 parity script against a running simulation server.

  The script (`scripts/a2a_v1_1_parity/parity.py`) is an independent reference:
  Python stubs generated from the upstream `v1.1.0-rc` proto and the official
  protobuf runtime. It calls every RPC, route and method of the server and
  compares what the server put on the wire with what the reference encodes,
  byte for byte. See `docs/how-to/check-a2a-v1-1-parity.md`.

      {:ok, _pid} = AshA2A.Sim.Server.start_link()

      case AshA2A.Sim.Parity.run(AshA2A.Sim.Server.info()) do
        {:ok, report} -> report["summary"]
        {:skip, reason} -> reason
      end
      #=> %{"pass" => 1209, "fail" => 0, "known" => 0, "skip" => 0}

  The script needs a Python virtual environment that
  `scripts/a2a_v1_1_parity/setup.sh` creates. `check/0` says whether it is
  there; when it is not, `run/2` returns `{:skip, reason}` and runs nothing.

  ## The report

  `run/2` returns the script's JSON report as a map with string keys:

    * `"summary"` - counts of rows by status: `"pass"`, `"fail"`, `"known"`
      (a failing row listed in `known_defects.json`) and `"skip"`.
    * `"rows"` - one map per check with `"binding"`, `"operation"`,
      `"vector"`, `"check"`, `"status"`, `"detail"` and, for a known defect,
      `"finding"`.
    * `"known_defects"` - the finding ids of the known rows; each is a section
      of `docs/reference/a2a-v1-1-parity-findings.md`.
    * `"normalisations"`, `"coverage"`, `"reference"` - what the comparison
      normalises and why, which proto fields were observed, and where the
      reference proto came from.
  """

  @root Path.expand("../../..", __DIR__)
  @script_dir Path.join(@root, "scripts/a2a_v1_1_parity")
  @default_venv "/tmp/a2a_v1_1_parity/venv"
  @timeout 120_000

  @doc """
  The bindings the script reports on, in report order. The second JSON-RPC
  entry is the owner-scoped `/jsonrpc` mount; `"v1.0"` holds the vectors sent
  with `A2A-Version: 1.0` and compared with the upstream v1.0.1 proto.
  """
  @spec bindings() :: [String.t()]
  def bindings do
    ["grpc", "http+json", "jsonrpc", "jsonrpc:/jsonrpc", "v1.0"] ++
      ["agent-card", "cross-binding", "coverage"]
  end

  @doc "The directory holding the script, its README and `setup.sh`."
  @spec script_dir() :: String.t()
  def script_dir, do: @script_dir

  @doc """
  The virtual environment the script runs in: `$A2A_PARITY_VENV`, else
  `#{@default_venv}`.
  """
  @spec venv() :: String.t()
  def venv, do: System.get_env("A2A_PARITY_VENV") || @default_venv

  @doc """
  Whether the parity script can run here. Returns `{:ok, python}` with the
  interpreter of the virtual environment, or `{:skip, reason}`.
  """
  @spec check() :: {:ok, String.t()} | {:skip, String.t()}
  def check do
    python = Path.join(venv(), "bin/python")
    stubs = Path.join(venv(), "a2a_v1_1_gen/a2a_pb2.py")

    cond do
      not File.exists?(Path.join(@script_dir, "parity.py")) ->
        {:skip, "#{@script_dir}/parity.py is not in this checkout"}

      not File.exists?(python) ->
        {:skip,
         "no Python virtual environment at #{venv()}: run scripts/a2a_v1_1_parity/setup.sh"}

      not File.exists?(stubs) ->
        {:skip, "no reference stubs in #{venv()}: run scripts/a2a_v1_1_parity/setup.sh"}

      true ->
        {:ok, python}
    end
  end

  @doc """
  Runs the script against the server described by `info`
  (`AshA2A.Sim.Server.info/0`).

  Returns `{:ok, report}`, `{:skip, reason}` when the virtual environment is
  missing, or `{:error, reason}` when the script did not produce a report.

  ## Options

    * `:known` - apply `known_defects.json`, so a failing row that is a
      documented defect is reported as `"known"`. Default `true`.
    * `:timeout` - milliseconds to wait for the script. Default `#{@timeout}`.
  """
  @spec run(map(), keyword()) :: {:ok, map()} | {:skip, String.t()} | {:error, String.t()}
  def run(info, opts \\ []) do
    with {:ok, python} <- check() do
      report =
        Path.join(System.tmp_dir!(), "a2a-v1-1-parity-#{System.unique_integer([:positive])}.json")

      known =
        if Keyword.get(opts, :known, true),
          do: ["--known", Path.join(@script_dir, "known_defects.json")],
          else: []

      args =
        [Path.join(@script_dir, "parity.py"), "--http", info.base_url, "--grpc", info.grpc_target] ++
          ["--report", report, "--writer-token", info.tokens.writer] ++
          ["--reader-token", info.tokens.reader, "--unscoped-token", info.tokens.unscoped] ++
          known

      task =
        Task.async(fn ->
          System.cmd(python, args,
            stderr_to_stdout: true,
            env: [
              {"PYTHONDONTWRITEBYTECODE", "1"},
              {"A2A_PARITY_GEN", Path.join(venv(), "a2a_v1_1_gen")}
            ]
          )
        end)

      result =
        case Task.yield(task, Keyword.get(opts, :timeout, @timeout)) ||
               Task.shutdown(task, :brutal_kill) do
          {:ok, {output, status}} when status in [0, 1, 3] ->
            read_report(report, output)

          {:ok, {output, status}} ->
            {:error, "parity.py exited #{status}: #{String.slice(output, -600, 600)}"}

          _ ->
            {:error, "parity.py did not finish in time"}
        end

      File.rm(report)
      result
    end
  end

  defp read_report(path, output) do
    with {:ok, body} <- File.read(path),
         {:ok, report} <- Jason.decode(body) do
      {:ok, Map.put(report, "matrix", output)}
    else
      _ -> {:error, "parity.py wrote no report: #{String.slice(output, -600, 600)}"}
    end
  end

  @doc """
  The verdict for one binding of a report: `{:pass, detail}`, `{:skip, detail}`
  when its only failing rows are known defects, or `{:fail, detail}`.
  """
  @spec verdict(map(), String.t()) :: {:pass | :skip | :fail, String.t()}
  def verdict(report, binding) do
    rows = Enum.filter(report["rows"], &(&1["binding"] == binding))
    by = Enum.group_by(rows, & &1["status"])
    failed = Map.get(by, "fail", [])
    known = Map.get(by, "known", [])
    passed = length(Map.get(by, "pass", []))

    cond do
      rows == [] ->
        {:fail, "the parity report holds no row for #{binding}"}

      failed != [] ->
        first = hd(failed)

        {:fail,
         "#{length(failed)} of #{length(rows)} rows fail; first: #{first["operation"]} | " <>
           "#{first["vector"]} | #{first["check"]}: #{String.slice(first["detail"], 0, 300)}"}

      known != [] ->
        findings =
          known |> Enum.map(& &1["finding"]) |> Enum.uniq() |> Enum.sort() |> Enum.join(", ")

        {:skip,
         "#{passed} rows pass byte for byte; #{length(known)} rows are known defects " <>
           "(#{findings} in docs/reference/a2a-v1-1-parity-findings.md)"}

      true ->
        {:pass, "#{passed} rows identical to the upstream v1.1 reference"}
    end
  end
end
