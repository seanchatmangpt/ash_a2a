defmodule AshA2A.Chicago.Bench do
  @moduledoc """
  RFC-SA2A-002 benchmark harness (§84, §102, §122, §135, Appendix E).

  Benchmarks are subordinate to correctness (§84): every sample a benchmark
  step produces carries a semantic invariant verdict, checked on warmup AND
  measured iterations, and an invariant failure is recorded in the raw result
  (`"invariant_failures"`) -- it is never dropped from the distribution and a
  benchmark with one is never reported as `MEASURED`.

  ## Pieces

    * `measure/2` -- warmup policy, iterations, per-iteration timings, latency
      distribution (min/p50/p90/p95/p99/max/mean/stddev -- means alone never
      hide the tail), throughput, `:erlang.memory/0` and process-heap deltas,
      VM CPU runtime and reductions, invariant failures
    * `record/3` -- the Appendix E record: benchmark id, exact subject (§5),
      profile, environment identity (`AshA2A.Chicago.Bench.Environment`, §102)
    * `write!/2` + `verify_file/1` -- the raw machine-readable result written
      content-addressed; editing it after generation invalidates its digest
      (§135)
    * `run/1` -- runs all benchmarks and writes raw results plus a derived
      summary (`mix ash_a2a.chicago.bench`)
    * `AshA2A.Chicago.Bench.Regression` -- §122 comparison across records

  Benchmarks (all 10 RFC-SA2A-002 categories):
  `AshA2A.Chicago.Bench.B1Admission` (`SA2A-B1`),
  `AshA2A.Chicago.Bench.B2LogicClosure` (`SA2A-B2`),
  `AshA2A.Chicago.Bench.B3HookReflex` (`SA2A-B3`),
  `AshA2A.Chicago.Bench.B4Planning` (`SA2A-B4`),
  `AshA2A.Chicago.Bench.B5Authority` (`SA2A-B5`),
  `AshA2A.Chicago.Bench.B6ReactiveCascade` (`SA2A-B6`),
  `AshA2A.Chicago.Bench.B7CrossRuntime` (`SA2A-B7`),
  `AshA2A.Chicago.Bench.B8Replay` (`SA2A-B8`),
  `AshA2A.Chicago.Bench.B9OcelOverhead` (`SA2A-B9`),
  `AshA2A.Chicago.Bench.B10Recovery` (`SA2A-B10`). The qualification court is
  `AshA2A.Chicago.Courts.Benchmarks` (`SA2A-BENCH`).
  """

  alias AshA2A.Chicago.{Json, Profile, Subject}
  alias AshA2A.Chicago.Bench.{
    B1Admission,
    B2LogicClosure,
    B3HookReflex,
    B4Planning,
    B5Authority,
    B6ReactiveCascade,
    B7CrossRuntime,
    B8Replay,
    B9OcelOverhead,
    B10Recovery,
    Environment
  }

  @schema "ash_a2a.chicago.bench_result/1"
  @specification "RFC-SA2A-002-v26.9.16"

  @benchmarks [
    {"B1", B1Admission},
    {"B2", B2LogicClosure},
    {"B3", B3HookReflex},
    {"B4", B4Planning},
    {"B5", B5Authority},
    {"B6", B6ReactiveCascade},
    {"B7", B7CrossRuntime},
    {"B8", B8Replay},
    {"B9", B9OcelOverhead},
    {"B10", B10Recovery}
  ]

  @default_iterations 10
  @default_warmup 2

  @typedoc """
  One timed unit of benchmark work.

    * `:case` -- which case/scenario (reported separately)
    * `:duration_us` -- measured latency
    * `:outcome` -- what the real SUT decided (e.g. `"admitted"`, `"refused"`)
    * `:phases` -- `%{phase => microseconds}` splits of `:duration_us`
    * `:invariant` -- `:ok` or `{:error, detail}` (§84)
  """
  @type sample :: %{
          required(:case) => String.t(),
          required(:duration_us) => non_neg_integer(),
          required(:invariant) => :ok | {:error, String.t()},
          optional(:outcome) => String.t(),
          optional(:phases) => %{String.t() => integer() | nil}
        }

  @type step :: (:warmup | :measured, pos_integer() -> [sample()])

  @spec schema() :: String.t()
  def schema, do: @schema

  @doc "`[{short_id, module}]` for every benchmark this harness implements."
  @spec benchmarks() :: [{String.t(), module()}]
  def benchmarks, do: @benchmarks

  @spec default_iterations() :: pos_integer()
  def default_iterations, do: @default_iterations

  @spec default_warmup() :: non_neg_integer()
  def default_warmup, do: @default_warmup

  # --- measurement -----------------------------------------------------------

  @doc """
  Runs `step` `:warmup` times (samples discarded from the distribution, but
  their invariant failures kept), garbage-collects, then runs it `:iterations`
  times and summarizes.

  Options: `:iterations` (default #{@default_iterations}), `:warmup` (default
  #{@default_warmup}).
  """
  @spec measure(step(), keyword()) :: map()
  def measure(step, opts \\ []) when is_function(step, 2) do
    iterations = max(Keyword.get(opts, :iterations, @default_iterations), 1)
    warmup = max(Keyword.get(opts, :warmup, @default_warmup), 0)

    warmup_samples =
      for i <- 1..warmup//1, sample <- step.(:warmup, i), do: Map.put(sample, :iteration, i)

    :erlang.garbage_collect()
    memory_before = Map.new(:erlang.memory())
    process_before = process_snapshot(self())
    {runtime_before, _} = :erlang.statistics(:runtime)
    {reductions_before, _} = :erlang.statistics(:reductions)
    started = System.monotonic_time(:microsecond)

    samples =
      for i <- 1..iterations//1, sample <- step.(:measured, i), do: Map.put(sample, :iteration, i)

    wall_us = max(System.monotonic_time(:microsecond) - started, 1)
    {runtime_after, _} = :erlang.statistics(:runtime)
    {reductions_after, _} = :erlang.statistics(:reductions)
    process_after = process_snapshot(self())
    memory_after = Map.new(:erlang.memory())

    failures =
      invariant_failures(warmup_samples, "warmup") ++ invariant_failures(samples, "measured")

    %{
      "iterations" => iterations,
      "warmup_policy" => %{
        "warmup_iterations" => warmup,
        "warmup_samples" => length(warmup_samples),
        "warmup_samples_in_distribution" => false,
        "invariants_checked_during_warmup" => true,
        "garbage_collect_before_measurement" => true
      },
      "sample_count" => length(samples),
      "samples" => Enum.map(samples, &sample_to_map/1),
      "latency_us" => distribution(Enum.map(samples, & &1.duration_us)),
      "by_case" => by_case(samples),
      "throughput" => %{
        "wall_us" => wall_us,
        "samples_per_second" => per_second(length(samples), wall_us)
      },
      "memory" => %{
        "erlang_memory_before_bytes" => stringify(memory_before),
        "erlang_memory_after_bytes" => stringify(memory_after),
        "erlang_memory_delta_bytes" =>
          Map.new(memory_after, fn {k, v} ->
            {Atom.to_string(k), v - Map.get(memory_before, k, 0)}
          end),
        "measuring_process_before" => process_before,
        "measuring_process_after" => process_after,
        "measuring_process_memory_delta_bytes" =>
          process_after["memory"] - process_before["memory"]
      },
      "cpu" => %{
        "vm_runtime_ms" => runtime_after - runtime_before,
        "vm_reductions" => reductions_after - reductions_before
      },
      "invariant_failure_count" => length(failures),
      "invariant_failures" => failures
    }
  end

  @doc """
  Nearest-rank latency distribution over integer samples (microseconds).
  An empty list reports `"n" => 0` and no statistics (never invented zeros).
  """
  @spec distribution([number()]) :: map()
  def distribution([]), do: %{"n" => 0}

  def distribution(values) when is_list(values) do
    sorted = Enum.sort(values)
    n = length(sorted)
    tuple = List.to_tuple(sorted)
    mean = Enum.sum(sorted) / n
    variance = Enum.reduce(sorted, 0.0, fn v, acc -> acc + (v - mean) * (v - mean) end) / n

    %{
      "n" => n,
      "min" => elem(tuple, 0),
      "p50" => rank(tuple, n, 50),
      "p90" => rank(tuple, n, 90),
      "p95" => rank(tuple, n, 95),
      "p99" => rank(tuple, n, 99),
      "max" => elem(tuple, n - 1),
      "mean" => Float.round(mean, 1),
      "stddev" => Float.round(:math.sqrt(variance), 1)
    }
  end

  defp rank(tuple, n, q), do: elem(tuple, max(ceil(q * n / 100) - 1, 0))

  @doc "Events per second, rounded to 0.01."
  @spec per_second(non_neg_integer(), pos_integer()) :: float()
  def per_second(count, wall_us) when wall_us > 0,
    do: Float.round(count * 1_000_000 / wall_us, 2)

  defp by_case(samples) do
    samples
    |> Enum.group_by(& &1.case)
    |> Map.new(fn {name, group} ->
      phases =
        group
        |> Enum.flat_map(fn s -> Enum.to_list(Map.get(s, :phases, %{})) end)
        |> Enum.reject(fn {_phase, us} -> is_nil(us) end)
        |> Enum.group_by(fn {phase, _} -> phase end, fn {_, us} -> us end)
        |> Map.new(fn {phase, values} -> {phase, distribution(values)} end)

      {name,
       %{
         "latency_us" => distribution(Enum.map(group, & &1.duration_us)),
         "outcomes" => Enum.frequencies(Enum.map(group, &Map.get(&1, :outcome, "unreported"))),
         "phases_us" => phases,
         "invariant_failures" => Enum.count(group, &(&1.invariant != :ok))
       }}
    end)
  end

  defp invariant_failures(samples, phase) do
    for %{invariant: {:error, detail}} = s <- samples do
      %{
        "phase" => phase,
        "iteration" => s.iteration,
        "case" => s.case,
        "outcome" => Map.get(s, :outcome),
        "detail" => detail
      }
    end
  end

  defp sample_to_map(sample) do
    %{
      "iteration" => sample.iteration,
      "case" => sample.case,
      "duration_us" => sample.duration_us,
      "outcome" => Map.get(sample, :outcome),
      "phases_us" => Map.get(sample, :phases, %{}),
      "invariant" =>
        case sample.invariant do
          :ok -> "ok"
          {:error, detail} -> "failed: " <> detail
        end
    }
  end

  defp process_snapshot(pid) do
    pid
    |> Process.info([:memory, :total_heap_size, :heap_size, :reductions, :message_queue_len])
    |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
  end

  defp stringify(map), do: Map.new(map, fn {k, v} -> {Atom.to_string(k), v} end)

  # --- records and integrity ---------------------------------------------------

  @doc """
  Wraps a benchmark body into an Appendix E record.

  Options: `:subject` (`AshA2A.Chicago.Subject`, captured when absent),
  `:environment` (captured when absent), `:profile` (default `:core`),
  `:run_id`.
  """
  @spec record(String.t(), map(), keyword()) :: map()
  def record(benchmark_id, body, opts \\ []) when is_binary(benchmark_id) and is_map(body) do
    subject = Keyword.get_lazy(opts, :subject, fn -> Subject.capture() end)
    environment = Keyword.get_lazy(opts, :environment, &Environment.capture/0)
    failures = Map.get(body, "invariant_failure_count", 0)

    body
    |> Map.merge(%{
      "schema" => @schema,
      "specification" => @specification,
      "benchmark_id" => benchmark_id,
      "status" => if(failures == 0, do: "MEASURED", else: "INVARIANT_FAILURE"),
      "profile" => Profile.name(Keyword.get(opts, :profile, :core)),
      "run_id" => Keyword.get(opts, :run_id),
      "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "exact_subject" =>
        subject
        |> Subject.to_map()
        |> Map.delete("repo")
        |> Map.put("identity", Subject.digest(subject)),
      "environment" => environment
    })
    |> Json.safe()
  end

  @doc """
  Writes `record` content-addressed into `dir` as
  `<benchmark_id>.<sha256>.json`, where the digest is sha256 over the canonical
  JSON of the record and is also embedded (`"raw_result_digest"`).

  Returns `%{path, digest, bytes}`.
  """
  @spec write!(map(), Path.t()) :: %{path: Path.t(), digest: String.t(), bytes: pos_integer()}
  def write!(%{"benchmark_id" => id} = record, dir) do
    digest = sha256(Json.canonical(record))

    envelope = %{
      "raw_result" => record,
      "raw_result_digest" => digest,
      "digest_algorithm" => "sha256(canonical_json(raw_result))"
    }

    bytes = Json.canonical(envelope)
    path = Path.join(dir, "#{id}.#{digest}.json")
    File.mkdir_p!(dir)
    File.write!(path, bytes)
    %{path: path, digest: digest, bytes: byte_size(bytes)}
  end

  @doc """
  Re-derives a raw result's digest from the bytes on disk (§135).

  `{:ok, raw_result}` only when the recomputed digest equals the embedded one
  AND the content address in the file name. Any manual edit of the result --
  or of the digest without a matching rename -- is refused.
  """
  @spec verify_file(Path.t()) :: {:ok, map()} | {:error, term()}
  def verify_file(path) do
    with {:ok, bytes} <- File.read(path),
         {:ok, %{"raw_result" => raw, "raw_result_digest" => claimed}} when is_map(raw) <-
           decode(bytes) do
      actual = sha256(Json.canonical(raw))
      addressed = path |> Path.basename(".json") |> String.split(".") |> List.last()

      cond do
        actual != claimed ->
          {:error, {:raw_result_digest_mismatch, claimed: claimed, actual: actual}}

        addressed != actual ->
          {:error, {:content_address_mismatch, file_name: addressed, actual: actual}}

        true ->
          {:ok, raw}
      end
    else
      {:ok, _other} -> {:error, :not_a_bench_raw_result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode(bytes) do
    case JSON.decode(bytes) do
      {:ok, doc} -> {:ok, doc}
      {:error, reason} -> {:error, {:raw_result_non_json, reason}}
    end
  end

  @doc "Compact derived summary of a written record (never a substitute for the raw result)."
  @spec summary(map(), %{path: Path.t(), digest: String.t(), bytes: pos_integer()}) :: map()
  def summary(record, written) do
    %{
      "benchmark_id" => record["benchmark_id"],
      "status" => record["status"],
      "raw_result_path" => written.path,
      "raw_result_digest" => written.digest,
      "raw_result_bytes" => written.bytes,
      "iterations" => record["iterations"],
      "warmup_iterations" => get_in(record, ["warmup_policy", "warmup_iterations"]),
      "latency_us" => record["latency_us"],
      "throughput" => record["throughput"],
      "invariant_failure_count" => record["invariant_failure_count"],
      "environment_identity" => get_in(record, ["environment", "identity"]),
      "subject_identity" => get_in(record, ["exact_subject", "identity"]),
      "highlights" => Map.get(record, "highlights", %{})
    }
  end

  @doc false
  @spec sha256(iodata()) :: String.t()
  def sha256(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  # --- whole run -----------------------------------------------------------------

  @doc """
  Runs the selected benchmarks, writes each raw result content-addressed into
  `:out` and a derived `summary.json` alongside.

  Options: `:only` (e.g. `["B1", "B9"]`, default all), `:iterations`,
  `:warmup`, `:out` (default a fresh tmp dir), `:profile`, `:run_id`.
  """
  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts \\ []) do
    with {:ok, selected} <- select(Keyword.get(opts, :only)) do
      run_id = Keyword.get_lazy(opts, :run_id, fn -> "bench-" <> random_id() end)
      out = Keyword.get_lazy(opts, :out, fn -> Path.join(System.tmp_dir!(), run_id) end)
      subject = Subject.capture()
      environment = Environment.capture()

      record_opts = [
        subject: subject,
        environment: environment,
        profile: Keyword.get(opts, :profile, :core),
        run_id: run_id
      ]

      results =
        Enum.map(selected, fn {_short, module} ->
          case module.run(opts) do
            {:ok, body} ->
              record = record(module.id(), body, record_opts)
              summary(record, write!(record, out))

            {:blocked, detail} ->
              %{"benchmark_id" => module.id(), "status" => "BLOCKED", "detail" => detail}
          end
        end)

      summary = %{
        "schema" => @schema <> "#summary",
        "derived" => true,
        "run_id" => run_id,
        "environment_identity" => environment["identity"],
        "subject_identity" => Subject.digest(subject),
        "results" => results
      }

      File.mkdir_p!(out)
      summary_path = Path.join(out, "summary.json")
      File.write!(summary_path, Json.canonical(summary))

      {:ok,
       %{
         run_id: run_id,
         out: out,
         results: results,
         summary_path: summary_path,
         environment: environment
       }}
    end
  end

  @doc "Resolves `[\"B1\", \"SA2A-B5\", ...]` to benchmark modules."
  @spec select([String.t()] | nil) :: {:ok, [{String.t(), module()}]} | {:error, term()}
  def select(nil), do: {:ok, @benchmarks}

  def select(ids) when is_list(ids) do
    wanted = Enum.map(ids, &(&1 |> String.upcase() |> String.replace_prefix("SA2A-", "")))

    case Enum.reject(wanted, &List.keymember?(@benchmarks, &1, 0)) do
      [] -> {:ok, Enum.filter(@benchmarks, fn {short, _} -> short in wanted end)}
      unknown -> {:error, {:unknown_benchmarks, unknown}}
    end
  end

  defp random_id, do: :crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)
end
