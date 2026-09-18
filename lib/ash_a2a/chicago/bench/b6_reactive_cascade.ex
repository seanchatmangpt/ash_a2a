defmodule AshA2A.Chicago.Bench.B6ReactiveCascade do
  @moduledoc """
  RFC-SA2A-002 §90 benchmark `SA2A-B6` -- reactive cascade completion and
  bound-exhaustion latency.

  Drives the real `AshA2A.Semantic.HookReactor.run/2` bounded generation
  loop over the real `praxis-graphlaw` wasm engine
  (`AshA2A.Semantic.HookReactor.Engine`), the real `AshA2A.CommandBus`, a
  real `AshA2A.Authority.Broker.InMemory` and a real
  `AshA2A.ReceiptStore.Memory`, reusing the same hook/bounds/environment
  builders `AshA2A.Chicago.Courts.ReactiveCascade` already drives
  (`AshA2A.Chicago.Fixtures.HooksCascade`). Unlike SA2A-B3 (single hook-fire
  reflex latency), B6 times ONE ENTIRE cascade episode to its real terminal
  state -- quiescence or bound-exhaustion -- across a matrix of
  depth/fan-out/parallelism combinations (§90):

    * `cycle_d1_f1_p1` / `cycle_d2_f1_p1` / `cycle_d4_f1_p1` -- a
      self-triggering Pulse hook (F_max=1, P_max=1) at increasing D_max:
      every case genuinely exhausts its depth ceiling
      (`:bounds_depth_exceeded`), never quiescence, so cascade duration as a
      function of D_max is a real measured slope, not three copies of one
      number.
    * `tree_d2_f2_p1` / `tree_d2_f2_p2` -- the Seed=>2 Branch=>4 Leaf tree
      (same shape as the court's positive control SA2A-CASCADE-008) at
      P_max in {1, 2}, exactly at its admitted ceilings, so it completes
      quiescent every iteration; the P_max=1 vs P_max=2 pair isolates the
      real parallel-routing effect on time-to-quiescence.
    * `wide_d1_f4_p4` -- one delta, four admitted hooks, F_max=4 and P_max=4
      exactly at ceiling: a single wide generation routed at full requested
      parallelism.

  ## Setup vs. timed region

  Hook meta-admission (`HookReactor.admit/2`, a real engine witness-check
  per hook) and the broker/store environment
  (`AshA2A.Chicago.Fixtures.HooksCascade.with_env/1`) are arranged ONCE per
  case and excluded from the timed region -- the same §89 discipline
  `AshA2A.Chicago.Bench.B5Authority` uses for grant issuance. The timed
  region is exactly one `HookReactor.run/2` call: the real bounded
  generation loop end to end, never a single hook fire. Only the stimulus
  delta's IRI varies per iteration (a fresh generation-1 delta digest so
  every iteration's intent/command identity is fresh and `AshA2A.CommandBus`
  really executes rather than replaying iteration 1's receipt -- reusing an
  identical delta across iterations would silently degenerate every
  iteration after the first into idempotent-replay latency instead of a
  real cascade); the admitted hook set itself, whose digest already commits
  to its own baked-in `subject` (RFC-SA2A-002 §62, `Hook.digest/1`), stays
  fixed for the whole case.

  ## Real returned state, not telemetry interaction (Chicago style)

  `HookReactor.run/2` returns a `%HookReactor.Result{}` carrying the real
  terminal `outcome`/`code`, `generations`, `depth_reached`, and every
  `evaluations`/`intents`/`routes`/`bound_decisions` entry plus the
  reactor's own `duration_us`/`memory_peak_bytes` -- every measurement below
  is read from that real returned struct, never asserted from a telemetry
  call count alone. `AshA2A.Chicago.Bench.Timeline` is attached only to
  `cascade.start`/`cascade.stop` as an independent cross-check that the
  telemetry the SUT emits agrees with the struct it returns (§84); the
  independent post-state reader
  `AshA2A.Chicago.Fixtures.HooksCascade.signals/1` re-confirms, via a
  before/after row-count delta across the timed call, that the real `Signal`
  rows written to the ETS data layer agree with the struct's own committed
  route count -- the same "read back through `Ash.read!/1`, never the
  reply" discipline the court itself uses.

  ## Invariants (§84), checked on every sample

  Re-derived from the real generation loop
  (`AshA2A.Semantic.HookReactor.generation/4`): every terminal state --
  quiescent or bound-exhausted alike -- is reached one generation AFTER the
  last generation that actually committed a route, so `generations ==
  depth_reached + 1` holds for every case, not only the quiescent ones.
  `cycle_*`: terminal `:refused` / `:bounds_depth_exceeded`, `depth_reached
  == D_max`, exactly `D_max` committed routes. `tree_*`: terminal
  `:quiescent`, `depth_reached == 2`, exactly 6 committed routes (2 Branch +
  4 Leaf). `wide_*`: terminal `:quiescent`, `depth_reached == 1`, exactly 4
  committed routes. Every case: the independent `Signal` row delta equals
  the committed route count, and `cascade.stop` telemetry's `outcome`/`code`
  agree with the returned struct's.

  ## Not yet wired into the run-all dispatch

  `AshA2A.Chicago.Bench.@benchmarks` and `Mix.Tasks.AshA2a.Chicago.Bench`'s
  `--only` help text list B1/B5/B9 only; this module is intentionally not
  added there in this change (both are files shared with other in-flight
  SA2A-B* benchmark modules building concurrently) -- run it directly via
  `AshA2A.Chicago.Bench.B6ReactiveCascade.run/1`, or wire it into the shared
  dispatch in the serial merge/integration pass alongside its sibling
  modules.
  """

  alias AshA2A.Chicago.Bench
  alias AshA2A.Chicago.Bench.Timeline
  alias AshA2A.Chicago.Fixtures.HooksCascade, as: F
  alias AshA2A.Semantic.HookReactor
  alias AshA2A.Semantic.HookReactor.Engine

  @id "SA2A-B6"

  @start [:ash_a2a, :hook_reactor, :cascade, :start]
  @stop [:ash_a2a, :hook_reactor, :cascade, :stop]

  @typedoc "One SA2A-B6 case: an id and the bound ceilings/hook shape it drives."
  @type case_spec :: %{
          id: String.t(),
          kind: :cycle | :tree | :wide,
          depth: pos_integer(),
          fan_out: pos_integer(),
          parallelism: pos_integer()
        }

  @cases [
    %{id: "cycle_d1_f1_p1", kind: :cycle, depth: 1, fan_out: 1, parallelism: 1},
    %{id: "cycle_d2_f1_p1", kind: :cycle, depth: 2, fan_out: 1, parallelism: 1},
    %{id: "cycle_d4_f1_p1", kind: :cycle, depth: 4, fan_out: 1, parallelism: 1},
    %{id: "tree_d2_f2_p1", kind: :tree, depth: 2, fan_out: 2, parallelism: 1},
    %{id: "tree_d2_f2_p2", kind: :tree, depth: 2, fan_out: 2, parallelism: 2},
    %{id: "wide_d1_f4_p4", kind: :wide, depth: 1, fan_out: 4, parallelism: 4}
  ]

  @spec id() :: String.t()
  def id, do: @id

  @doc "Telemetry events SA2A-B6's independent cross-check attaches to."
  @spec events() :: [[atom()]]
  def events, do: [@start, @stop]

  @doc "The default case matrix (depth/fan-out/parallelism combinations, §90)."
  @spec cases() :: [case_spec()]
  def cases, do: @cases

  @doc """
  Runs the benchmark. Returns `{:ok, body}` or `{:blocked, detail}` when the
  real GraphLaw engine is not runnable on this host (never a fake engine).

  Options: `:iterations`, `:warmup`, `:cases` (matrix override).
  """
  @spec run(keyword()) :: {:ok, map()} | {:blocked, String.t()}
  def run(opts \\ []) do
    case Engine.open() do
      {:error, reason} ->
        {:blocked, "real GraphLaw engine unavailable: #{inspect(reason)}"}

      {:ok, runtime} ->
        try do
          {:ok,
           F.with_env(fn env ->
             measure(runtime, Keyword.get(opts, :cases, @cases), env, opts)
           end)}
        after
          Engine.close(runtime)
        end
    end
  end

  defp measure(runtime, cases, env, opts) do
    admissions = Map.new(cases, fn c -> {c.id, admit!(runtime, c)} end)
    ref = Timeline.attach(events())

    try do
      handlers = length(:telemetry.list_handlers(@stop))

      measured =
        Bench.measure(
          fn _phase, _i ->
            Enum.map(cases, &sample(&1, runtime, env, Map.fetch!(admissions, &1.id), ref))
          end,
          opts
        )

      Map.merge(measured, %{
        "benchmark" => "B6 reactive cascade completion and bound-exhaustion latency",
        "rfc_sections" => ["§84", "§90"],
        "sut" => %{
          "boundary" => "AshA2A.Semantic.HookReactor.run/2",
          "do_boundary" => "AshA2A.CommandBus.run/4 (per admitted intent, inside the reactor)",
          "engine" => %{
            "module" => inspect(runtime.module),
            "wasm_digest" => Map.get(runtime, :wasm_digest)
          }
        },
        "fixture" => %{
          "hooks_and_environment" => inspect(F),
          "cases" =>
            Enum.map(cases, fn c ->
              %{
                "id" => c.id,
                "kind" => to_string(c.kind),
                "depth" => c.depth,
                "fan_out" => c.fan_out,
                "parallelism" => c.parallelism
              }
            end)
        },
        "evidence_handlers_attached" => handlers,
        "notes" => [
          "hook meta-admission and broker/store startup are setup, excluded from the timed region",
          "the timed region is exactly one HookReactor.run/2 call, generation 1 through terminal",
          "only the stimulus delta's IRI varies per iteration; a repeated delta would silently " <>
            "replay instead of re-running the cascade, per AshA2A.CommandBus claim/replay protection",
          "generations/depth_reached/intents_constructed/routes_committed/bound_refusals/" <>
            "signal_rows_independent are reported as real per-case numeric distributions through " <>
            "the same phases_us slot Bench.by_case/1 already aggregates -- not just latency",
          "cycle_* cases genuinely exhaust their depth ceiling every iteration (never quiescent) -- " <>
            "the real §90 slope-of-D_max measurement, not incidental refusal"
        ],
        "highlights" => highlights(measured)
      })
    after
      Timeline.detach(ref)
    end
  end

  defp highlights(measured) do
    measured
    |> Map.get("by_case", %{})
    |> Map.new(fn {case_id, data} ->
      {case_id,
       %{
         "latency_p50_us" => get_in(data, ["latency_us", "p50"]),
         "latency_p99_us" => get_in(data, ["latency_us", "p99"]),
         "generations_p50" => get_in(data, ["phases_us", "generations", "p50"]),
         "depth_reached_p50" => get_in(data, ["phases_us", "depth_reached", "p50"]),
         "routes_committed_p50" => get_in(data, ["phases_us", "routes_committed", "p50"])
       }}
    end)
  end

  # --- setup (excluded from the timed region) ---------------------------------

  @spec admit!(map(), case_spec()) :: {[HookReactor.Hook.t()], HookReactor.Admission.t()}
  defp admit!(runtime, c) do
    hooks = hooks_for(c)

    case HookReactor.admit(hooks, runtime: runtime) do
      %{refused: []} = admitted ->
        {hooks, admitted.admission}

      %{refused: refused} ->
        raise "SA2A-B6 fixture hooks refused meta-admission for case #{c.id}: #{inspect(refused)}"
    end
  end

  defp hooks_for(%{kind: :cycle} = c) do
    subject = fixture_subject(c)
    [F.hook("sa2a-b6-#{c.id}-pulse", "Pulse", "Pulse", subject)]
  end

  defp hooks_for(%{kind: :tree} = c) do
    subject = fixture_subject(c)

    [
      F.hook("sa2a-b6-#{c.id}-branch-a", "Seed", "Branch", subject),
      F.hook("sa2a-b6-#{c.id}-branch-b", "Seed", "Branch", subject),
      F.hook("sa2a-b6-#{c.id}-leaf-a", "Branch", "Leaf", subject),
      F.hook("sa2a-b6-#{c.id}-leaf-b", "Branch", "Leaf", subject)
    ]
  end

  defp hooks_for(%{kind: :wide, fan_out: fan_out} = c) do
    subject = fixture_subject(c)
    for i <- 1..fan_out, do: F.hook("sa2a-b6-#{c.id}-wide-#{i}", "Wide", "Shard", subject)
  end

  defp fixture_subject(%{id: id}), do: "sa2a-b6-fixture-#{id}"

  defp stimulus_class(%{kind: :cycle}), do: "Pulse"
  defp stimulus_class(%{kind: :tree}), do: "Seed"
  defp stimulus_class(%{kind: :wide}), do: "Wide"

  # --- the timed sample ---------------------------------------------------------

  @doc false
  @spec sample(
          case_spec(),
          map(),
          map(),
          {[HookReactor.Hook.t()], HookReactor.Admission.t()},
          reference()
        ) :: Bench.sample()
  def sample(c, runtime, env, {hooks, admission}, ref) do
    _ = Timeline.drain(ref)
    subject = fixture_subject(c)
    unique = System.unique_integer([:positive])
    delta = F.typed_delta(stimulus_class(c), "urn:sa2a:b6:#{c.id}:#{unique}")
    bounds = F.bounds!(c.depth, c.fan_out, c.parallelism)

    before_rows = length(F.signals(subject))

    result =
      F.run!(runtime, env, admission,
        hooks: hooks,
        delta: delta,
        principal: env.granted,
        bounds: bounds
      )

    timeline = Timeline.drain(ref)
    rows_added = length(F.signals(subject)) - before_rows
    committed = Enum.count(result.routes, &(&1.outcome == :committed))

    %{
      case: c.id,
      duration_us: result.duration_us,
      outcome: outcome_string(result),
      phases: phases_for(result, timeline, rows_added),
      invariant: invariant(c, result, timeline, rows_added, committed)
    }
  end

  defp outcome_string(%{outcome: outcome, code: nil}), do: to_string(outcome)
  defp outcome_string(%{outcome: outcome, code: code}), do: "#{outcome}:#{code}"

  defp phases_for(result, timeline, rows_added) do
    committed = Enum.count(result.routes, &(&1.outcome == :committed))

    %{
      "generations" => result.generations,
      "depth_reached" => result.depth_reached,
      "intents_constructed" => length(result.intents),
      "routes_committed" => committed,
      "routes_replayed" => Enum.count(result.routes, &(&1.outcome == :replayed)),
      "routes_refused_or_failed" =>
        Enum.count(result.routes, &(&1.outcome in [:refused, :uncommitted, :failed])),
      "bound_refusals" => Enum.count(result.bound_decisions, &(&1.outcome == :refused)),
      "signal_rows_independent" => rows_added,
      "reactor_memory_peak_bytes" => result.memory_peak_bytes,
      "telemetry_start_to_stop_us" =>
        Timeline.gap(Timeline.first(timeline, @start), Timeline.first(timeline, @stop)),
      "mean_hook_evaluate_us" => mean(Enum.map(result.evaluations, &Map.get(&1, :duration_us))),
      "mean_route_us" => mean(Enum.map(result.routes, & &1[:route_us]))
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp mean(values) do
    case Enum.filter(values, &is_integer/1) do
      [] -> nil
      vs -> div(Enum.sum(vs), length(vs))
    end
  end

  # --- invariants (§84) ----------------------------------------------------------

  defp invariant(c, result, timeline, rows_added, committed) do
    start_count = length(Timeline.all(timeline, @start))
    stop_entries = Timeline.all(timeline, @stop)
    stop = List.first(stop_entries)

    checks =
      [
        {start_count == 1, "expected exactly one cascade.start event, observed #{start_count}"},
        {length(stop_entries) == 1,
         "expected exactly one cascade.stop event, observed #{length(stop_entries)}"},
        {stop == nil or stop.metadata[:outcome] == result.outcome,
         "cascade.stop telemetry outcome #{inspect(stop && stop.metadata[:outcome])} disagrees " <>
           "with the returned struct's outcome #{inspect(result.outcome)}"},
        {stop == nil or stop.metadata[:code] == result.code,
         "cascade.stop telemetry code #{inspect(stop && stop.metadata[:code])} disagrees with " <>
           "the returned struct's code #{inspect(result.code)}"},
        {result.generations == result.depth_reached + 1,
         "generations #{result.generations} != depth_reached #{result.depth_reached} + 1 " <>
           "(every terminal state is reached one generation after the last committing one)"},
        {rows_added == committed,
         "independent Signal row delta #{rows_added} != reactor-reported committed routes " <>
           "#{committed}"}
      ] ++ kind_checks(c, result, committed)

    first_failure(checks)
  end

  defp kind_checks(%{kind: :cycle, depth: depth}, result, committed) do
    [
      {result.outcome == :refused,
       "cycle case reached #{inspect(result.outcome)}, expected :refused"},
      {result.code == :bounds_depth_exceeded,
       "cycle case refused #{inspect(result.code)}, expected :bounds_depth_exceeded"},
      {result.depth_reached == depth,
       "cycle case depth_reached #{result.depth_reached} != D_max #{depth}"},
      {committed == depth,
       "cycle case committed #{committed} routes, expected exactly D_max #{depth}"}
    ]
  end

  defp kind_checks(%{kind: :tree}, result, committed) do
    [
      {result.outcome == :quiescent,
       "tree case reached #{inspect(result.outcome)}, expected :quiescent"},
      {result.depth_reached == 2, "tree case depth_reached #{result.depth_reached} != 2"},
      {committed == 6,
       "tree case committed #{committed} routes, expected exactly 6 (2 Branch + 4 Leaf)"}
    ]
  end

  defp kind_checks(%{kind: :wide}, result, committed) do
    [
      {result.outcome == :quiescent,
       "wide case reached #{inspect(result.outcome)}, expected :quiescent"},
      {result.depth_reached == 1, "wide case depth_reached #{result.depth_reached} != 1"},
      {committed == 4, "wide case committed #{committed} routes, expected exactly 4"}
    ]
  end

  defp first_failure(checks) do
    case Enum.find(checks, fn {ok?, _detail} -> ok? != true end) do
      nil -> :ok
      {_ok?, detail} -> {:error, detail}
    end
  end
end
