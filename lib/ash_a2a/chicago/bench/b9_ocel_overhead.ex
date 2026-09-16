defmodule AshA2A.Chicago.Bench.B9OcelOverhead do
  @moduledoc """
  RFC-SA2A-002 §93 benchmark `SA2A-B9` -- OCEL evidence overhead.

  Measures the incremental cost of independent process evidence over a real
  consequence workload: the `authorized` scenario of
  `AshA2A.Chicago.Bench.B5Authority` (real grant decision, real CommandBus
  prepared receipt / actuation / final receipt, real independent read).

  Two arms run the identical workload:

    * `baseline` -- no additional observer. This is a comparison arm only;
      no evidence is claimed from it (§93: evidence is never disabled to
      improve a qualification number).
    * `observed` -- a real `AshA2A.Chicago.Observer` attached with the admitted
      `AshA2A.Chicago.Ocel.SutMappings`, recording every boundary event.

  Any evidence handlers already attached around the benchmark (for example
  the qualification run's own observer) are present in both arms and counted
  in `"evidence_handlers_attached"`, so the delta is the cost of one more
  independent observer.

  Then, on the observed arm's evidence:

    * OCEL events / objects produced, serialized size, dropped records
    * observer CPU: observer-process reductions, and VM CPU runtime delta
      between arms
    * observer memory: observer-process memory and heap after the workload
    * serialization time: `Observer.flush/2` (build + encode + fsync)
    * validation time: `AshA2A.Chicago.Ocel.Validator.validate_file/1` when
      that validator is compiled; otherwise recorded as `not_run`
    * conformance-query time: `AshA2A.Chicago.Query.load/2` (digest-checked
      read from disk) and each predicate evaluation

  ## Invariants (§84)

  Workload invariants of both arms (see `B5Authority`), plus: zero dropped
  records, at least eight BRCE events per observed workload iteration, the
  artifact loads under its own digest, every actuation is preceded by a
  prepared receipt for the same command, and one committed receipt per
  observed iteration.
  """

  alias AshA2A.Chicago.{Bench, Observer, Query}
  alias AshA2A.Chicago.Bench.{B5Authority, Timeline}
  alias AshA2A.Chicago.Ocel.SutMappings

  @id "SA2A-B9"
  @validator AshA2A.Chicago.Ocel.Validator
  @brce_events_per_iteration 8
  @scope "SA2A-B9-WORKLOAD-000"

  @spec id() :: String.t()
  def id, do: @id

  @doc """
  Options: `:iterations`, `:warmup`, `:out` (artifact directory; default tmp),
  `:ocel_validator` (default `AshA2A.Chicago.Ocel.Validator`).
  """
  @spec run(keyword()) :: {:ok, map()}
  def run(opts \\ []) do
    env = B5Authority.setup()
    ref = Timeline.attach(B5Authority.events())
    run_id = "bench-b9-" <> Integer.to_string(System.unique_integer([:positive]))

    dir =
      Keyword.get_lazy(opts, :b9_artifact_dir, fn ->
        Path.join([Keyword.get(opts, :out, System.tmp_dir!()), "b9-ocel", run_id])
      end)

    try do
      {:ok, measure(env, ref, run_id, dir, opts)}
    after
      Timeline.detach(ref)
      B5Authority.teardown(env)
    end
  end

  defp measure(env, ref, run_id, dir, opts) do
    step = fn arm -> fn _phase, _i -> [workload(arm, env, ref)] end end
    handlers_baseline = handler_count()
    baseline = Bench.measure(step.("baseline"), opts)

    {:ok, observer} = Observer.start_link(run_id: run_id, mappings: SutMappings.mappings())

    try do
      handlers_observed = handler_count()
      observer_before = observer_snapshot(observer)
      observed = Bench.measure(step.("observed"), opts)
      observer_after = observer_snapshot(observer)
      dropped = Observer.dropped(observer)

      {flush_us, flush} = :timer.tc(fn -> Observer.flush(observer, dir) end)
      evidence = evidence(flush, flush_us, dropped, opts)

      recorded_iterations =
        observed["iterations"] + observed["warmup_policy"]["warmup_iterations"]

      evidence_failures =
        evidence_failures(evidence, flush, dropped, recorded_iterations, observed["iterations"])

      failures =
        tag(baseline["invariant_failures"], "baseline") ++
          tag(observed["invariant_failures"], "observed") ++ evidence_failures

      overhead = overhead(baseline, observed, evidence)

      %{
        "benchmark" => "B9 OCEL evidence overhead",
        "rfc_sections" => ["§84", "§93"],
        "sut" => %{
          "workload" => "#{inspect(B5Authority)} authorized scenario",
          "observer" => inspect(Observer),
          "mappings" => inspect(SutMappings),
          "consumer" => inspect(Query),
          "validator" => inspect(@validator)
        },
        "iterations" => observed["iterations"],
        "warmup_policy" => observed["warmup_policy"],
        "latency_us" => observed["latency_us"],
        "throughput" => observed["throughput"],
        "memory" => observed["memory"],
        "cpu" => observed["cpu"],
        "arms" => %{
          "baseline" => Map.put(baseline, "evidence_handlers_attached", handlers_baseline),
          "observed" => Map.put(observed, "evidence_handlers_attached", handlers_observed)
        },
        "observer_process" => %{
          "before" => observer_before,
          "after" => observer_after,
          "reductions" => diff(observer_after, observer_before, "reductions"),
          "memory_bytes_after" => observer_after["memory"],
          "memory_delta_bytes" => diff(observer_after, observer_before, "memory")
        },
        "ocel" => evidence,
        "overhead" => overhead,
        "evidence_disabled" => false,
        "invariant_failure_count" => length(failures),
        "invariant_failures" => failures,
        "highlights" => %{
          "ocel_events" => evidence["events"],
          "ocel_bytes" => evidence["serialized_bytes"],
          "serialization_us" => evidence["serialization_us"],
          "query_load_us" => evidence["query"]["load_us"],
          "p50_overhead_us" => get_in(overhead, ["latency_delta_us", "p50"])
        }
      }
    after
      if Process.alive?(observer), do: Observer.stop(observer)
    end
  end

  defp workload(arm, env, ref) do
    "authorized" |> B5Authority.scenario(env, ref) |> Map.put(:case, arm)
  end

  defp evidence({:ok, flush}, flush_us, dropped, opts) do
    validator = Keyword.get(opts, :ocel_validator, @validator)
    {validation_us, validation} = :timer.tc(fn -> validate(flush.path, validator) end)
    {load_us, loaded} = :timer.tc(fn -> Query.load(flush.path, flush.sha256) end)

    queries =
      case loaded do
        {:ok, index} ->
          Map.new(predicates(), fn {name, predicate} ->
            {us, {holds?, detail}} = :timer.tc(fn -> Query.eval(index, @scope, predicate) end)
            {name, %{"us" => us, "holds" => holds?, "detail" => detail}}
          end)

        {:error, _} ->
          %{}
      end

    %{
      "artifact_path" => flush.path,
      "artifact_sha256" => flush.sha256,
      "events" => flush.events,
      "objects" => flush.objects,
      "serialized_bytes" => flush.bytes,
      "dropped" => dropped,
      "mapping_digest" => flush.mapping_digest,
      "serialization_us" => flush_us,
      "validation" => Map.put(validation, "us", validation_us),
      "query" => %{
        "load_us" => load_us,
        "load" => if(match?({:ok, _}, loaded), do: "ok", else: inspect(loaded)),
        "predicates" => queries,
        "total_us" => load_us + (queries |> Map.values() |> Enum.map(& &1["us"]) |> Enum.sum())
      }
    }
  end

  defp evidence({:error, reason}, flush_us, dropped, _opts) do
    %{
      "flush_error" => inspect(reason),
      "serialization_us" => flush_us,
      "dropped" => dropped,
      "query" => %{"load_us" => nil, "predicates" => %{}}
    }
  end

  defp predicates do
    [
      {"prepared_before_actuation",
       {:run_scope, {:precedes, "brce.prepare", "brce.actuate.start", "command"}}},
      {"commit_after_actuation",
       {:run_scope, {:precedes, "brce.actuate.stop", "brce.commit", "command"}}},
      {"no_failed_commit", {:run_scope, {:not_observed, "brce.commit", %{"outcome" => "failed"}}}}
    ]
  end

  # The validator is resolved at runtime (it may not be compiled into this
  # subject), exactly as `AshA2A.Chicago.Runner` resolves its OCEL validator.
  defp validate(path, validator) do
    if Code.ensure_loaded?(validator) and function_exported?(validator, :validate_file, 1) do
      case validator.validate_file(path) do
        {:ok, _report} ->
          %{"status" => "valid", "validator" => inspect(validator)}

        {:error, report} ->
          %{
            "status" => "invalid",
            "validator" => inspect(validator),
            "report" => inspect(report, limit: 20)
          }
      end
    else
      %{
        "status" => "not_run",
        "validator" => inspect(validator),
        "reason" => "#{inspect(validator)} is not compiled into this subject"
      }
    end
  rescue
    exception -> %{"status" => "invalid", "report" => Exception.message(exception)}
  end

  defp evidence_failures(%{"flush_error" => reason}, _flush, _dropped, _recorded, _iterations),
    do: [failure("observer flush failed: #{reason}")]

  defp evidence_failures(evidence, {:ok, flush}, dropped, recorded, iterations) do
    predicates = evidence["query"]["predicates"]
    commits = count_commits(flush.path)

    [
      {dropped == 0, "observer dropped #{dropped} records"},
      {flush.events >= recorded * @brce_events_per_iteration,
       "only #{flush.events} OCEL events for #{recorded} observed workload iterations"},
      {evidence["query"]["load"] == "ok",
       "independent consumer could not load the artifact: #{evidence["query"]["load"]}"},
      {commits >= iterations, "#{commits} committed receipts for #{iterations} iterations"}
      | Enum.map(predicates, fn {name, %{"holds" => holds?, "detail" => detail}} ->
          {holds?, "conformance query #{name} does not hold: #{detail}"}
        end)
    ]
    |> Enum.reject(&elem(&1, 0))
    |> Enum.map(&failure(elem(&1, 1)))
  end

  defp count_commits(path) do
    with {:ok, index} <- Query.load(path) do
      Enum.count(
        index.events,
        &(&1.type == "brce.commit" and &1.attributes["outcome"] == "committed")
      )
    else
      _ -> 0
    end
  end

  defp failure(detail),
    do: %{
      "phase" => "evidence",
      "iteration" => nil,
      "case" => "observed",
      "outcome" => nil,
      "detail" => detail
    }

  defp tag(failures, arm), do: Enum.map(failures, &Map.put(&1, "arm", arm))

  defp overhead(baseline, observed, evidence) do
    base = baseline["latency_us"]
    obs = observed["latency_us"]

    latency_delta =
      for stat <- ["min", "p50", "p90", "p95", "p99", "max", "mean"],
          is_number(base[stat]) and is_number(obs[stat]),
          into: %{},
          do: {stat, obs[stat] - base[stat]}

    events = evidence["events"]
    iterations = observed["iterations"] + observed["warmup_policy"]["warmup_iterations"]

    %{
      "latency_delta_us" => latency_delta,
      "vm_runtime_ms_delta" =>
        observed["cpu"]["vm_runtime_ms"] - baseline["cpu"]["vm_runtime_ms"],
      "vm_reductions_delta" =>
        observed["cpu"]["vm_reductions"] - baseline["cpu"]["vm_reductions"],
      "events_per_iteration" =>
        if(is_integer(events) and iterations > 0, do: Float.round(events / iterations, 2)),
      "bytes_per_event" =>
        if(is_integer(events) and events > 0,
          do: Float.round(evidence["serialized_bytes"] / events, 1)
        )
    }
  end

  defp observer_snapshot(pid) do
    pid
    |> Process.info([:reductions, :memory, :total_heap_size, :message_queue_len])
    |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
  end

  defp diff(after_map, before_map, key), do: after_map[key] - before_map[key]

  defp handler_count, do: length(:telemetry.list_handlers([:ash_a2a, :command_bus, :commit]))
end
