defmodule AshA2A.Chicago.Courts.ReactiveCascade do
  @moduledoc """
  RFC-SA2A-002 §63 Reactive Cascade court plus Benchmarks B3 (§87 Knowledge
  Hook Reflex) and B6 (§90 Reactive Cascade), court id `SA2A-CASCADE`.

      Depth ≤ D_max        FanOut ≤ F_max        Parallelism ≤ P_max

  The court attacks `AshA2A.Semantic.HookReactor` with self-triggering and
  mutually-cyclic hook sets capable of unbounded recursion, over-wide fan-out
  and over-requested parallelism, and requires bounded termination or typed
  refusal. Positive controls (§100) prove the bounds discriminate: a bounded
  acyclic reflex reaches quiescence, and a fan-out tree exactly at its admitted
  depth/fan-out completes.

  Every consequence in every cascade goes through the real
  `AshA2A.CommandBus`; hook conditions are decided by the real GraphLaw
  engine; post-state is read back through `Ash.read!/1`. Measurement
  falsifiers derive their numbers from the independent observer's attributed
  records (plus the reactor's own terminal result where named).
  """

  use AshA2A.Chicago.Court

  alias AshA2A.Chicago.{Context, Falsifier, Result}
  alias AshA2A.Chicago.Fixtures.HooksCascade, as: F
  alias AshA2A.Semantic.HookReactor
  alias AshA2A.Semantic.HookReactor.Engine

  @court "SA2A-CASCADE"
  @unbounded_after_ms 60_000

  @impl true
  def id, do: @court
  @impl true
  def title,
    do: "Reactive cascade bounds, bounded quiescence, B3 hook reflex and B6 cascade benchmarks"

  @impl true
  def gate, do: 6
  @impl true
  def profile, do: :logic
  @impl true
  def rfc_sections, do: ["§37", "§63", "§87", "§90", "§100"]

  @impl true
  def ocel_mappings, do: F.mappings(__MODULE__)

  @impl true
  def falsifiers do
    [
      negative(
        "001",
        invariant:
          "Depth ≤ D_max: a self-triggering hook terminates by bounded refusal, never unbounded recursion",
        stimulus:
          "hook `?s a h:Pulse` ⇒ emit Pulse (its own consequence re-triggers it); D_max=3, F_max=1, P_max=1; granted principal",
        boundary: "HookReactor generation loop depth decision (Bounds depth ceiling)",
        forbidden_outcome:
          "more than D_max actuations, or no terminal cascade.stop within #{@unbounded_after_ms}ms",
        attempt_evidence: "episode started and >= 3 real committed consequences of the cycle",
        survival_evidence:
          "brce.actuate.start count >= 4, hook.cascade.stop absent, court-side timeout, Signal rows > 3",
        guard: "HookReactor.generation/4 `generation > bounds.depth` refusal",
        failure_class: :bound_failure,
        rfc_sections: ["§63"],
        attempt_predicate:
          {:all, [{:observed, "hook.cascade.start"}, {:count, "brce.commit", :gte, 3}]},
        outcome_predicate:
          {:any, [{:count, "brce.actuate.start", :gte, 4}, {:not_observed, "hook.cascade.stop"}]}
      ),
      negative(
        "002",
        invariant:
          "Depth is episode depth, not per-hook depth: a two-hook cycle (Ping ⇒ Pong ⇒ Ping) is bounded by the same D_max",
        stimulus: "hooks Ping⇒Pong and Pong⇒Ping; D_max=4, F_max=1, P_max=1; granted principal",
        boundary: "HookReactor generation loop depth decision",
        forbidden_outcome:
          "more than D_max actuations, or no terminal cascade.stop within #{@unbounded_after_ms}ms",
        attempt_evidence: "episode started and >= 4 committed consequences of the cycle",
        survival_evidence: "brce.actuate.start count >= 5, hook.cascade.stop absent, timeout",
        guard: "HookReactor.generation/4 counts generations of the episode",
        failure_class: :bound_failure,
        rfc_sections: ["§63"],
        attempt_predicate:
          {:all, [{:observed, "hook.cascade.start"}, {:count, "brce.commit", :gte, 4}]},
        outcome_predicate:
          {:any, [{:count, "brce.actuate.start", :gte, 5}, {:not_observed, "hook.cascade.stop"}]}
      ),
      negative(
        "003",
        invariant:
          "FanOut ≤ F_max: three hooks firing on one delta with F_max=2 are refused before any is routed",
        stimulus: "three admitted hooks on h:Burst; F_max=2, D_max=3, P_max=2; granted principal",
        boundary: "HookReactor.admit_fan_out/3 (Bounds.admit_fan_out/2)",
        forbidden_outcome: "any intent routed or any actuation",
        attempt_evidence: ">= 3 candidate intents constructed from one delta",
        survival_evidence: "hook.intent.route_start or brce.actuate.start",
        guard: "HookReactor.admit_fan_out/3 halts before route_all/2",
        failure_class: :bound_failure,
        rfc_sections: ["§63"],
        attempt_predicate: {:count, "hook.intent.constructed", :gte, 3},
        outcome_predicate:
          {:any, [{:observed, "hook.intent.route_start"}, {:observed, "brce.actuate.start"}]}
      ),
      negative(
        "004",
        invariant:
          "Parallelism ≤ P_max: a requested parallelism above the admitted ceiling is refused before evaluation",
        stimulus:
          "admitted P_max=2, requested parallelism 8; two matching hooks; granted principal",
        boundary: "HookReactor.admit_parallelism/1 (Bounds.admit_parallelism/2)",
        forbidden_outcome: "any hook evaluation or actuation",
        attempt_evidence: "hook.cascade.start carrying requested_parallelism 8",
        survival_evidence: "hook.evaluate or brce.actuate.start",
        guard: "HookReactor.admit_parallelism/1",
        failure_class: :bound_failure,
        rfc_sections: ["§63"],
        attempt_predicate: {:observed, "hook.cascade.start", %{"requested_parallelism" => "8"}},
        outcome_predicate:
          {:any, [{:observed, "hook.evaluate"}, {:observed, "brce.actuate.start"}]}
      ),
      negative(
        "005",
        invariant:
          "Parallelism ≤ P_max during routing: four admitted intents in one generation never have more than P_max routes in flight",
        stimulus: "four admitted hooks on h:Wide; F_max=4, P_max=2, D_max=2; granted principal",
        boundary: "HookReactor.route_all/2 bounded Task.async_stream window",
        forbidden_outcome:
          "a route started with in_flight > 2, or more than 2 overlapping CommandBus actuations",
        attempt_evidence: "four routes started and four committed consequences",
        survival_evidence:
          "hook.intent.route_start in_flight 3 or 4; court-side actuation overlap from brce.actuate.start/stop > 2",
        guard: "HookReactor.route_all/2 max_concurrency: parallelism",
        failure_class: :bound_failure,
        rfc_sections: ["§63"],
        attempt_predicate:
          {:all,
           [
             {:count, "hook.intent.route_start", :eq, 4},
             {:count, "brce.commit", :gte, 4}
           ]},
        outcome_predicate:
          {:any,
           [
             {:observed, "hook.intent.route_start", %{"in_flight" => "3"}},
             {:observed, "hook.intent.route_start", %{"in_flight" => "4"}}
           ]}
      ),
      negative(
        "006",
        invariant:
          "Only admitted (receipted) consequence feeds the cascade: a refused intent produces no phantom delta",
        stimulus:
          "self-triggering Pulse hook, D_max=5, principal WITHOUT a grant (every intent refused at CommandBus), " <>
            "with an optimistic projection that would render a delta for ANY intent it is handed",
        boundary: "HookReactor.feedback/2 (committed receipts only)",
        forbidden_outcome: "a second generation evaluated, or any actuation",
        attempt_evidence:
          "brce.admission refused authority_required and a terminal hook.cascade.stop",
        survival_evidence: "hook.evaluate generation 2, brce.actuate.start",
        guard: "HookReactor.feedback/2 filters outcome == :committed",
        failure_class: :bound_failure,
        rfc_sections: ["§63", "§60"],
        attempt_predicate:
          {:all,
           [
             {:observed, "brce.admission",
              %{"outcome" => "refused", "code" => "authority_required"}},
             {:observed, "hook.cascade.stop"}
           ]},
        outcome_predicate:
          {:any,
           [
             {:observed, "hook.evaluate", %{"generation" => "2"}},
             {:observed, "brce.actuate.start"}
           ]}
      ),
      Falsifier.new!(
        id: "SA2A-CASCADE-007",
        court_id: @court,
        kind: :positive_control,
        invariant:
          "Cycle beyond bound blocked / bounded acyclic reflex reaches quiescence (§100): Reading ⇒ Alert ⇒ Notice terminates quiescent",
        stimulus:
          "hooks Reading⇒Alert and Alert⇒Notice; D_max=4, F_max=1, P_max=1; granted principal",
        boundary: "HookReactor generation loop",
        attempt_evidence: "hook.cascade.start",
        survival_evidence:
          "hook.cascade.stop quiescent after exactly two committed consequences and no refused bound; Alert and Notice rows",
        rfc_sections: ["§63", "§100", "§37"],
        attempt_predicate: {:observed, "hook.cascade.start"},
        outcome_predicate:
          {:all,
           [
             {:observed, "hook.cascade.stop",
              %{"outcome" => "quiescent", "depth_reached" => "2"}},
             {:count, "brce.commit", :eq, 2},
             {:not_observed, "hook.cascade.bound", %{"outcome" => "refused"}}
           ]}
      ),
      Falsifier.new!(
        id: "SA2A-CASCADE-008",
        court_id: @court,
        kind: :positive_control,
        invariant:
          "Bounds admit what they admit: a Seed ⇒ 2 Branch ⇒ 4 Leaf tree exactly at D_max=2, F_max=2, P_max=2 completes",
        stimulus:
          "hooks Seed⇒Branch (×2) and Branch⇒Leaf (×2); D_max=2, F_max=2, P_max=2; granted principal",
        boundary: "HookReactor depth / fan-out / parallelism decisions",
        attempt_evidence: "hook.cascade.start",
        survival_evidence:
          "quiescent after six committed consequences, depth_reached 2, no refused bound, 6 rows",
        rfc_sections: ["§63", "§100"],
        attempt_predicate: {:observed, "hook.cascade.start"},
        outcome_predicate:
          {:all,
           [
             {:observed, "hook.cascade.stop",
              %{"outcome" => "quiescent", "depth_reached" => "2"}},
             {:count, "brce.commit", :eq, 6},
             {:not_observed, "hook.cascade.bound", %{"outcome" => "refused"}}
           ]}
      ),
      measurement(
        "009",
        "SA2A-B3 no-match control: delta size, hooks evaluated/fired, intent count, latencies",
        "one admitted hook on h:Reading, delta asserts only an unrelated class",
        {:all,
         [
           {:observed, "hook.evaluate", %{"outcome" => "not_fired"}},
           {:observed, "hook.cascade.stop"}
         ]},
        {:not_observed, "hook.intent.constructed"}
      ),
      measurement(
        "010",
        "SA2A-B3 single-match reflex: one hook fires, one intent, one receipted consequence",
        "one admitted hook on h:Reading, matching delta, granted principal, no feedback",
        {:all,
         [
           {:count, "hook.evaluate", :gte, 1},
           {:observed, "hook.evaluate", %{"outcome" => "fired"}},
           {:observed, "brce.commit", %{"outcome" => "committed"}}
         ]},
        {:count, "hook.intent.constructed", :eq, 1}
      ),
      measurement(
        "011",
        "SA2A-B3 multi-match within bound: three hooks fire on one delta, F_max=3",
        "three admitted hooks on h:Reading, matching delta, granted principal, no feedback",
        {:all,
         [
           {:count, "hook.intent.constructed", :gte, 3},
           {:count, "brce.commit", :gte, 3}
         ]},
        {:not_observed, "hook.cascade.bound", %{"outcome" => "refused"}}
      ),
      measurement(
        "012",
        "SA2A-B3 replay of the same delta: second delivery replays the receipt",
        "single-match reflex delivered twice",
        {:all,
         [
           {:count, "hook.cascade.start", :eq, 2},
           {:observed, "brce.claim", %{"outcome" => "replay"}}
         ]},
        {:count, "brce.actuate.start", :eq, 1}
      ),
      measurement(
        "013",
        "SA2A-B6 acyclic fan-out tree as a function of admitted parallelism (P_max ∈ {1,2})",
        "Seed ⇒ 2 Branch ⇒ 4 Leaf tree at D_max=2, F_max=2, run once per P_max",
        {:all,
         [
           {:count, "hook.cascade.stop", :eq, 2},
           {:observed, "hook.cascade.stop", %{"outcome" => "quiescent"}},
           {:count, "brce.commit", :gte, 12}
         ]},
        {:not_observed, "hook.cascade.bound", %{"outcome" => "refused"}}
      ),
      measurement(
        "014",
        "SA2A-B6 cycle-inducing fixture as a function of admitted depth (D_max ∈ {1,2,4})",
        "self-triggering Pulse hook at D_max 1, 2 and 4 (F_max=1, P_max=1)",
        {:all,
         [
           {:count, "hook.cascade.bound", :gte, 3},
           {:count, "hook.cascade.stop", :eq, 3},
           {:observed, "hook.cascade.stop", %{"code" => "bounds_depth_exceeded"}}
         ]},
        {:count, "brce.actuate.start", :eq, 7}
      )
    ]
  end

  defp negative(suffix, fields) do
    Falsifier.new!([id: "#{@court}-#{suffix}", court_id: @court, kind: :negative] ++ fields)
  end

  defp measurement(suffix, invariant, stimulus, attempt, outcome) do
    Falsifier.new!(
      id: "#{@court}-#{suffix}",
      court_id: @court,
      kind: :measurement,
      invariant: invariant,
      stimulus: stimulus,
      boundary: "AshA2A.Semantic.HookReactor over the real GraphLaw engine and CommandBus",
      attempt_evidence:
        "the measured path executed (hook.cascade.start/stop and engine evaluations)",
      survival_evidence: "measurements derived from observer records attributed to the stimulus",
      rfc_sections: ["§87", "§90"],
      tags: [:benchmark],
      attempt_predicate: attempt,
      outcome_predicate: outcome
    )
  end

  # --- execution --------------------------------------------------------------

  @impl true
  def run(%Context{} = ctx) do
    falsifiers = falsifiers()

    case Engine.open() do
      {:error, reason} ->
        Enum.map(
          falsifiers,
          &Result.blocked(&1, "real GraphLaw engine unavailable: #{inspect(reason)}")
        )

      {:ok, runtime} ->
        try do
          F.with_env(fn env ->
            Enum.map(falsifiers, fn f ->
              F.guarded(f, fn -> execute(f.id, f, ctx, runtime, env) end)
            end)
          end)
        after
          Engine.close(runtime)
        end
    end
  end

  defp execute("SA2A-CASCADE-001", f, ctx, runtime, env) do
    subject = subject(env, f)
    hooks = [F.hook("sa2a-pulse-001", "Pulse", "Pulse", subject)]
    cycle(f, ctx, runtime, env, subject, hooks, "Pulse", 3)
  end

  defp execute("SA2A-CASCADE-002", f, ctx, runtime, env) do
    subject = subject(env, f)

    hooks = [
      F.hook("sa2a-ping-002", "Ping", "Pong", subject),
      F.hook("sa2a-pong-002", "Pong", "Ping", subject)
    ]

    cycle(f, ctx, runtime, env, subject, hooks, "Ping", 4)
  end

  defp execute("SA2A-CASCADE-003", f, ctx, runtime, env) do
    subject = subject(env, f)
    hooks = for i <- 1..3, do: F.hook("sa2a-burst-#{i}-003", "Burst", "Shard", subject)

    ep =
      Context.stimulus(ctx, f, fn ->
        F.episode(runtime, env,
          hooks: hooks,
          delta: F.typed_delta("Burst", "urn:sa2a:burst:" <> subject),
          principal: env.granted,
          bounds: F.bounds!(3, 2, 2)
        )
      end)

    rows = F.signals(subject)

    Result.negative(f,
      attempt_observed?: F.count(ctx, f, "hook.intent.constructed") >= 3,
      forbidden_outcome_observed?:
        F.seen?(ctx, f, "hook.intent.route_start") or F.seen?(ctx, f, "brce.actuate.start") or
          rows != [],
      evidence: cascade_evidence(ep.result, rows)
    )
  end

  defp execute("SA2A-CASCADE-004", f, ctx, runtime, env) do
    subject = subject(env, f)
    hooks = for i <- 1..2, do: F.hook("sa2a-wide-#{i}-004", "Wide", "Shard", subject)

    ep =
      Context.stimulus(ctx, f, fn ->
        F.episode(runtime, env,
          hooks: hooks,
          delta: F.typed_delta("Wide", "urn:sa2a:wide:" <> subject),
          principal: env.granted,
          bounds: F.bounds!(2, 2, 2),
          parallelism: 8
        )
      end)

    rows = F.signals(subject)

    Result.negative(f,
      attempt_observed?: F.seen?(ctx, f, "hook.cascade.start", %{"requested_parallelism" => "8"}),
      forbidden_outcome_observed?:
        F.seen?(ctx, f, "hook.evaluate") or F.seen?(ctx, f, "brce.actuate.start") or rows != [],
      evidence: cascade_evidence(ep.result, rows)
    )
  end

  defp execute("SA2A-CASCADE-005", f, ctx, runtime, env) do
    subject = subject(env, f)
    hooks = for i <- 1..4, do: F.hook("sa2a-wide-#{i}-005", "Wide", "Shard", subject)

    ep =
      Context.stimulus(ctx, f, fn ->
        F.episode(runtime, env,
          hooks: hooks,
          delta: F.typed_delta("Wide", "urn:sa2a:wide:" <> subject),
          principal: env.granted,
          bounds: F.bounds!(2, 4, 2)
        )
      end)

    rows = F.signals(subject)
    records = Context.observed(ctx, f)
    max_in_flight = max_attr(F.records(ctx, f, "hook.intent.route_start"), "in_flight")
    overlap = F.actuation_overlap(records)

    Result.negative(f,
      attempt_observed?:
        F.count(ctx, f, "hook.intent.route_start") == 4 and
          F.count(ctx, f, "brce.commit", %{"outcome" => "committed"}) >= 4,
      forbidden_outcome_observed?: max_in_flight > 2 or overlap > 2,
      evidence:
        ep.result
        |> cascade_evidence(rows)
        |> Map.merge(%{"max_in_flight" => max_in_flight, "max_actuation_overlap" => overlap})
    )
  end

  defp execute("SA2A-CASCADE-006", f, ctx, runtime, env) do
    subject = subject(env, f)
    hooks = [F.hook("sa2a-pulse-006", "Pulse", "Pulse", subject)]

    ep =
      Context.stimulus(ctx, f, fn ->
        F.episode(runtime, env,
          hooks: hooks,
          delta: F.typed_delta("Pulse", "urn:sa2a:pulse:" <> subject),
          principal: env.ungranted,
          bounds: F.bounds!(5, 1, 1),
          project: &F.optimistic_project/2
        )
      end)

    rows = F.signals(subject)

    Result.negative(f,
      attempt_observed?:
        F.seen?(ctx, f, "brce.admission", %{
          "outcome" => "refused",
          "code" => "authority_required"
        }) and F.seen?(ctx, f, "hook.cascade.stop"),
      forbidden_outcome_observed?:
        F.seen?(ctx, f, "hook.evaluate", %{"generation" => "2"}) or
          F.seen?(ctx, f, "brce.actuate.start") or rows != [],
      evidence: cascade_evidence(ep.result, rows)
    )
  end

  defp execute("SA2A-CASCADE-007", f, ctx, runtime, env) do
    subject = subject(env, f)

    hooks = [
      F.hook("sa2a-alert-007", "Reading", "Alert", subject),
      F.hook("sa2a-notice-007", "Alert", "Notice", subject)
    ]

    ep =
      Context.stimulus(ctx, f, fn ->
        F.episode(runtime, env,
          hooks: hooks,
          delta: F.typed_delta("Reading", "urn:sa2a:reading:" <> subject),
          principal: env.granted,
          bounds: F.bounds!(4, 1, 1)
        )
      end)

    rows = F.signals(subject)
    r = ep.result

    Result.positive(f,
      attempt_observed?: F.seen?(ctx, f, "hook.cascade.start"),
      expected_outcome_observed?:
        r.outcome == :quiescent and r.depth_reached == 2 and
          Enum.sort(Enum.map(rows, & &1.kind)) == ["Alert", "Notice"] and
          F.count(ctx, f, "brce.commit") == 2 and
          not F.seen?(ctx, f, "hook.cascade.bound", %{"outcome" => "refused"}),
      evidence: cascade_evidence(r, rows)
    )
  end

  defp execute("SA2A-CASCADE-008", f, ctx, runtime, env) do
    subject = subject(env, f)

    ep =
      Context.stimulus(ctx, f, fn ->
        F.episode(runtime, env,
          hooks: tree_hooks(subject, "008"),
          delta: F.typed_delta("Seed", "urn:sa2a:seed:" <> subject),
          principal: env.granted,
          bounds: F.bounds!(2, 2, 2)
        )
      end)

    rows = F.signals(subject)
    r = ep.result

    Result.positive(f,
      attempt_observed?: F.seen?(ctx, f, "hook.cascade.start"),
      expected_outcome_observed?:
        r.outcome == :quiescent and r.depth_reached == 2 and length(rows) == 6 and
          F.count(ctx, f, "brce.commit") == 6 and
          not F.seen?(ctx, f, "hook.cascade.bound", %{"outcome" => "refused"}),
      evidence: cascade_evidence(r, rows)
    )
  end

  defp execute("SA2A-CASCADE-009", f, ctx, runtime, env) do
    subject = subject(env, f)
    hooks = [F.hook("sa2a-b3-nomatch", "Reading", "Alert", subject)]

    [result] =
      Context.stimulus(ctx, f, fn ->
        [
          F.episode(runtime, env,
            hooks: hooks,
            delta: F.typed_delta("Unrelated", "urn:sa2a:b3:" <> subject),
            principal: env.granted,
            bounds: F.bounds!(1, 1, 1),
            project: false
          ).result
        ]
      end)

    b3(f, ctx, [{"no_match", result}])
  end

  defp execute("SA2A-CASCADE-010", f, ctx, runtime, env) do
    subject = subject(env, f)
    hooks = [F.hook("sa2a-b3-single", "Reading", "Alert", subject)]

    result =
      Context.stimulus(ctx, f, fn ->
        F.episode(runtime, env,
          hooks: hooks,
          delta: F.typed_delta("Reading", "urn:sa2a:b3:" <> subject),
          principal: env.granted,
          bounds: F.bounds!(1, 1, 1),
          project: false
        ).result
      end)

    b3(f, ctx, [{"single_match", result}])
  end

  defp execute("SA2A-CASCADE-011", f, ctx, runtime, env) do
    subject = subject(env, f)
    hooks = for i <- 1..3, do: F.hook("sa2a-b3-multi-#{i}", "Reading", "Alert", subject)

    result =
      Context.stimulus(ctx, f, fn ->
        F.episode(runtime, env,
          hooks: hooks,
          delta: F.typed_delta("Reading", "urn:sa2a:b3:" <> subject),
          principal: env.granted,
          bounds: F.bounds!(1, 3, 3),
          project: false
        ).result
      end)

    b3(f, ctx, [{"multi_match", result}])
  end

  defp execute("SA2A-CASCADE-012", f, ctx, runtime, env) do
    subject = subject(env, f)
    hook = F.hook("sa2a-b3-replay", "Reading", "Alert", subject)
    delta = F.typed_delta("Reading", "urn:sa2a:b3:" <> subject)

    {first, second} =
      Context.stimulus(ctx, f, fn ->
        %{admission: admission} = HookReactor.admit([hook], runtime: runtime)

        opts = [
          hooks: [hook],
          delta: delta,
          principal: env.granted,
          bounds: F.bounds!(1, 1, 1),
          project: false
        ]

        {F.run!(runtime, env, admission, opts), F.run!(runtime, env, admission, opts)}
      end)

    b3(f, ctx, [{"first_delivery", first}, {"replayed_delivery", second}])
  end

  defp execute("SA2A-CASCADE-013", f, ctx, runtime, env) do
    runs =
      Context.stimulus(ctx, f, fn ->
        for p <- [1, 2] do
          subject = "#{subject(env, f)}-p#{p}"

          {"parallelism_#{p}",
           F.episode(runtime, env,
             hooks: tree_hooks(subject, "013-p#{p}"),
             delta: F.typed_delta("Seed", "urn:sa2a:seed:" <> subject),
             principal: env.granted,
             bounds: F.bounds!(2, 2, p)
           ).result}
        end
      end)

    b6(f, ctx, runs)
  end

  defp execute("SA2A-CASCADE-014", f, ctx, runtime, env) do
    runs =
      Context.stimulus(ctx, f, fn ->
        for d <- [1, 2, 4] do
          subject = "#{subject(env, f)}-d#{d}"

          {"depth_#{d}",
           F.episode(runtime, env,
             hooks: [F.hook("sa2a-b6-pulse-d#{d}", "Pulse", "Pulse", subject)],
             delta: F.typed_delta("Pulse", "urn:sa2a:pulse:" <> subject),
             principal: env.granted,
             bounds: F.bounds!(d, 1, 1)
           ).result}
        end
      end)

    b6(f, ctx, runs)
  end

  # --- shared bodies ----------------------------------------------------------

  defp cycle(f, ctx, runtime, env, subject, hooks, seed_class, depth) do
    outcome =
      Context.stimulus(ctx, f, fn ->
        task =
          Task.async(fn ->
            F.episode(runtime, env,
              hooks: hooks,
              delta: F.typed_delta(seed_class, "urn:sa2a:cycle:" <> subject),
              principal: env.granted,
              bounds: F.bounds!(depth, 1, 1)
            )
          end)

        case Task.yield(task, @unbounded_after_ms) || Task.shutdown(task, :brutal_kill) do
          {:ok, ep} -> {:terminated, ep}
          nil -> :unbounded
          {:exit, reason} -> {:crashed, reason}
        end
      end)

    rows = F.signals(subject)
    actuations = F.count(ctx, f, "brce.actuate.start")

    case outcome do
      {:terminated, ep} ->
        Result.negative(f,
          attempt_observed?:
            F.seen?(ctx, f, "hook.cascade.start") and
              F.count(ctx, f, "brce.commit", %{"outcome" => "committed"}) >= depth,
          forbidden_outcome_observed?: actuations > depth or length(rows) > depth,
          evidence: cascade_evidence(ep.result, rows)
        )

      :unbounded ->
        Result.negative(f,
          attempt_observed?: F.seen?(ctx, f, "hook.cascade.start") and actuations > 0,
          forbidden_outcome_observed?: true,
          evidence: %{
            "unbounded_after_ms" => @unbounded_after_ms,
            "actuations" => actuations,
            "signal_rows" => length(rows)
          }
        )

      {:crashed, reason} ->
        Result.unknown(f, "cascade episode crashed: #{inspect(reason, limit: 10)}")
    end
  end

  defp tree_hooks(subject, tag) do
    [
      F.hook("sa2a-split-a-#{tag}", "Seed", "Branch", subject),
      F.hook("sa2a-split-b-#{tag}", "Seed", "Branch", subject),
      F.hook("sa2a-leaf-a-#{tag}", "Branch", "Leaf", subject),
      F.hook("sa2a-leaf-b-#{tag}", "Branch", "Leaf", subject)
    ]
  end

  # --- measurements -------------------------------------------------------------

  defp b3(f, ctx, runs) do
    records = Context.observed(ctx, f)

    measurements =
      Map.new(runs, fn {label, result} ->
        rs = for_cascade(records, result.cascade_id)
        evals = Enum.filter(rs, &(&1.activity == "hook.evaluate"))
        start = Enum.find(rs, &(&1.activity == "hook.cascade.start"))
        stop = Enum.find(rs, &(&1.activity == "hook.cascade.stop"))

        {label,
         %{
           "delta_size" => start && start.attributes["delta_size"],
           "hooks_evaluated" =>
             Enum.count(evals, &(&1.attributes["outcome"] in ["fired", "not_fired"])),
           "hooks_fired" => Enum.count(evals, &(&1.attributes["outcome"] == "fired")),
           "hooks_refused" => Enum.count(evals, &(&1.attributes["outcome"] == "refused")),
           "intent_count" => Enum.count(rs, &(&1.activity == "hook.intent.constructed")),
           "hook_evaluation_latency_us" => durations(evals),
           "intent_construction_latency_us" => durations(activity(rs, "hook.intent.constructed")),
           "idempotency_check_latency_us" => durations(activity(rs, "hook.intent.idempotency")),
           "idempotency_outcomes" =>
             rs
             |> activity("hook.intent.idempotency")
             |> Enum.frequencies_by(&to_string(&1.attributes["outcome"])),
           "route_latency_us" => durations(activity(rs, "hook.intent.routed")),
           "route_outcomes" =>
             rs
             |> activity("hook.intent.routed")
             |> Enum.frequencies_by(&to_string(&1.attributes["outcome"])),
           "episode_duration_us" => stop && stop.attributes["duration_us"],
           "terminal_outcome" => stop && stop.attributes["outcome"],
           "engine" => "praxis-graphlaw wasm via AshA2A.GraphLaw.WasmexSession (N3_DENIAL)"
         }}
      end)

    Result.measured(f,
      attempt_observed?:
        Enum.all?(runs, fn {_label, r} ->
          rs = for_cascade(records, r.cascade_id)

          Enum.any?(rs, &(&1.activity == "hook.cascade.start")) and
            Enum.any?(rs, &(&1.activity == "hook.cascade.stop")) and
            Enum.any?(rs, &(&1.activity == "hook.evaluate"))
        end),
      measurements: measurements
    )
  end

  defp b6(f, ctx, runs) do
    records = Context.observed(ctx, f)

    measurements =
      Map.new(runs, fn {label, result} ->
        rs = for_cascade(records, result.cascade_id)
        start = Enum.find(rs, &(&1.activity == "hook.cascade.start"))
        stop = Enum.find(rs, &(&1.activity == "hook.cascade.stop"))
        routes = activity(rs, "hook.intent.route_start")
        commands = MapSet.new(routes, &F.object(&1, "command"))

        {label,
         %{
           "admitted_bounds" =>
             start &&
               %{
                 "depth" => start.attributes["depth_ceiling"],
                 "fan_out" => start.attributes["fan_out_ceiling"],
                 "parallelism" => start.attributes["parallelism_ceiling"]
               },
           "cascade_depth" => stop && stop.attributes["depth_reached"],
           "generations_evaluated" => stop && stop.attributes["generations"],
           "fan_out_per_depth" =>
             rs
             |> activity("hook.intent.constructed")
             |> Enum.frequencies_by(&to_string(&1.attributes["generation"])),
           "parallelism_max_in_flight" => max_attr(routes, "in_flight"),
           "parallelism_max_actuation_overlap" => F.actuation_overlap(records, commands),
           "receipts_produced" =>
             Enum.count(
               activity(rs, "hook.intent.routed"),
               &(&1.attributes["outcome"] == "committed")
             ),
           "time_to_terminal_us" => stop && stop.attributes["duration_us"],
           "terminal_outcome" => stop && stop.attributes["outcome"],
           "terminal_code" => stop && stop.attributes["code"],
           "bound_decisions" =>
             rs
             |> activity("hook.cascade.bound")
             |> Enum.map(
               &"g#{&1.attributes["generation"]}:#{&1.attributes["bound"]}:#{&1.attributes["outcome"]}"
             ),
           "reactor_process_memory_peak_bytes" => stop && stop.attributes["memory_peak_bytes"]
         }}
      end)

    Result.measured(f,
      attempt_observed?:
        Enum.all?(runs, fn {_label, r} ->
          rs = for_cascade(records, r.cascade_id)

          Enum.any?(rs, &(&1.activity == "hook.cascade.start")) and
            Enum.any?(rs, &(&1.activity == "hook.cascade.stop"))
        end),
      measurements: measurements
    )
  end

  defp for_cascade(records, cascade_id),
    do: Enum.filter(records, &(F.object(&1, "cascade") == cascade_id))

  defp activity(records, name), do: Enum.filter(records, &(&1.activity == name))

  defp durations(records) do
    records
    |> Enum.map(& &1.attributes["duration_us"])
    |> Enum.filter(&is_integer/1)
    |> F.stats()
  end

  defp max_attr(records, key) do
    records
    |> Enum.map(& &1.attributes[key])
    |> Enum.filter(&is_integer/1)
    |> Enum.max(fn -> 0 end)
  end

  defp cascade_evidence(result, rows) do
    %{
      "cascade_outcome" => result.outcome,
      "cascade_code" => result.code,
      "generations" => result.generations,
      "depth_reached" => result.depth_reached,
      "intents" => length(result.intents),
      "route_outcomes" => Enum.frequencies_by(result.routes, &to_string(&1.outcome)),
      "bound_decisions" =>
        Enum.map(result.bound_decisions, &"g#{&1.generation}:#{&1.bound}:#{&1.outcome}"),
      "signal_rows" => length(rows)
    }
  end

  defp subject(env, %Falsifier{id: id}), do: "#{String.downcase(id)}-#{env.nonce}"
end
