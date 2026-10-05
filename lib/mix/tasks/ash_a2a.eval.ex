# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshA2a.Eval do
  @shortdoc "Runs a golden-dataset skill eval suite against a live agent and emits a scored JSON report"

  @moduledoc """
  Runs a golden-dataset eval suite (JSON) against a LIVE agent endpoint --
  every case is a real `message/send` over the real transport -- and emits a
  scored JSON report (per-case verdicts, aggregate pass rate, latency
  percentiles).

  This is the AAIF evaluation direction, one step past the v1.0 conformance
  runner (`mix ash_a2a.v1_conformance_report`): conformance proves the agent
  speaks the protocol; evaluation asks whether the agent is GOOD at its
  skills.

      mix ash_a2a.eval --suite priv/eval/support_golden.json --url http://127.0.0.1:4000
      mix ash_a2a.eval --suite suite.json --url URL --save-baseline baseline.json
      mix ash_a2a.eval --suite suite.json --url URL --baseline baseline.json

  ## Options

    * `--suite PATH` -- (required) the eval suite JSON. See
      `AshA2A.Eval.Suite` for the format.
    * `--url URL` -- agent endpoint; overrides the suite's own `"url"`.
      Required if the suite declares none.
    * `--out PATH` -- also write the JSON report to PATH.
    * `--save-baseline PATH` -- write the report to PATH as the stored
      baseline for a later `--baseline` run.
    * `--baseline PATH` -- compare against a stored baseline report and FAIL
      the run on regression: any case that PASSED in the baseline and now
      FAILS, or any baseline case missing from this run. Exit code 1 on
      regression.
    * `--timeout-ms N` -- default per-case HTTP receive timeout (default
      10000).

  ## Exit status

  Without `--baseline` this is a REPORT task: exit 0 regardless of case
  verdicts (the report is the evidence). With `--baseline` it is a GATE:
  exit 1 on regression (`verdict: "REGRESSION"` in the comparison).

  Suite/scorer formats: `AshA2A.Eval.Suite` and `AshA2A.Eval.Scorers`.
  """

  use Mix.Task

  @switches [
    suite: :string,
    url: :string,
    out: :string,
    save_baseline: :string,
    baseline: :string,
    timeout_ms: :integer
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, switches: @switches, aliases: [s: :suite])

    suite_path = Keyword.get(opts, :suite) || mix_raise("--suite PATH is required")

    suite =
      case AshA2A.Eval.Suite.load(suite_path) do
        {:ok, suite} ->
          suite

        {:error, {:invalid_suite, problems}} ->
          Mix.raise("invalid eval suite #{suite_path}:\n" <> Enum.join(problems, "\n"))

        {:error, reason} ->
          Mix.raise("cannot load eval suite #{suite_path}: #{inspect(reason)}")
      end

    url =
      Keyword.get(opts, :url) || suite["url"] ||
        mix_raise("--url URL is required (suite declares none)")

    report =
      AshA2A.Eval.Runner.run(suite, url, timeout_ms: opts[:timeout_ms])
      |> AshA2A.Eval.Report.finalize(suite["name"], url)

    json = Jason.encode_to_iodata!(jsonable(report), pretty: true)

    write_if_given(opts[:out], json)
    write_if_given(opts[:save_baseline], json)

    totals = report.totals
    latency = report.latency_ms

    Mix.shell().info(
      "eval suite #{suite_path}: #{totals.pass} PASS, #{totals.fail} FAIL, #{totals.total} total " <>
        "(pass_rate #{format_rate(totals.pass_rate)}; latency_ms p50=#{format_rate(latency.p50)} " <>
        "p90=#{format_rate(latency.p90)} p99=#{format_rate(latency.p99)})"
    )

    unless Enum.empty?(report.cases) do
      Enum.each(report.cases, fn case_result ->
        marker = if case_result.verdict == "PASS", do: "PASS", else: "FAIL"

        Mix.shell().info("  [#{marker}] #{case_result.id} (#{case_result.latency_ms} ms)")
      end)
    end

    case Keyword.fetch(opts, :baseline) do
      {:ok, baseline_path} ->
        gate!(baseline_path, report, opts)

      :error ->
        Mix.shell().info(
          "report task: exit 0 (run with --baseline PATH to turn this report into the eval gate)"
        )

        :ok
    end
  end

  # The eval gate: compare against the stored baseline; exit non-zero on
  # regression so CI/mix exits with a real failure status.
  defp gate!(baseline_path, report, _opts) do
    baseline =
      case read_baseline(baseline_path) do
        {:ok, decoded} ->
          decoded

        {:error, reason} ->
          Mix.raise("cannot read baseline #{baseline_path}: #{inspect(reason)}")
      end

    comparison = AshA2A.Eval.Report.compare(baseline, report, baseline_path: baseline_path)

    print_comparison(comparison)

    if comparison.verdict == "REGRESSION" do
      exit({:shutdown, 1})
    else
      Mix.shell().info("eval gate: PASS (no regression vs #{baseline_path})")
      :ok
    end
  end

  defp read_baseline(path) do
    with {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body) do
      {:ok, decoded}
    end
  end

  defp print_comparison(comparison) do
    Mix.shell().info(
      "eval gate vs baseline: pass_rate #{format_rate(comparison.pass_rate.baseline)} -> " <>
        "#{format_rate(comparison.pass_rate.current)}"
    )

    Enum.each(comparison.regressions, fn r ->
      case r.type do
        :regression ->
          Mix.shell().info("  [REGRESSION] #{r.id}: #{r.baseline} -> #{r.current}")

        :missing_case ->
          Mix.shell().info(
            "  [MISSING CASE] #{r.id}: in baseline (#{r.baseline}), absent from this run"
          )
      end
    end)

    Enum.each(comparison.improvements, fn i ->
      Mix.shell().info("  [improved] #{i.id}: #{i.baseline} -> #{i.current}")
    end)

    if comparison.new_cases != [] do
      Mix.shell().info(
        "  [new cases, no baseline verdict] #{Enum.join(comparison.new_cases, ", ")}"
      )
    end
  end

  defp write_if_given(nil, _json), do: :ok

  defp write_if_given(path, json) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, json)
    Mix.shell().info("report written to #{path}")
  end

  # Reports are built with rich in-memory terms (scorer details, transport
  # errors). JSON has no tuple/atom encoding, so the on-disk report renders
  # every non-JSON-safe leaf with inspect/1 -- the wire report is the
  # inspectable evidence; in-process consumers keep the typed terms.
  defp jsonable(%Date{} = d), do: d
  defp jsonable(%DateTime{} = d), do: d
  defp jsonable(v) when is_atom(v), do: v
  defp jsonable(v) when is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v), do: v
  defp jsonable(v) when is_list(v), do: Enum.map(v, &jsonable/1)

  defp jsonable(v) when is_map(v) do
    Map.new(v, fn {k, val} -> {k, jsonable(val)} end)
  end

  defp jsonable(v), do: inspect(v)

  defp format_rate(nil), do: "n/a"
  defp format_rate(rate) when is_float(rate), do: :erlang.float_to_binary(rate, decimals: 3)
  defp format_rate(other), do: to_string(other)

  defp mix_raise(message) do
    Mix.raise(message)
  end
end
