# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshA2a.V1ConformanceReport do
  @shortdoc "Runs every A2A v1.0 conformance court plus the v1.1 court list and emits a machine-readable JSON verdict report"

  @moduledoc """
  One command that runs every A2A v1.0 conformance court in this repo and
  emits a machine-readable JSON verdict report.

      mix ash_a2a.v1_conformance_report
      mix ash_a2a.v1_conformance_report --out receipts/v1-conformance.json
      mix ash_a2a.v1_conformance_report --only v1_pagination
      mix ash_a2a.v1_conformance_report --tck-report /tmp/a2a-tck/reports/compatibility.json

  ## Relation to the conformance statement and the official TCK

  `docs/reference/a2a-v1-conformance.md` ("What is not claimed") states that
  A2A TCK certification is NOT claimed: the official `a2aproject/a2a-tck`
  compatibility suite has been run point-in-time against this implementation
  (see `docs/reference/tck-suite.md`), and `CONFORMANT` means "the pinned
  court in this repo passes", not TCK-certified.

  This task is the in-repo operator instrument: it executes every v1.0
  conformance court (plus the companion v1 court files) and reduces them to
  one JSON document. **This task does NOT run the official TCK** and a
  full-PASS report here does not make the implementation TCK-certified.
  With `--tck-report PATH` it additionally ingests an already-produced TCK
  `compatibility.json` and records its `{pass, fail, not_tested, skipped,
  manual}` counts under the report's `tck` key (counts only; no percentage
  headline, no pass/fail judgment on the TCK).

  ## What it does

  1. Derives the court list from a glob of `test/ash_a2a_v1_*_test.exs`
     minus the explicit exclusions (`excluded_v1_files/0`); there is no
     hand-maintained list or count, so a new court file is run, never
     silently skipped.
  2. Verifies each entry against the real filesystem at runtime; an entry
     that no longer exists on disk becomes a court-status entry with
     `verdict: "FAIL"` and `exit_code: null` (a court you cannot execute is
     not a court that passed).
  3. Runs each existing court as a REAL OS subprocess
     (`mix test <file> --include serial`), capturing the exit code and the
     ExUnit summary line.
  4. Adds the explicit A2A v1.1 court list (`v1_1_courts/0`: `x1`..`x5`,
     `v1_1_codec`, `v2`..`v14` generation/live files, `b3_v11_courts`,
     `t1_downgrade_wire`), subject to the same runtime existence check.
  5. Writes the JSON report: `%{generated_at, elixir_version, courts,
     totals}`, where `courts` is a list of `%{file, exit_code, summary_line,
     verdict: "PASS" | "FAIL"}` and `totals` is `%{pass, fail, total}`.

  ## Options

    * `--out PATH` -- write the JSON report to PATH (in addition to stdout).
    * `--tck-report PATH` -- ingest a TCK `compatibility.json` (tolerant
      reader: counts status-bearing records, or aggregate count objects)
      into the report's `tck` key. An unreadable/unrecognized file is
      recorded as `tck: %{source, error}`, never silently dropped.
    * `--only SUBSTRING` -- run only courts whose file name contains
      SUBSTRING. Used for iteration; also the documented empty-result path:
      a substring matching no court produces a valid report with
      `courts: []` and `totals.total == 0` and still exits 0, because a
      report over zero selected courts is a well-formed empty report, not
      an error.

  ## Exit status

  This is a REPORT task, not a gate: it always exits 0. The gate is the
  JSON itself -- `totals.fail == 0` is the operator's conformance check.

  ## Runtime expectation

  The full run executes every v1.0 court, including the `:serial` tail
  (real Bandit loopback listeners, shared transports). Expect a LONG run --
  minutes to tens of minutes, the same order as the suite's serial tail
  (see `mix.exs`' `test.all` alias comment for the measured wall-clock
  order). This is the operator gate, so the slowness is the point; use
  `--only` to iterate on a subset.

  ## Maintaining the court list

  Nothing to maintain: `v1_courts/0` globs `test/ash_a2a_v1_*_test.exs`
  (relative to the working directory, the repo root) and subtracts
  `excluded_v1_files/0`. A new v1 court file is picked up automatically;
  a file that should not be a court must be added to the exclusion list
  below with a reason.
  """

  use Mix.Task

  @v1_glob "test/ash_a2a_v1_*_test.exs"

  # Deliberately NOT courts (see `@excluded_v1_files` below):
  #
  #   * test/ash_a2a_v1_conformance_report_test.exs -- the runner's own
  #     self-test (it invokes THIS task as a subprocess); not a v1.0 protocol
  #     conformance court, and listing it would make the report recurse.
  #
  #   * test/ash_a2a_v1_check_gate_serial_test.exs -- exercises the serial
  #     check-gate tooling (mix alias / CI gate wiring), not A2A v1.0 protocol
  #     behavior; it is a build-gate self-check, not a protocol conformance court.
  #
  #   * test/ash_a2a_zach_courts_test.exs -- adversarial extension courts over
  #     the DSL/executor surface (non-vacuity, ToA2AError totality, executor
  #     dispatch). They exercise v1.0 APIs but are extension courts, not v1.0
  #     protocol conformance; the report's scope is protocol conformance only.

  @switches [out: :string, only: :string, tck_report: :string]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, switches: @switches)

    all_courts = all_courts()

    selected =
      case Keyword.get(opts, :only) do
        nil -> all_courts
        substring -> Enum.filter(all_courts, &String.contains?(&1, substring))
      end

    Mix.shell().info(
      "A2A v1.0 conformance courts selected: #{length(selected)} of #{length(all_courts)} " <>
        "(this is NOT the official A2A TCK; see docs/reference/a2a-v1-conformance.md)"
    )

    courts = Enum.map(selected, &run_court/1)

    totals = %{
      pass: Enum.count(courts, &(&1.verdict == "PASS")),
      fail: Enum.count(courts, &(&1.verdict == "FAIL")),
      total: length(courts)
    }

    report = %{
      generated_at: DateTime.to_iso8601(DateTime.utc_now()),
      elixir_version: to_string(System.version()),
      courts: courts,
      totals: totals
    }

    report =
      case Keyword.get(opts, :tck_report) do
        nil -> report
        path -> Map.put(report, :tck, ingest_tck_report(path))
      end

    json = Jason.encode_to_iodata!(report, pretty: true)

    case Keyword.get(opts, :out) do
      nil ->
        Mix.shell().info(IO.iodata_to_binary(json))

      path ->
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, json)
        Mix.shell().info("machine report written to #{path}")
    end

    Mix.shell().info(
      "totals: #{totals.pass} PASS, #{totals.fail} FAIL, #{totals.total} total " <>
        "(report task: exit 0 regardless; the gate is totals.fail == 0)"
    )

    :ok
  end

  # Runs one court as a real OS subprocess. A missing court file becomes a
  # FAIL court-status entry (nothing was executed, so nothing passed).
  defp run_court(court) do
    unless File.exists?(Path.expand(court, File.cwd!())) do
      %{
        file: court,
        exit_code: nil,
        summary_line: "court file missing on disk",
        verdict: "FAIL"
      }
    else
      {output, exit_code} =
        System.cmd("mix", ["test", court, "--include", "serial"],
          stderr_to_stdout: true,
          env: mix_subprocess_env()
        )

      %{
        file: court,
        exit_code: exit_code,
        summary_line: summary_line(output),
        verdict: if(exit_code == 0, do: "PASS", else: "FAIL")
      }
    end
  end

  # The subprocess reuses the parent's MIX_BUILD_ROOT when the parent set
  # one (lane build isolation propagates), and always runs in the test
  # environment so the court sees the real test config.
  defp mix_subprocess_env do
    env =
      case System.get_env("MIX_BUILD_ROOT") do
        nil -> %{}
        root -> %{"MIX_BUILD_ROOT" => root}
      end

    Map.put(env, "MIX_ENV", "test")
  end

  # ExUnit's summary line, e.g. "12 tests, 0 failures",
  # "5 tests, 2 failures, 1 skipped", or a property-based court's
  # "16 properties, 0 failures". Falls back to the last non-empty
  # output line when no summary was printed (e.g. compile error).
  defp summary_line(output) do
    output
    |> String.split("\n")
    |> Enum.reverse()
    |> Enum.find(fn line ->
      Regex.match?(~r/\d+ (tests?|properties), \d+ failures?/, line) or
        Regex.match?(~r/Result:\s+\d+(\/\d+)?\s+passed/, line)
    end)
    |> case do
      nil -> output |> String.split("\n") |> Enum.reject(&(&1 == "")) |> List.last("")
      line -> String.trim(line)
    end
  end

  # Explicit exclusions from the census (see the comment above for
  # reasons). Every test/ash_a2a_v1_*_test.exs file is a court unless it is
  # listed here.
  @excluded_v1_files [
    "test/ash_a2a_v1_check_gate_serial_test.exs",
    "test/ash_a2a_v1_conformance_report_test.exs"
  ]

  @doc false
  def excluded_v1_files, do: @excluded_v1_files

  # A2A v1.1 court files outside the `ash_a2a_v1_*` glob. Listed explicitly;
  # the runtime existence check in `run_court/1` turns a missing entry into a
  # FAIL, so a renamed or deleted file is never a silent pass.
  @v1_1_courts [
    "test/b3_v11_courts_test.exs",
    "test/t1_downgrade_wire_test.exs",
    "test/v1_1_codec_test.exs",
    "test/v10_grpc_live_test.exs",
    "test/v11_client_generation_test.exs",
    "test/v11_client_live_test.exs",
    "test/v12_plug_wiring_test.exs",
    "test/v13_sse_generation_test.exs",
    "test/v14_http_json_live_core_test.exs",
    "test/v2_generation_test.exs",
    "test/v3_generation_ash_test.exs",
    "test/v4_push_version_test.exs",
    "test/v4_stream_generation_test.exs",
    "test/v5_live_session_test.exs",
    "test/v6_generation_test.exs",
    "test/v9_http_json_v11_test.exs",
    "test/x1_artifact_only_generation_test.exs",
    "test/x2_grpc_v11_gaps_test.exs",
    "test/x3_email_hardening_test.exs",
    "test/x4_state_and_longpoll_test.exs",
    "test/x5_generation_durability_test.exs"
  ]

  @doc "A2A v1.1 court files outside the `ash_a2a_v1_*` glob (explicit list)."
  def v1_1_courts, do: @v1_1_courts

  @doc """
  Court files: the v1 glob minus the explicit exclusions (sorted). The report
  runs `all_courts/0` (this list plus the explicit v1.1 list).
  """
  def v1_courts do
    (Path.wildcard(@v1_glob) -- @excluded_v1_files) |> Enum.sort()
  end

  @doc "Every court the report runs: `v1_courts/0` plus `v1_1_courts/0` (sorted, unique)."
  def all_courts, do: (v1_courts() ++ @v1_1_courts) |> Enum.uniq() |> Enum.sort()

  @tck_statuses %{
    "PASS" => :pass,
    "PASSED" => :pass,
    "FAIL" => :fail,
    "FAILED" => :fail,
    "ERROR" => :fail,
    "NOT_TESTED" => :not_tested,
    "NOT_RUN" => :not_tested,
    "UNTESTED" => :not_tested,
    "SKIP" => :skipped,
    "SKIPPED" => :skipped,
    "MANUAL" => :manual
  }
  @tck_zero %{pass: 0, fail: 0, not_tested: 0, skipped: 0, manual: 0}

  # Tolerant ingest of a TCK compatibility.json: count status-bearing
  # records anywhere in the document; when there are none, fall back to
  # outermost aggregate count objects. Unreadable / unrecognized input is
  # reported as an error entry, never dropped.
  defp ingest_tck_report(path) do
    with {:ok, bin} <- File.read(path),
         {:ok, doc} <- Jason.decode(bin) do
      case tck_records(doc, []) do
        [] ->
          case tck_aggregates(doc, %{}) do
            counts when map_size(counts) == 0 ->
              %{source: path, error: "no requirement records or counts recognized"}

            counts ->
              Map.merge(%{source: path, kind: "aggregate"}, Map.merge(@tck_zero, counts))
          end

        recs ->
          counts = Enum.frequencies(recs)
          Map.merge(%{source: path, kind: "records"}, Map.merge(@tck_zero, counts))
      end
    else
      {:error, reason} -> %{source: path, error: "unreadable: #{inspect(reason)}"}
    end
  end

  defp tck_status(value) when is_binary(value) do
    Map.get(@tck_statuses, value |> String.trim() |> String.upcase() |> String.replace(~r/[ -]/, "_"))
  end

  defp tck_status(_), do: nil

  defp tck_records(%{} = node, acc) do
    own =
      Enum.find_value(["status", "result", "outcome", "verdict"], fn k ->
        tck_status(Map.get(node, k))
      end)

    if own,
      do: [own | acc],
      else: Enum.reduce(Map.values(node), acc, &tck_records/2)
  end

  defp tck_records(list, acc) when is_list(list), do: Enum.reduce(list, acc, &tck_records/2)
  defp tck_records(_, acc), do: acc

  defp tck_aggregates(%{} = node, acc) do
    counts =
      for {k, v} <- node, is_integer(v), s = tck_status(k), reduce: %{} do
        m ->
          case Map.fetch(m, s) do
            {:ok, cur} -> Map.put(m, s, cur + v)
            :error -> Map.put(m, s, v)
          end
      end

    if map_size(counts) > 0,
      do: Map.merge(acc, counts, fn _k, a, b -> a + b end),
      else: Enum.reduce(Map.values(node), acc, &tck_aggregates/2)
  end

  defp tck_aggregates(list, acc) when is_list(list), do: Enum.reduce(list, acc, &tck_aggregates/2)
  defp tck_aggregates(_, acc), do: acc
end
