# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Eval do
  @moduledoc """
  Agent skill evaluation (the AAIF evaluation direction).

  The v1.0 conformance runner (`mix ash_a2a.v1_conformance_report`) proves
  protocol compliance: the agent speaks `message/send`. Evaluation asks the
  NEXT question: **is the agent GOOD at its skills?** This module runs a
  golden-dataset suite of real `message/send` cases against a live agent
  endpoint, scores the artifacts that come back, and emits a scored JSON
  report with an eval gate (baseline regression detection).

      # Run a suite against a live agent and print/write the report
      AshA2A.Eval.run("priv/eval/support_golden.json", url: "http://127.0.0.1:4000")

      # The eval gate: fail on regression against a stored baseline
      report = AshA2A.Eval.run!("suite.json", url: url)
      comparison = AshA2A.Eval.compare(baseline_report, report, baseline_path: "base.json")
      comparison.verdict == "REGRESSION"

  Sub-modules:

    * `AshA2A.Eval.Suite` -- suite JSON loading/validation
    * `AshA2A.Eval.Runner` -- real-transport case execution
    * `AshA2A.Eval.Scorers` -- exact/contains/schema_match/custom scorers
    * `AshA2A.Eval.Report` -- aggregation, percentiles, baseline comparison
    * `Mix.Tasks.AshA2a.Eval` -- `mix ash_a2a.eval --suite PATH`

  Zero mocks: every case is a real HTTP `message/send` round trip against a
  real agent; scorers assert on the artifacts the agent actually produced.
  """

  @doc """
  Loads `suite_path`, runs every case against `url` (overriding the suite's
  own `"url"`), and returns the full report map. Raises on an invalid suite.
  Options: `:timeout_ms` (default per-case receive timeout, 10_000).
  """
  @spec run(String.t() | map(), keyword()) :: map()
  def run(suite_path_or_map, opts) do
    {suite, name} = load_suite(suite_path_or_map)
    url = opts[:url] || suite["url"]
    timeout_ms = opts[:timeout_ms]

    case_results = AshA2A.Eval.Runner.run(suite, url, timeout_ms: timeout_ms)

    AshA2A.Eval.Report.finalize(case_results, name, url)
  end

  @doc "Like `run/2` but takes the already-loaded/validated suite map."
  @spec run_suite(map(), String.t(), keyword()) :: map()
  def run_suite(suite, url, opts \\ []) do
    case_results = AshA2A.Eval.Runner.run(suite, url, opts)
    AshA2A.Eval.Report.finalize(case_results, suite["name"], url)
  end

  @doc """
  Baseline comparison -- the eval gate. `baseline` is a previously stored
  report map (decoded from disk), `current` the fresh report. See
  `AshA2A.Eval.Report.compare/3` for the shape and gate semantics.
  """
  @spec compare(map(), map(), keyword()) :: map()
  def compare(baseline, current, opts \\ []) do
    AshA2A.Eval.Report.compare(baseline, current, opts)
  end

  @doc "Loads + validates a suite file. Raises `ArgumentError` on any problem."
  @spec load_suite!(String.t()) :: map()
  def load_suite!(path) do
    {suite, _name} = load_suite(path)
    suite
  end

  defp load_suite(%{} = suite), do: {suite, suite["name"]}

  defp load_suite(path) when is_binary(path) do
    case AshA2A.Eval.Suite.load(path) do
      {:ok, suite} ->
        {suite, suite["name"]}

      {:error, {:invalid_suite, problems}} ->
        raise ArgumentError,
              "invalid eval suite #{inspect(path)}:\n" <> Enum.join(problems, "\n")

      {:error, reason} ->
        raise ArgumentError, "cannot load eval suite #{inspect(path)}: #{inspect(reason)}"
    end
  end
end
