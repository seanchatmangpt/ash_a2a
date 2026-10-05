# SPDX-FileCopyrightText: 2026 ash_a2a v1.0 conformance report contributors
# <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.V1ConformanceReportTest do
  @moduledoc """
  Lane Z10: real-invocation tests for `mix ash_a2a.v1_conformance_report`.

  Chicago-style: no mocks. Each test invokes the real Mix task as a real OS
  subprocess (`System.cmd("mix", [...])`) exactly as an operator would, and
  asserts on the resulting real JSON report file. The full-court run is the
  long-running operator gate and is NOT exercised here; the tests select a
  single fast real court via `--only`, plus the documented empty-result
  contract of a `--only` substring matching no court.
  """

  use ExUnit.Case, async: false

  @task "ash_a2a.v1_conformance_report"

  # The fastest genuinely-existing v1.0 court: the frozen spec-example wire
  # corpus (pure codec decode/encode round-trips over real spec JSON, no
  # transport). Selected via `--only` so the test runs exactly one court.
  @fast_court_substring "v1_spec_corpus"

  @moduletag timeout: 1_800_000

  test "--only selects one real court, runs it, and emits a valid PASS report" do
    out = report_path()

    {stdout, exit_code} =
      System.cmd("mix", [@task, "--only", @fast_court_substring, "--out", out],
        stderr_to_stdout: true
      )

    assert exit_code == 0, "report task exited #{exit_code}: #{stdout}"
    assert File.exists?(out), "no report written to #{out}; stdout was:\n#{stdout}"

    report = out |> File.read!() |> Jason.decode!()

    assert is_binary(report["generated_at"])
    assert is_binary(report["elixir_version"])

    # `--only v1_spec_corpus` selects exactly the spec-corpus court.
    assert [%{"file" => file} = court] = report["courts"]
    assert file =~ "ash_a2a_v1_spec_corpus_test.exs"

    assert court["exit_code"] == 0
    assert court["verdict"] == "PASS"
    assert court["summary_line"] =~ ~r/\d+ tests?, 0 failures?/

    # Totals consistency: the report's own arithmetic must close.
    assert report["totals"] == %{"pass" => 1, "fail" => 0, "total" => 1}
    assert Enum.count(report["courts"], &(&1["verdict"] == "PASS")) == report["totals"]["pass"]
    assert Enum.count(report["courts"], &(&1["verdict"] == "FAIL")) == report["totals"]["fail"]
    assert report["totals"]["pass"] + report["totals"]["fail"] == report["totals"]["total"]
  end

  test "--only with a substring matching no court yields the documented empty-result contract" do
    out = report_path()

    {stdout, exit_code} =
      System.cmd("mix", [@task, "--only", "no-such-court-substring-z10", "--out", out],
        stderr_to_stdout: true
      )

    assert exit_code == 0, "report task exited #{exit_code}: #{stdout}"

    report = out |> File.read!() |> Jason.decode!()

    assert report["courts"] == []
    assert report["totals"] == %{"pass" => 0, "fail" => 0, "total" => 0}
    assert is_binary(report["generated_at"])
    assert is_binary(report["elixir_version"])
  end

  # -- helpers --

  defp report_path do
    Path.join(
      System.tmp_dir!(),
      "v1-conformance-report-#{System.unique_integer([:positive])}.json"
    )
  end
end
