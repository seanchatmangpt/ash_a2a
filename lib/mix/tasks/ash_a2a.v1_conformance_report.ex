# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshA2a.V1ConformanceReport do
  @shortdoc "Runs every A2A v1.0 conformance court and emits a machine-readable JSON verdict report"

  @moduledoc """
  One command that runs every A2A v1.0 conformance court in this repo and
  emits a machine-readable JSON verdict report.

      mix ash_a2a.v1_conformance_report
      mix ash_a2a.v1_conformance_report --out receipts/v1-conformance.json
      mix ash_a2a.v1_conformance_report --only v1_pagination

  ## Relation to the conformance statement and the official TCK

  `docs/reference/a2a-v1-conformance.md` ("What is not claimed") states:
  **"A2A TCK conformance: UNSUPPORTED. The official A2A protocol conformance
  suite / TCK has not been run against this implementation. `CONFORMANT`
  means 'the pinned court in this repo passes', not TCK-certified."**

  This task is the next-best operator instrument: it executes every pinned
  v1.0 conformance court the statement cites (plus the companion v1 court
  files), and reduces them to one JSON document. **This is NOT the A2A
  project's official TCK** and a full-PASS report here does not make the
  implementation TCK-certified; it witnesses the same executed courts the
  statement cites.

  ## What it does

  1. Takes the maintained court list in this module (`@v1_courts`).
  2. Verifies each entry against the real filesystem at runtime; an entry
     that no longer exists on disk becomes a court-status entry with
     `verdict: "FAIL"` and `exit_code: null` (a court you cannot execute is
     not a court that passed).
  3. Runs each existing court as a REAL OS subprocess
     (`mix test <file> --include serial`), capturing the exit code and the
     ExUnit summary line.
  4. Writes the JSON report: `%{generated_at, elixir_version, courts,
     totals}`, where `courts` is a list of `%{file, exit_code, summary_line,
     verdict: "PASS" | "FAIL"}` and `totals` is `%{pass, fail, total}`.

  ## Options

    * `--out PATH` -- write the JSON report to PATH (in addition to stdout).
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

  `@v1_courts` below is the maintained list of v1.0 court files. When a
  court file is added, renamed or removed under `test/ash_a2a_v1_*.exs`,
  update the list; the runtime filesystem check (step 2) keeps an honest
  report when the list and the disk disagree.
  """

  use Mix.Task

  # Maintained list of the A2A v1.0 conformance court files, relative to the
  # repo root. Keep in sync with docs/reference/a2a-v1-conformance.md and
  # test/ash_a2a_v1_*.exs on disk. The runtime existence check reports any
  # drift as a FAIL court-status entry instead of crashing.
  @v1_courts [
    "test/ash_a2a_v1_architecture_test.exs",
    "test/ash_a2a_v1_artifact_streaming_test.exs",
    "test/ash_a2a_v1_auth_challenge_test.exs",
    # DY3: agent-card signing courts (CARD-SIGN-001..004 — the four
    # NOT_AUTOMATABLE TCK requirements, exercised against the real
    # CardSigning machinery; see the file header).
    "test/ash_a2a_v1_card_signing_test.exs",
    "test/ash_a2a_v1_binding_mismatch_test.exs",
    "test/ash_a2a_v1_cancellation_test.exs",
    "test/ash_a2a_v1_conformance_test.exs",
    "test/ash_a2a_v1_context_continuity_test.exs",
    "test/ash_a2a_v1_error_registry_test.exs",
    "test/ash_a2a_v1_extended_httpjson_test.exs",
    "test/ash_a2a_v1_io_modes_test.exs",
    "test/ash_a2a_v1_list_decode_test.exs",
    "test/ash_a2a_v1_multinode_continuity_test.exs",
    "test/ash_a2a_v1_oban_delivery_test.exs",
    "test/ash_a2a_v1_owner_scope_test.exs",
    "test/ash_a2a_v1_pagination_test.exs",
    # Z16: protojson wire fidelity against the vendored official v1.0 IDL
    # (priv/a2a_v1_spec_corpus/a2a.proto) -- protocol conformance, in scope.
    "test/ash_a2a_v1_proto_fidelity_test.exs",
    "test/ash_a2a_v1_push_httpjson_test.exs",
    "test/ash_a2a_v1_rejected_state_test.exs",
    # Z24: agent-card securityRequirements v1.0 decode/encode name fidelity
    # against the vendored official IDL -- protocol conformance, in scope.
    "test/ash_a2a_v1_security_requirements_test.exs",
    "test/ash_a2a_v1_spec_corpus_test.exs",
    "test/ash_a2a_v1_sse_replay_test.exs",
    "test/ash_a2a_v1_state_properties_test.exs",
    "test/ash_a2a_v1_taskstore_durability_test.exs",
    "test/ash_a2a_v1_telemetry_test.exs",
    "test/ash_a2a_v1_wire_properties_test.exs"
  ]

  # Deliberately NOT in @v1_courts:
  #
  #   * test/ash_a2a_v1_conformance_report_test.exs -- the runner's own
  #     self-test (it invokes THIS task as a subprocess); not a v1.0 protocol
  #     conformance court, and listing it would make the report recurse.
  #
  #   * test/ash_a2a_zach_courts_test.exs -- adversarial extension courts over
  #     the DSL/executor surface (non-vacuity, ToA2AError totality, executor
  #     dispatch). They exercise v1.0 APIs but are extension courts, not v1.0
  #     protocol conformance; the report's scope is protocol conformance only.

  @switches [out: :string, only: :string]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, switches: @switches)

    selected =
      case Keyword.get(opts, :only) do
        nil -> @v1_courts
        substring -> Enum.filter(@v1_courts, &String.contains?(&1, substring))
      end

    Mix.shell().info(
      "A2A v1.0 conformance courts selected: #{length(selected)} of #{length(@v1_courts)} " <>
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

  @doc false
  def v1_courts, do: @v1_courts
end
