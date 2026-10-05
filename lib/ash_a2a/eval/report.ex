# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Eval.Report do
  @moduledoc """
  Scored eval report: per-case verdicts plus aggregate pass rate and latency
  percentiles, baseline comparison (the eval gate), and JSON encoding.

  Report shape:

      %{
        "generated_at": iso8601,
        "suite": name,
        "url": url,
        "cases": [ %{id, skill, verdict, scorers, latency_ms, error} ],
        "totals": %{pass, fail, total, pass_rate},
        "latency_ms": %{p50, p90, p99}
      }

  Baseline comparison shape (`AshA2A.Eval.compare/2`):

      %{
        baseline: path | null,
        regressions: [ %{id, type, baseline, current} ],
        improvements: [ %{id, baseline, current} ],
        new_cases: [id], missing_cases: [id],
        pass_rate: %{baseline: float | nil, current: float},
        verdict: "PASS" | "REGRESSION"
      }

  Gate semantics: a REGRESSION verdict is a case that PASSED in the baseline
  and FAILS now, or a baseline case that is missing from the current run
  (silent coverage loss fails the gate -- a gate that quietly shrinks its own
  denominator passes everything).
  """

  @doc """
  Folds runner per-case results into the full report map. `suite` supplies
  the suite name; `url` the endpoint the cases ran against.
  """
  @spec finalize([map()], String.t() | nil, String.t()) :: map()
  def finalize(case_results, suite_name, url) do
    latencies =
      case_results
      |> Enum.map(& &1.latency_ms)
      |> Enum.sort()

    %{
      generated_at: DateTime.to_iso8601(DateTime.utc_now()),
      suite: suite_name,
      url: url,
      cases: case_results,
      totals: totals(case_results),
      latency_ms: %{
        p50: percentile(latencies, 50),
        p90: percentile(latencies, 90),
        p99: percentile(latencies, 99)
      }
    }
  end

  @doc """
  Compares a baseline report (decoded from disk, string keys) against the
  current report (atom keys, as built by `finalize/3`). Accepts either key
  shape on both sides.
  """
  @spec compare(map(), map(), keyword()) :: map()
  def compare(baseline, current, opts \\ []) do
    baseline_cases = index_cases(baseline)
    current_cases = index_cases(current)

    regressions =
      Enum.flat_map(baseline_cases, fn {id, base} ->
        case Map.fetch(current_cases, id) do
          {:ok, now} ->
            if base.verdict == "PASS" and now.verdict == "FAIL" do
              [%{id: id, type: :regression, baseline: "PASS", current: "FAIL"}]
            else
              []
            end

          :error ->
            [%{id: id, type: :missing_case, baseline: base.verdict, current: nil}]
        end
      end)

    improvements =
      for {id, base} <- baseline_cases,
          now = Map.get(current_cases, id),
          base.verdict == "FAIL" and now.verdict == "PASS" do
        %{id: id, baseline: "FAIL", current: "PASS"}
      end

    new_cases = Enum.sort(Map.keys(current_cases) -- Map.keys(baseline_cases))
    missing_cases = for r <- regressions, r.type == :missing_case, do: r.id

    base_rate = pass_rate_of(baseline)
    curr_rate = pass_rate_of(current)

    %{
      baseline: Keyword.get(opts, :baseline_path),
      regressions: Enum.sort_by(regressions, & &1.id),
      improvements: Enum.sort_by(improvements, & &1.id),
      new_cases: new_cases,
      missing_cases: missing_cases,
      pass_rate: %{baseline: base_rate, current: curr_rate},
      verdict: if(regressions == [], do: "PASS", else: "REGRESSION")
    }
  end

  @doc "Nearest-rank percentile over an ascending list; `nil` for empty input."
  @spec percentile([number()], number()) :: float() | nil
  def percentile([], _p), do: nil

  def percentile([single], _p), do: single * 1.0

  def percentile(sorted, p) do
    n = length(sorted)
    idx = p / 100 * (n - 1)
    lo = floor(idx)
    hi = ceil(idx)

    if lo == hi do
      value_at(sorted, lo) * 1.0
    else
      lo_v = value_at(sorted, lo) * 1.0
      hi_v = value_at(sorted, hi) * 1.0
      lo_v + (hi_v - lo_v) * (idx - lo)
    end
  end

  defp value_at(list, idx) when is_integer(idx), do: Enum.fetch!(list, idx)

  defp totals(case_results) do
    pass = Enum.count(case_results, &(&1.verdict == "PASS"))
    total = length(case_results)

    %{
      pass: pass,
      fail: total - pass,
      total: total,
      pass_rate: if(total == 0, do: 0.0, else: pass / total * 1.0)
    }
  end

  defp index_cases(report) do
    report
    |> fetch_field("cases", [])
    |> Enum.map(fn c ->
      {fetch_field(c, "id", nil), %{verdict: fetch_field(c, "verdict", nil)}}
    end)
    |> Map.new()
  end

  defp pass_rate_of(report) do
    case fetch_field(report, "totals", nil) do
      %{} = totals -> fetch_field(totals, "pass_rate", nil)
      _ -> nil
    end
  end

  defp fetch_field(map, key, default) when is_map(map) do
    cond do
      Map.has_key?(map, key) ->
        Map.fetch!(map, key)

      Map.has_key?(map, String.to_existing_atom(key)) ->
        Map.fetch!(map, String.to_existing_atom(key))

      true ->
        default
    end
  end

  defp fetch_field(_other, _key, default), do: default
end
