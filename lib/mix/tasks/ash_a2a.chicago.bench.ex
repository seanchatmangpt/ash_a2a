defmodule Mix.Tasks.AshA2a.Chicago.Bench do
  @shortdoc "Runs the RFC-SA2A-002 benchmarks (all 10 categories, B1-B10)"

  @moduledoc """
  Runs the RFC-SA2A-002 benchmark harness (`AshA2A.Chicago.Bench`) against
  this exact checkout and writes one content-addressed raw result per
  benchmark plus a derived `summary.json`.

      mix ash_a2a.chicago.bench
      mix ash_a2a.chicago.bench --only B1,B9 --iterations 20 --warmup 3 --out tmp/bench
      mix ash_a2a.chicago.bench --verify tmp/bench/SA2A-B5.<sha256>.json

  Options:

    * `--only` -- comma-separated benchmark ids (`B1`..`B10`; default all 10)
    * `--iterations` -- measured iterations per benchmark (default #{AshA2A.Chicago.Bench.default_iterations()})
    * `--warmup` -- warmup iterations, invariant-checked but excluded from
      the distribution (default #{AshA2A.Chicago.Bench.default_warmup()})
    * `--out` -- output directory (default a fresh tmp dir)
    * `--verify` -- re-derive a raw result's digest from disk and exit
      (repeatable); non-zero exit on any mismatch (§135)
    * `--require-measured` -- non-zero exit unless every benchmark is `MEASURED`

  Each raw result carries the exact subject (§5), the §102 environment
  receipt, warmup policy, per-iteration timings, latency distribution,
  throughput, memory, invariant failures, and (B9) OCEL overhead. Invariant
  failures are reported, never hidden (§84).
  """

  use Mix.Task

  alias AshA2A.Chicago.Bench

  @switches [
    only: :string,
    iterations: :integer,
    warmup: :integer,
    out: :string,
    verify: :keep,
    require_measured: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, invalid} = OptionParser.parse(argv, strict: @switches)
    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    case Keyword.get_values(opts, :verify) do
      [] -> execute(opts)
      paths -> verify(paths)
    end
  end

  defp verify(paths) do
    results =
      for path <- paths do
        case Bench.verify_file(path) do
          {:ok, raw} ->
            Mix.shell().info("VERIFIED #{raw["benchmark_id"]} #{path}")
            :ok

          {:error, reason} ->
            Mix.shell().error("REFUSED #{path}: #{inspect(reason)}")
            :error
        end
      end

    if :error in results, do: Mix.raise("raw benchmark result integrity check failed")
  end

  defp execute(opts) do
    Mix.Task.run("app.start")

    only =
      case opts[:only] do
        nil -> nil
        csv -> csv |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
      end

    run_opts =
      [only: only]
      |> put_if(:iterations, opts[:iterations])
      |> put_if(:warmup, opts[:warmup])
      |> put_if(:out, opts[:out] && Path.expand(opts[:out]))

    case Bench.run(run_opts) do
      {:ok, run} ->
        Mix.shell().info("environment identity: #{run.environment["identity"]}")

        for result <- run.results do
          Mix.shell().info(line(result))
        end

        Mix.shell().info("summary: #{run.summary_path}")

        if opts[:require_measured] && Enum.any?(run.results, &(&1["status"] != "MEASURED")) do
          Mix.raise("not every benchmark is MEASURED")
        end

      {:error, reason} ->
        Mix.raise("benchmark run refused: #{inspect(reason)}")
    end
  end

  defp line(%{"status" => "BLOCKED"} = r), do: "#{r["benchmark_id"]}\tBLOCKED\t#{r["detail"]}"

  defp line(r) do
    latency = r["latency_us"] || %{}

    "#{r["benchmark_id"]}\t#{r["status"]}\titerations=#{r["iterations"]}\t" <>
      "p50=#{latency["p50"]}us p90=#{latency["p90"]}us p99=#{latency["p99"]}us max=#{latency["max"]}us\t" <>
      "invariant_failures=#{r["invariant_failure_count"]}\t#{r["raw_result_path"]}"
  end

  defp put_if(opts, _key, nil), do: opts
  defp put_if(opts, key, value), do: Keyword.put(opts, key, value)
end
