defmodule AshA2A.Chicago.Bench.B2LogicClosure do
  @moduledoc """
  RFC-SA2A-002 §86 benchmark `SA2A-B2` -- logic closure cost.

  Drives the real `AshA2A.Semantic.LogicClosure.close/2` boundary -- and
  through it the real vendored `praxis-graphlaw` engine, executed in-BEAM by
  Wasmtime via `AshA2A.GraphLaw.WasmexSession` (a Rustler NIF, not the
  subprocess Node host `AshA2A.GraphLaw.Wasm` uses for `SA2A-B1`) -- over the
  identical corpus `AshA2A.Chicago.Courts.SafeLogic`'s own `SA2A-B2`
  falsifiers (023/024/025) already exercise for standing:

    * `shallow`    -- one non-recursive rule over 200 facts
    * `recursive`  -- transitive closure over a 40-node chain
    * `near_bound` -- transitive closure over a 90-node chain (a large share
      of the default fuel budget)

  Every case's expected derived-triple count is computed arithmetically from
  the program shape, never read back from the engine (`cases/0`): `shallow`
  derives one `e:childOf` triple per `e:parentOf` fact; `recursive` and
  `near_bound` derive `C(k,2) - (k-1)` triples over a `k`-node chain
  (`AshA2A.Chicago.Fixtures.LogicSparql.chain_derived/1`).

  Unlike `SA2A-B1` (which mixes admitted and refused candidates in one
  distribution per §85), every `SA2A-B2` case is expected to reach a real,
  terminating, admitted closure -- there is no refused case in this corpus,
  matching what `SafeLogic`'s own 023/024/025 falsifiers declare
  (`kind: :measurement`, not `:negative`).

  ## Wall-clock phases (from real telemetry)

  Split from the real `[:ash_a2a, :logic, :closure, :start | :decision |
  :engine | :stop]` telemetry: each `:decision` event's own `:stage` metadata
  keys one admission-gate phase (gap from the previous event); the gap from
  the last `:decision` to `:engine` is `engine_dispatch`; `:engine` to
  `:stop` is `finalize`; `:start` to `:stop` is `total_closure`. These are
  external wall-clock measurements of the Elixir-side boundary.

  ## Engine-native measures (from the real `Closure` struct, per case)

  `AshA2A.Chicago.Bench.Timeline`'s telemetry metadata allow-list does not
  carry fuel/memory/wall-clock numbers, so `engine_by_case` is built directly
  from the real `Closure` struct `LogicClosure.close/2` returns on every
  measured (non-warmup) admitted run: fuel consumed (measured deterministic
  for identical input per `LogicClosure`'s own moduledoc) and its share of
  the fuel budget, the engine's own self-reported wall time, peak linear
  memory, and closure-digest stability -- each as a real `Bench.distribution/1`
  over the measured iterations, not a single ad hoc percentile helper.

  ## Invariants, checked on every sample (§84 discipline, same as B1)

  Exactly one `:start` and one `:stop` whose outcome agrees with the return
  value; a `:engine` event with `outcome: :completed`; `standing: :candidate`
  and `authority: :none` on the returned closure; and a derived-triple count
  equal to the case's arithmetically-expected count. Any violation is an
  invariant failure in the raw result, never dropped (§86: "logic closure
  cost is reported only for terminating runs").
  """

  alias AshA2A.Chicago.Bench
  alias AshA2A.Chicago.Bench.Timeline
  alias AshA2A.Chicago.Fixtures.LogicSparql, as: F
  alias AshA2A.GraphLaw.WasmexSession
  alias AshA2A.Semantic.LogicClosure
  alias AshA2A.Semantic.LogicClosure.Program

  @id "SA2A-B2"

  @start [:ash_a2a, :logic, :closure, :start]
  @decision [:ash_a2a, :logic, :closure, :decision]
  @engine [:ash_a2a, :logic, :closure, :engine]
  @stop [:ash_a2a, :logic, :closure, :stop]

  @typedoc "One SA2A-B2 corpus case: a real `LogicClosure.Program` and its arithmetically-expected derived count."
  @type case_spec :: %{id: String.t(), program: Program.t(), expected_derived: non_neg_integer()}

  @spec id() :: String.t()
  def id, do: @id

  @doc "Telemetry events the benchmark times."
  @spec events() :: [[atom()]]
  def events, do: [@start, @decision, @engine, @stop]

  @doc """
  The real B2 corpus -- identical facts/rules to `AshA2A.Chicago.Courts.SafeLogic`'s
  own `SA2A-B2` falsifiers 023 (shallow), 024 (recursive), 025 (near_bound).
  """
  @spec cases() :: [case_spec()]
  def cases do
    [
      %{
        id: "shallow",
        program: %Program{facts: F.shallow_facts(200), rules: F.shallow_rules()},
        expected_derived: 200
      },
      %{
        id: "recursive",
        program: %Program{facts: F.chain_facts(40), rules: F.transitive_rules()},
        expected_derived: F.chain_derived(40)
      },
      %{
        id: "near_bound",
        program: %Program{facts: F.chain_facts(90), rules: F.transitive_rules()},
        expected_derived: F.chain_derived(90)
      }
    ]
  end

  @doc "The `:admitted_rules` every B2 case needs for `LogicClosure.close/2`."
  @spec engine_opts() :: keyword()
  def engine_opts,
    do: [
      admitted_rules: LogicClosure.admitted_rule_set([F.shallow_rules(), F.transitive_rules()])
    ]

  @doc "sha256 over the corpus's own facts+rules text -- content identity, never read back from the engine."
  @spec digest([case_spec()]) :: String.t()
  def digest(cases \\ cases()) do
    cases
    |> Enum.map_join("\n--\n", fn c ->
      c.id <> "\n" <> c.program.facts <> "\n" <> c.program.rules
    end)
    |> Bench.sha256()
  end

  @doc """
  Runs the benchmark. Returns `{:ok, body}` or `{:blocked, detail}` when the
  real in-BEAM Wasmtime engine (`AshA2A.GraphLaw.WasmexSession`) is not
  runnable on this host (never a fake engine).

  Options: `:iterations`, `:warmup`, `:closure_opts` (merged into the real
  `LogicClosure.close/2` opts, e.g. `:wasm_path`, `:fuel`), `:cases` (corpus
  override; its digest is recorded).
  """
  @spec run(keyword()) :: {:ok, map()} | {:blocked, String.t()}
  def run(opts \\ []) do
    closure_opts = Keyword.merge(engine_opts(), Keyword.get(opts, :closure_opts, []))

    case WasmexSession.available?(closure_opts) do
      :ok ->
        {:ok, measure(Keyword.get(opts, :cases, cases()), closure_opts, opts)}

      {:error, detail} ->
        {:blocked, "real in-BEAM Wasmtime engine unavailable: #{inspect(detail)}"}
    end
  end

  defp measure(cases, closure_opts, opts) do
    ref = Timeline.attach(events())
    tab = :ets.new(:b2_logic_closure_engine_metrics, [:duplicate_bag, :public])

    try do
      handlers = length(:telemetry.list_handlers(@stop))

      measured =
        Bench.measure(
          fn phase, _i -> Enum.map(cases, &sample(&1, ref, closure_opts, tab, phase)) end,
          opts
        )

      admitted = count_outcome(measured, "admitted")
      refused = count_outcome(measured, "refused")
      wall_us = measured["throughput"]["wall_us"]

      stage_latency =
        measured["samples"]
        |> Enum.flat_map(&Enum.to_list(&1["phases_us"]))
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
        |> Map.new(fn {phase, values} -> {phase, Bench.distribution(values)} end)

      engine_by_case = Map.new(cases, fn c -> {c.id, engine_summary(tab, c.id)} end)
      wasm_digest = engine_by_case |> Map.values() |> Enum.find_value(&Map.get(&1, "wasm_digest"))
      wasmex_vsn = (Application.spec(:wasmex, :vsn) || ~c"unknown") |> to_string()

      Map.merge(measured, %{
        "benchmark" => "B2 logic closure cost (real Wasmtime engine)",
        "rfc_sections" => ["§27", "§47", "§48", "§86"],
        "sut" => %{
          "boundary" => "AshA2A.Semantic.LogicClosure.close/2",
          "engine" =>
            "wasmtime via wasmex #{wasmex_vsn} (in-BEAM, AshA2A.GraphLaw.WasmexSession)",
          "wasm_digest" => wasm_digest
        },
        "fixture" => %{
          "corpus" =>
            "AshA2A.Chicago.Bench.B2LogicClosure.cases/0 (== AshA2A.Chicago.Courts.SafeLogic SA2A-B2 falsifiers 023/024/025)",
          "corpus_digest" => digest(cases),
          "cases" =>
            Enum.map(cases, fn c -> %{"id" => c.id, "expected_derived" => c.expected_derived} end)
        },
        "stage_latency_us" => stage_latency,
        "engine_by_case" => engine_by_case,
        "throughput" =>
          Map.merge(measured["throughput"], %{
            "closures_per_second" => Bench.per_second(admitted, wall_us),
            "admitted" => admitted,
            "refused" => refused
          }),
        "evidence_handlers_attached" => handlers,
        "notes" => [
          "engine_dispatch/finalize/total_closure are external wall-clock gaps between the real closure telemetry events; engine_by_case's fuel/engine_wall_us/peak_memory_bytes are the real engine-self-reported values returned in the Closure struct, not derived from telemetry",
          "every SA2A-B2 case is expected admitted (:candidate/:none); unlike SA2A-B1 there is no refused case in this corpus",
          "warmup runs are invariant-checked but excluded from every distribution, including engine_by_case (same warmup policy as latency_us)"
        ],
        "highlights" => %{
          "total_closure_p50_us" => get_in(stage_latency, ["total_closure", "p50"]),
          "total_closure_p99_us" => get_in(stage_latency, ["total_closure", "p99"]),
          "closures_per_second" => Bench.per_second(admitted, wall_us)
        }
      })
    after
      Timeline.detach(ref)
      :ets.delete(tab)
    end
  end

  defp count_outcome(measured, outcome),
    do: Enum.count(measured["samples"], &(&1["outcome"] == outcome))

  @doc false
  @spec sample(case_spec(), reference(), keyword(), :ets.tid(), :warmup | :measured) ::
          Bench.sample()
  def sample(case_spec, ref, closure_opts, tab, phase) do
    _ = Timeline.drain(ref)
    started = System.monotonic_time(:microsecond)
    result = LogicClosure.close(case_spec.program, closure_opts)
    duration = System.monotonic_time(:microsecond) - started
    timeline = Timeline.drain(ref)

    record_engine_metrics(tab, case_spec.id, phase, result)

    %{
      case: case_spec.id,
      duration_us: duration,
      outcome: outcome(result),
      phases: phases(timeline),
      invariant: invariant(case_spec, result, timeline)
    }
  end

  defp outcome({:ok, _}), do: "admitted"
  defp outcome({:error, _}), do: "refused"

  defp phases(timeline) do
    start = Timeline.first(timeline, @start)
    stop = Timeline.first(timeline, @stop)
    engine = Timeline.first(timeline, @engine)
    decisions = Timeline.all(timeline, @decision)

    {stage_phases, last} =
      Enum.reduce(decisions, {%{}, start}, fn entry, {acc, previous} ->
        {Map.put(acc, to_string(entry.metadata[:stage]), Timeline.gap(previous, entry)), entry}
      end)

    stage_phases
    |> Map.put("engine_dispatch", Timeline.gap(last, engine))
    |> Map.put("finalize", if(engine, do: Timeline.gap(engine, stop)))
    |> Map.put("total_closure", Timeline.gap(start, stop))
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp invariant(case_spec, result, timeline) do
    starts = length(Timeline.all(timeline, @start))
    stops = Timeline.all(timeline, @stop)
    stop_outcome = with [entry] <- stops, do: entry.metadata[:outcome]

    cond do
      starts != 1 or length(stops) != 1 ->
        {:error, "expected one closure start and stop, observed #{starts} and #{length(stops)}"}

      to_string(stop_outcome) != outcome(result) ->
        {:error,
         "logic.closure.stop outcome #{inspect(stop_outcome)} disagrees with #{outcome(result)}"}

      true ->
        expectation(case_spec, result, timeline)
    end
  end

  defp expectation(case_spec, {:ok, closure}, timeline) do
    cond do
      closure.standing != :candidate ->
        {:error,
         "case #{case_spec.id} reached standing #{inspect(closure.standing)}, not :candidate"}

      closure.authority != :none ->
        {:error,
         "case #{case_spec.id} closure conferred authority #{inspect(closure.authority)} (must be :none)"}

      closure.derived_count != case_spec.expected_derived ->
        {:error,
         "case #{case_spec.id} derived #{closure.derived_count} facts, expected #{case_spec.expected_derived}"}

      not engine_completed?(timeline) ->
        {:error, "case #{case_spec.id}: no logic.closure.engine outcome=completed event observed"}

      true ->
        :ok
    end
  end

  defp expectation(case_spec, {:error, refusal}, _timeline),
    do:
      {:error,
       "case #{case_spec.id} (expected admitted candidate) was refused: #{inspect(refusal, limit: 20)}"}

  defp engine_completed?(timeline),
    do: Enum.any?(Timeline.all(timeline, @engine), &(&1.metadata[:outcome] == :completed))

  defp record_engine_metrics(_tab, _id, _phase, {:error, _}), do: :ok

  defp record_engine_metrics(tab, id, phase, {:ok, closure}) do
    :ets.insert(
      tab,
      {id, phase,
       %{
         fuel_consumed: closure.fuel_consumed,
         fuel_budget: closure.fuel_budget,
         peak_memory_bytes: closure.peak_memory_bytes,
         engine_wall_us: closure.wall_us,
         derived_count: closure.derived_count,
         fact_count_before: closure.fact_count_before,
         fact_count_after: closure.fact_count_after,
         rule_count: closure.rule_count,
         closure_digest: closure.closure_digest,
         wasm_digest: closure.wasm_digest
       }}
    )
  end

  defp engine_summary(tab, id) do
    metrics =
      tab
      |> :ets.match_object({id, :measured, :_})
      |> Enum.map(fn {_id, _phase, m} -> m end)

    case metrics do
      [] ->
        %{
          "n" => 0,
          "status" => "no completed measured engine run for this case (see invariant_failures)"
        }

      _ ->
        fuels = Enum.map(metrics, & &1.fuel_consumed)
        walls = Enum.map(metrics, & &1.engine_wall_us)
        mems = Enum.map(metrics, & &1.peak_memory_bytes)
        digests = metrics |> Enum.map(& &1.closure_digest) |> Enum.uniq()
        derived = metrics |> Enum.map(& &1.derived_count) |> Enum.uniq()
        budget = hd(metrics).fuel_budget

        %{
          "n" => length(metrics),
          "fuel_consumed" => Bench.distribution(fuels),
          "fuel_budget" => budget,
          "fuel_deterministic" => length(Enum.uniq(fuels)) == 1,
          "fuel_share_of_budget" => Float.round(hd(fuels) / budget, 4),
          "engine_wall_us" => Bench.distribution(walls),
          "peak_memory_bytes" => Bench.distribution(mems),
          "derived_count" => hd(derived),
          "derived_count_stable" => length(derived) == 1,
          "fact_count_before" => hd(metrics).fact_count_before,
          "fact_count_after" => hd(metrics).fact_count_after,
          "rule_count" => hd(metrics).rule_count,
          "closure_digest" => hd(digests),
          "closure_digest_stable" => length(digests) == 1,
          "wasm_digest" => hd(metrics).wasm_digest
        }
    end
  end
end
