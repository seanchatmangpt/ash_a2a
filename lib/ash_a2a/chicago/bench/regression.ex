defmodule AshA2A.Chicago.Bench.Regression do
  @moduledoc """
  RFC-SA2A-002 §122 benchmark regression policy over two raw results.

    * Results are comparable only when the benchmark id and the §102
      environment identity are equal -- numbers from different environments
      are refused, never compared as if they measured the same subject.
      Different exact subjects ARE comparable (that is what a regression check
      is); both subject identities are carried into the report.
    * A correctness regression always outranks a performance change: any
      invariant failure in the candidate yields `"verdict" => "CORRECTNESS_REGRESSION"`
      regardless of latency.
    * A performance regression alone does not invalidate conformance unless it
      violates an admitted bound (`:bounds`, e.g. `%{"latency_us.p99" => 5_000}`),
      which yields `"BOUND_VIOLATED"`; otherwise `"WITHIN_BOUNDS"`.
  """

  @compared ["min", "p50", "p90", "p95", "p99", "max", "mean"]

  @doc """
  Compares `candidate` against `baseline` (both raw result maps, e.g. from
  `AshA2A.Chicago.Bench.verify_file/1`). Options: `:bounds` --
  `%{"latency_us.<stat>" => max_microseconds}` admitted bounds on the candidate.
  """
  @spec compare(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def compare(baseline, candidate, opts \\ []) when is_map(baseline) and is_map(candidate) do
    mismatched =
      [
        {"benchmark_id", baseline["benchmark_id"], candidate["benchmark_id"]},
        {"environment.identity", get_in(baseline, ["environment", "identity"]),
         get_in(candidate, ["environment", "identity"])}
      ]
      |> Enum.filter(fn {_field, a, b} -> is_nil(a) or is_nil(b) or a != b end)
      |> Enum.map(&elem(&1, 0))

    if mismatched == [] do
      {:ok, report(baseline, candidate, Keyword.get(opts, :bounds, %{}))}
    else
      {:error, {:not_comparable, mismatched}}
    end
  end

  defp report(baseline, candidate, bounds) do
    base = baseline["latency_us"] || %{}
    cand = candidate["latency_us"] || %{}

    deltas =
      for stat <- @compared, is_number(base[stat]) and is_number(cand[stat]), into: %{} do
        {stat,
         %{
           "baseline" => base[stat],
           "candidate" => cand[stat],
           "delta" => cand[stat] - base[stat]
         }}
      end

    violations =
      bounds
      |> Enum.sort()
      |> Enum.flat_map(fn
        {"latency_us." <> stat = key, max} when is_number(max) ->
          value = cand[stat]

          if is_number(value) and value > max,
            do: [%{"bound" => key, "admitted_max" => max, "observed" => value}],
            else: []

        _other ->
          []
      end)

    failures = candidate["invariant_failure_count"] || 0

    verdict =
      cond do
        failures > 0 -> "CORRECTNESS_REGRESSION"
        violations != [] -> "BOUND_VIOLATED"
        true -> "WITHIN_BOUNDS"
      end

    %{
      "benchmark_id" => candidate["benchmark_id"],
      "verdict" => verdict,
      "environment_identity" => get_in(candidate, ["environment", "identity"]),
      "baseline_subject_identity" => get_in(baseline, ["exact_subject", "identity"]),
      "candidate_subject_identity" => get_in(candidate, ["exact_subject", "identity"]),
      "latency_deltas_us" => deltas,
      "bound_violations" => violations,
      "candidate_invariant_failures" => failures
    }
  end
end
