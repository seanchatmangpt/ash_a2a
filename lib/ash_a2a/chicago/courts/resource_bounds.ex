defmodule AshA2A.Chicago.Courts.ResourceBounds do
  @moduledoc """
  RFC-SA2A-002 §83 Resource Bounds, §127 Bounded Concurrency, §132 No Blank
  Checks, §99 resource-bound integer edge cases and §88 Benchmark B4
  (Planning), court id `SA2A-BOUNDS`.

      Exhausted(r) ⇒ FailClosed ∨ TypedBlocked/Refused       (each r separately)
      Delegate(parent, child) ⇒ Envelope(child) ⊆ Remaining(parent) ∧ Authority(child) = Authority(parent)
      NeedMoreResources ⇏ GrantMoreResources

  Every dimension is exhausted separately against the real
  `AshA2A.Semantic.Episode` executor and its ledger: execution count,
  fan-out, concurrency (requested and in flight), memory, runtime, retries,
  external requests, financial expenditure and model tokens. Delegation,
  resource-extension and integer-edge attacks go through the same public
  envelope API a host uses. Positive controls (§100) prove the bounds admit
  exactly what they admit, that lawful delegation works, and that a
  non-model issuer can make a NEW allocation decision.

  B4 measures projection, planner invocation, plan admission, plan size and
  bounds from the observer's records of the real planning chain, reported
  separately from authority and DO latency.
  """

  use AshA2A.Chicago.Court

  alias AshA2A.Chicago.{Context, Falsifier, Result}
  alias AshA2A.Chicago.Fixtures.AutonomyBounds, as: F
  alias AshA2A.{Authority, Identity}
  alias AshA2A.Planning.HddlSolver
  alias AshA2A.Semantic.Episode
  alias AshA2A.Semantic.Episode.Envelope

  @court "SA2A-BOUNDS"

  @impl true
  def id, do: @court
  @impl true
  def title,
    do: "Resource bounds, bounded concurrency, no blank checks, integer edges and B4 planning"

  @impl true
  def gate, do: 6
  @impl true
  def profile, do: :plan
  @impl true
  def rfc_sections, do: ["§83", "§88", "§99", "§100", "§127", "§132"]

  @impl true
  def ocel_mappings, do: F.mappings()

  @impl true
  def falsifiers do
    exhaustion() ++
      concurrency() ++ delegation() ++ extension() ++ edges() ++ controls() ++ [b4()]
  end

  # One negative per spend-like dimension: an N-transition plan against a
  # ceiling admitting only `admitted` of them.
  defp exhaustion do
    [
      exhausted(
        "001",
        "execution count",
        "executions",
        4,
        2,
        "envelope executions 2; 4 record stages",
        "Ledger charge Bounds.consume(:executions)"
      ),
      negative("002",
        invariant:
          "§83 fan-out: a stage wider than the envelope's fan-out is refused before any route",
        stimulus: "one stage of 3 record transitions; envelope fan_out 2",
        boundary: "Episode stage fan-out guard",
        forbidden_outcome: "any transition start or actuation",
        attempt_evidence: ">= 3 episode.transition.request in one stage",
        survival_evidence: "episode.transition.start or brce.actuate.start; Step rows",
        guard: "Episode.stage/1 fan_out guard",
        failure_class: :bound_failure,
        rfc_sections: ["§83"],
        attempt_predicate: {:count, "episode.transition.request", :gte, 3},
        outcome_predicate:
          {:any, [{:observed, "episode.transition.start"}, {:observed, "brce.actuate.start"}]}
      ),
      negative("005",
        invariant:
          "§83 memory: an executor over its measured memory ceiling performs no transition",
        stimulus: "envelope memory_bytes 1024 (below any BEAM process); 2 record stages",
        boundary: "Episode stage memory guard (Process.info memory vs min(envelope, package))",
        forbidden_outcome:
          "any transition start or actuation, or a terminal other than resource_exhausted(memory_bytes)",
        attempt_evidence: "admitted episode whose first transition reached the stage",
        survival_evidence: "episode.transition.start, brce.actuate.start, rows",
        guard: "Episode.memory_guard/2",
        failure_class: :bound_failure,
        rfc_sections: ["§83"],
        attempt_predicate:
          {:all,
           [
             {:observed, "episode.admission", %{"outcome" => "admitted"}},
             {:observed, "episode.transition.request"}
           ]},
        outcome_predicate:
          {:any,
           [
             {:observed, "episode.transition.start"},
             {:observed, "brce.actuate.start"},
             {:not_observed, "episode.stop",
              %{"outcome" => "resource_exhausted", "resource" => "memory_bytes"}}
           ]}
      ),
      negative("006",
        invariant:
          "§83 runtime: an episode stops starting stages once the envelope's measured wall time is spent",
        stimulus:
          "envelope wall_time_ms 250; 6 record stages each sleeping 100ms inside actuation",
        boundary: "Ledger charge Allocator.check_wall_time/1 (measured from issue)",
        forbidden_outcome:
          "a 4th actuation (starts at >= 300ms) or a terminal other than resource_exhausted(wall_time_ms)",
        attempt_evidence: "episode.start plan_size 6 and >= 1 commit",
        survival_evidence: "brce.actuate.start >= 4; no wall_time_ms exhaustion",
        guard: "Allocator.check_wall_time/1 in Episode.charge/3",
        failure_class: :bound_failure,
        rfc_sections: ["§83"],
        attempt_predicate:
          {:all,
           [
             {:observed, "episode.start", %{"plan_size" => "6"}},
             {:count, "brce.commit", :gte, 1}
           ]},
        outcome_predicate:
          {:any,
           [
             {:count, "brce.actuate.start", :gte, 4},
             {:not_observed, "episode.stop",
              %{"outcome" => "resource_exhausted", "resource" => "wall_time_ms"}}
           ]}
      ),
      negative("007",
        invariant:
          "§83 retries: a persistently failing worker is retried only while retries remain",
        stimulus: "one do_work stage in mode fail; envelope retries 2, executions 16",
        boundary: "Episode.retry/4 ledger charge of :retries",
        forbidden_outcome: "a 4th attempt, or a terminal other than resource_exhausted(retries)",
        attempt_evidence: "episode.start and >= 3 actuations (1 + 2 retries)",
        survival_evidence: "brce.actuate.start >= 4; > 3 attempt rows",
        guard: "Allocator.allocate(:retries) in Episode.charge/3",
        failure_class: :bound_failure,
        rfc_sections: ["§83"],
        attempt_predicate:
          {:all, [{:observed, "episode.start"}, {:count, "brce.actuate.start", :gte, 3}]},
        outcome_predicate:
          {:any,
           [
             {:count, "brce.actuate.start", :gte, 4},
             {:not_observed, "episode.stop",
              %{"outcome" => "resource_exhausted", "resource" => "retries"}}
           ]}
      ),
      exhausted(
        "008",
        "external requests",
        "external_requests",
        4,
        2,
        "4 call_external stages costing 1 external request each; envelope external_requests 2",
        "Allocator.allocate(:external_requests)"
      ),
      exhausted(
        "009",
        "financial expenditure",
        "money_micros",
        4,
        2,
        "4 record stages costing 400000 micros each; envelope money_micros 1000000",
        "Allocator.allocate(:money_micros)"
      ),
      exhausted(
        "010",
        "model tokens",
        "tokens",
        4,
        2,
        "4 do_work stages costing 1500 tokens each; envelope tokens 4000",
        "Allocator.allocate(:tokens)"
      )
    ]
  end

  defp concurrency do
    [
      negative("003",
        invariant:
          "§83/§127 concurrency: a requested parallelism above the admitted ceiling is refused before any transition",
        stimulus:
          "one stage of 4 record transitions; envelope parallelism 2; requested parallelism 8",
        boundary: "Episode.admit_parallelism/2",
        forbidden_outcome: "any transition start or actuation",
        attempt_evidence: "episode.start requested_parallelism 8 and an admission decision",
        survival_evidence: "episode.transition.start, brce.actuate.start",
        guard: "Episode.admit_parallelism/2",
        failure_class: :bound_failure,
        rfc_sections: ["§83", "§127"],
        attempt_predicate:
          {:all,
           [
             {:observed, "episode.start", %{"requested_parallelism" => "8"}},
             {:observed, "episode.admission"}
           ]},
        outcome_predicate:
          {:any, [{:observed, "episode.transition.start"}, {:observed, "brce.actuate.start"}]}
      ),
      negative("004",
        invariant:
          "§127 declared bound: four admitted transitions in one window never have more than parallelism 2 in flight",
        stimulus:
          "one stage of 4 record transitions sleeping 40ms; envelope parallelism 2; requested 2",
        boundary: "Episode.route_window/4 Task.async_stream max_concurrency",
        forbidden_outcome:
          "a route started with in_flight > 2 or > 2 overlapping CommandBus actuations",
        attempt_evidence: "4 transition starts and 4 commits",
        survival_evidence:
          "episode.transition.start in_flight 3|4; observer actuation overlap > 2",
        guard: "Episode.route_window/4 max_concurrency: parallelism",
        failure_class: :bound_failure,
        rfc_sections: ["§127"],
        attempt_predicate:
          {:all,
           [
             {:count, "episode.transition.start", :eq, 4},
             {:count, "brce.commit", :gte, 4}
           ]},
        outcome_predicate:
          {:any,
           [
             {:observed, "episode.transition.start", %{"in_flight" => "3"}},
             {:observed, "episode.transition.start", %{"in_flight" => "4"}}
           ]}
      )
    ]
  end

  defp delegation do
    [
      negative("011",
        invariant:
          "§127: a child whose parent exhausted its envelope cannot obtain a fresh one -- not by delegation, a stale parent handle, a forged handle, a zero delegation, a host envelope claiming the parent, or an in-executor subplan",
        stimulus:
          "parent executions 2 consumed by a 2-stage episode; delegate executions 1 from the parent and from its pre-consumption handle; run on a forged handle; run a zero delegation; run a fresh host envelope with parent: parent; parent2 with executions 1 whose stage 2 is a subplan delegating executions 1",
        boundary:
          "Episode.delegate/2 (ledger + Bounds.delegate/2), Episode admission (ledger, delegated_from)",
        forbidden_outcome:
          "an admitted delegation of executions from the exhausted parent, or any child actuation",
        attempt_evidence: ">= 7 allocation decisions and >= 5 episode starts",
        survival_evidence:
          "episode.allocation delegate admitted requested_executions 1; brce.actuate.start >= 4",
        guard:
          "Bounds.delegate/2 narrowing over the ledger's parent entry; Ledger unknown id; delegated_from/2",
        failure_class: :bound_failure,
        rfc_sections: ["§127"],
        attempt_predicate:
          {:all, [{:count, "episode.allocation", :gte, 7}, {:count, "episode.start", :gte, 5}]},
        outcome_predicate:
          {:any,
           [
             {:observed, "episode.allocation",
              %{"kind" => "delegate", "outcome" => "admitted", "requested_executions" => "1"}},
             {:count, "brce.actuate.start", :gte, 4}
           ]}
      ),
      negative("012",
        invariant:
          "§127: delegation cannot manufacture authority -- a delegation carrying an authority or principal is refused, and a subtask of a principal lacking a grant stays refused at the consequence boundary",
        stimulus:
          "delegate with authority: %Authority{}, with principal: escalated, with a capability outside the parent; a limited principal's subplan to call_external; a subplan naming principal: escalated",
        boundary: "Episode.delegate/2, Episode subplan admission, CommandBus authority admission",
        forbidden_outcome: "an admitted delegation carrying authority, or any actuation",
        attempt_evidence:
          ">= 5 allocation decisions, a CommandBus admission decision, >= 2 episode admissions",
        survival_evidence:
          "episode.allocation delegate admitted carries_authority true; brce.actuate.start",
        guard:
          "Bounds.delegate/2 no_manufactured_authority, Episode.no_principal/1, subplan principal refusal, CommandBus.admit/2",
        failure_class: :authority_failure,
        rfc_sections: ["§127"],
        attempt_predicate:
          {:all,
           [
             {:count, "episode.allocation", :gte, 5},
             {:observed, "brce.admission"},
             {:count, "episode.admission", :gte, 2}
           ]},
        outcome_predicate:
          {:any,
           [
             {:observed, "episode.allocation",
              %{"kind" => "delegate", "outcome" => "admitted", "carries_authority" => "true"}},
             {:observed, "brce.actuate.start"}
           ]}
      ),
      negative("013",
        invariant:
          "§127: a subtask inherits its parent's concurrency ceiling -- it can neither delegate wider parallelism nor request it at run time",
        stimulus:
          "parent parallelism 2: delegate parallelism 4; delegate parallelism 2 then run a 4-wide stage requesting parallelism 4",
        boundary:
          "Bounds.delegate/2 parallelism narrowing; Episode.admit_parallelism/2 on the child",
        forbidden_outcome:
          "an admitted delegation of parallelism 4 or any child transition start",
        attempt_evidence:
          "delegation requested_parallelism 4 and a child episode.start requested_parallelism 4",
        survival_evidence:
          "episode.allocation delegate admitted requested_parallelism 4; episode.transition.start",
        guard: "Bounds.delegate/2 narrowed(:parallelism); Episode.admit_parallelism/2",
        failure_class: :bound_failure,
        rfc_sections: ["§127"],
        attempt_predicate:
          {:all,
           [
             {:observed, "episode.allocation",
              %{"kind" => "delegate", "requested_parallelism" => "4"}},
             {:observed, "episode.start", %{"requested_parallelism" => "4"}}
           ]},
        outcome_predicate:
          {:any,
           [
             {:observed, "episode.allocation",
              %{"kind" => "delegate", "outcome" => "admitted", "requested_parallelism" => "4"}},
             {:observed, "episode.transition.start"}
           ]}
      )
    ]
  end

  defp extension do
    [
      negative("014",
        invariant:
          "§132: NeedMoreResources ⇏ GrantMoreResources -- a running worker's request for more tokens does not extend the envelope",
        stimulus:
          "envelope tokens 2000; stage 1 do_work (1000 tokens) replies need_more_resources tokens 5000; stage 2 do_work costs 3000",
        boundary: "Episode extension -> Allocator.request_increase/2",
        forbidden_outcome:
          "an admitted extension, a second actuation, or a token limit above 2000",
        attempt_evidence: "episode.transition.stop carrying the worker's resource request",
        survival_evidence:
          "episode.allocation extension admitted; brce.actuate.start >= 2; ledger limit",
        guard: "Allocator.request_increase/2 (no success clause)",
        failure_class: :bound_failure,
        rfc_sections: ["§132", "§80"],
        attempt_predicate:
          {:observed, "episode.transition.stop", %{"resource_request" => "true"}},
        outcome_predicate:
          {:any,
           [
             {:observed, "episode.allocation", %{"kind" => "extension", "outcome" => "admitted"}},
             {:count, "brce.actuate.start", :gte, 2}
           ]}
      )
    ]
  end

  defp edges do
    [
      negative("016",
        invariant:
          "§99 integer edges at issue: negative, non-integer, infinite and overflow-sized (> 2^63-1) ceilings are refused, never admitted as bounds",
        stimulus:
          "issue with executions -1, parallelism 1.5, retries :infinity, tokens 2^64, fan_out 2^63, memory_bytes -5",
        boundary: "Episode.issue/2 (representable, Bounds.new/1, Allocator.new/2)",
        forbidden_outcome: "any admitted issue",
        attempt_evidence: "6 allocation decisions",
        survival_evidence: "episode.allocation outcome admitted",
        guard:
          "Episode.representable/1, Bounds.fetch_ceiling/2, Allocator.validate_limits/1, memory_ceiling/1",
        failure_class: :bound_failure,
        rfc_sections: ["§83", "§99"],
        attempt_predicate: {:count, "episode.allocation", :gte, 6},
        outcome_predicate: {:observed, "episode.allocation", %{"outcome" => "admitted"}}
      ),
      negative("017",
        invariant:
          "§99 integer edges at spend: a negative cost cannot credit an envelope, an overflow-sized cost cannot wrap, zero ceilings admit nothing, and negative or overflow delegations are refused",
        stimulus:
          "plans costing tokens -500 and 2^70; envelopes with executions 0 and fan_out 0; requested parallelism -1; delegations of executions -1 and 2^64",
        boundary:
          "Episode admission cost_valid/1, ledger charge, stage guards, Episode.delegate/2",
        forbidden_outcome: "any actuation or admitted delegation",
        attempt_evidence: ">= 5 episode starts",
        survival_evidence:
          "brce.actuate.start; episode.allocation delegate admitted; ledger tokens consumed < 0",
        guard:
          "Episode.cost_valid/1, Allocator.allocate/3, Bounds.consume/3, fan-out guard, admit_parallelism/2, representable/1",
        failure_class: :bound_failure,
        rfc_sections: ["§83", "§99"],
        attempt_predicate: {:count, "episode.start", :gte, 5},
        outcome_predicate:
          {:any,
           [
             {:observed, "brce.actuate.start"},
             {:observed, "episode.allocation", %{"kind" => "delegate", "outcome" => "admitted"}}
           ]}
      )
    ]
  end

  defp controls do
    [
      positive(
        "015",
        "§132/§80 discrimination: a resource request becomes a NEW allocation decision only from a non-model issuer -- model reissue refused, reissue below consumption refused, host reissue admitted with consumption carried forward, the superseded envelope unspendable",
        "need_more episode on tokens 2000; reallocate by {:model, _}, by host below consumed, by host to 8000; spend the old handle; run 3000 tokens on the new envelope",
        "Episode.reallocate/3 (Allocator.reissue/3) and ledger status",
        {:all,
         [
           {:observed, "episode.transition.stop", %{"resource_request" => "true"}},
           {:observed, "episode.allocation", %{"kind" => "reissue"}}
         ]},
        {:all,
         [
           {:observed, "episode.allocation",
            %{
              "kind" => "reissue",
              "outcome" => "refused",
              "code" => "model_issued_budget_refused"
            }},
           {:observed, "episode.allocation",
            %{"kind" => "reissue", "outcome" => "refused", "code" => "reissue_below_consumed"}},
           {:observed, "episode.allocation", %{"kind" => "reissue", "outcome" => "admitted"}},
           {:observed, "episode.admission",
            %{"outcome" => "refused", "code" => "episode_envelope_superseded"}},
           {:observed, "episode.stop", %{"outcome" => "completed", "committed" => "1"}}
         ]}
      ),
      positive(
        "018",
        "§100: bounds admit exactly what they admit -- a plan at every ceiling (executions, fan-out, parallelism, tokens, money, external requests) completes",
        "2 stages x 2 transitions; envelope executions 4, fan_out 2, parallelism 2, tokens 3000, money 800000, external_requests 1",
        "Episode stage guards and ledger charge",
        {:observed, "episode.start"},
        {:all,
         [
           {:observed, "episode.stop", %{"outcome" => "completed", "committed" => "4"}},
           {:count, "brce.commit", :eq, 4},
           {:not_observed, "episode.bound", %{"outcome" => "refused"}}
         ]}
      ),
      positive(
        "019",
        "§127 discrimination: a subtask delegated within the parent's remaining envelope completes, and the parent is debited",
        "parent executions 4, tokens 3000: record, subplan(delegate executions 2 tokens 1000: record + do_work 1000 tokens), record",
        "Episode subplan route -> Episode.delegate/2 -> child Episode.run/3",
        {:observed, "episode.start"},
        {:all,
         [
           {:observed, "episode.allocation", %{"kind" => "delegate", "outcome" => "admitted"}},
           {:observed, "episode.stop", %{"outcome" => "completed", "committed" => "3"}},
           {:observed, "episode.stop", %{"outcome" => "completed", "committed" => "2"}},
           {:count, "brce.commit", :eq, 4}
         ]}
      )
    ]
  end

  defp b4 do
    Falsifier.new!(
      id: "#{@court}-020",
      court_id: @court,
      kind: :measurement,
      invariant:
        "SA2A-B4: planning projection, planner invocation and plan admission time, plan size, bounds and resource envelope -- separated from authority and DO latency",
      stimulus:
        "3 real planning chains (admitted semantics -> projection -> hddl_cli -> strict PlanPackage), then one episode over the last plan",
      boundary: "AshA2A.Semantic.Episode.plan/5 phases and Episode.run/3 transitions",
      attempt_evidence: ">= 9 episode.planning phases and a completed episode",
      survival_evidence: "measurements derived from observer records attributed to the stimulus",
      rfc_sections: ["§88", "§102"],
      tags: [:benchmark],
      attempt_predicate:
        {:all,
         [
           {:count, "episode.planning", :gte, 9},
           {:observed, "episode.stop", %{"outcome" => "completed"}}
         ]},
      outcome_predicate: {:count, "brce.commit", :gte, 5}
    )
  end

  defp exhausted(suffix, label, resource, planned, admitted, stimulus, guard) do
    negative(suffix,
      invariant:
        "§83 #{label}: a #{planned}-transition plan against a ceiling admitting #{admitted} stops fail-closed at #{admitted}",
      stimulus: stimulus,
      boundary: "Episode.charge/3 atomic ledger charge",
      forbidden_outcome:
        "actuation #{admitted + 1}, or a terminal other than resource_exhausted(#{resource})",
      attempt_evidence: "episode.start plan_size #{planned} and >= #{admitted} commits",
      survival_evidence: "brce.actuate.start >= #{admitted + 1}; no typed exhaustion; rows",
      guard: guard,
      failure_class: :bound_failure,
      rfc_sections: ["§83"],
      attempt_predicate:
        {:all,
         [
           {:observed, "episode.start", %{"plan_size" => "#{planned}"}},
           {:count, "brce.commit", :gte, admitted}
         ]},
      outcome_predicate:
        {:any,
         [
           {:count, "brce.actuate.start", :gte, admitted + 1},
           {:not_observed, "episode.stop",
            %{"outcome" => "resource_exhausted", "resource" => resource}}
         ]}
    )
  end

  defp negative(suffix, fields) do
    Falsifier.new!([id: "#{@court}-#{suffix}", court_id: @court, kind: :negative] ++ fields)
  end

  defp positive(suffix, invariant, stimulus, boundary, attempt, expected) do
    Falsifier.new!(
      id: "#{@court}-#{suffix}",
      court_id: @court,
      kind: :positive_control,
      invariant: invariant,
      stimulus: stimulus,
      boundary: boundary,
      attempt_evidence: "the lawful case reached the envelope boundary",
      survival_evidence: "the expected admitted/completed outcome in OCEL, ledger and rows",
      rfc_sections: ["§100", "§127", "§132"],
      attempt_predicate: attempt,
      outcome_predicate: expected
    )
  end

  # --- execution --------------------------------------------------------------------

  @impl true
  def run(%Context{} = ctx) do
    F.with_env(fn env ->
      projection = F.projection()

      falsifiers()
      |> Enum.sort_by(& &1.id)
      |> Enum.map(fn f -> F.guarded(f, fn -> execute(f.id, f, ctx, env, projection) end) end)
    end)
  end

  # §83 spend-like exhaustion ------------------------------------------------------

  defp execute("SA2A-BOUNDS-001", f, ctx, env, projection) do
    spend(f, ctx, env, projection, %{
      resource: :executions,
      envelope: [executions: 2],
      builder: &F.record/3,
      cost: %{}
    })
  end

  defp execute("SA2A-BOUNDS-008", f, ctx, env, projection) do
    spend(f, ctx, env, projection, %{
      resource: :external_requests,
      envelope: [external_requests: 2],
      builder: &F.external/3,
      cost: %{external_requests: 1}
    })
  end

  defp execute("SA2A-BOUNDS-009", f, ctx, env, projection) do
    spend(f, ctx, env, projection, %{
      resource: :money_micros,
      envelope: [money_micros: 1_000_000],
      builder: &F.record/3,
      cost: %{money_micros: 400_000}
    })
  end

  defp execute("SA2A-BOUNDS-010", f, ctx, env, projection) do
    spend(f, ctx, env, projection, %{
      resource: :tokens,
      envelope: [tokens: 4_000],
      builder: &F.work/3,
      cost: %{tokens: 1_500}
    })
  end

  defp execute("SA2A-BOUNDS-002", f, ctx, env, projection) do
    tag = tag(env, f)
    package = F.static_package!(projection, 3)

    result =
      Context.stimulus(ctx, f, fn ->
        F.run!(package, F.envelope!(fan_out: 2), env, bind: F.bind(&F.record(tag, &1, stage: 1)))
      end)

    rows = F.rows(tag)

    Result.negative(f,
      attempt_observed?: F.count(ctx, f, "episode.transition.request") >= 3,
      forbidden_outcome_observed?:
        F.seen?(ctx, f, "episode.transition.start") or F.seen?(ctx, f, "brce.actuate.start") or
          rows != [] or result.code != :bounds_fan_out_exceeded,
      evidence: evidence(result, rows)
    )
  end

  defp execute("SA2A-BOUNDS-003", f, ctx, env, projection) do
    tag = tag(env, f)
    package = F.static_package!(projection, 4)

    result =
      Context.stimulus(ctx, f, fn ->
        F.run!(package, F.envelope!(parallelism: 2), env,
          bind: F.bind(&F.record(tag, &1, stage: 1)),
          parallelism: 8
        )
      end)

    rows = F.rows(tag)

    Result.negative(f,
      attempt_observed?:
        F.seen?(ctx, f, "episode.start", %{"requested_parallelism" => "8"}) and
          F.seen?(ctx, f, "episode.admission"),
      forbidden_outcome_observed?:
        F.seen?(ctx, f, "episode.transition.start") or F.seen?(ctx, f, "brce.actuate.start") or
          rows != [] or result.code != :bounds_parallelism_exceeded,
      evidence: evidence(result, rows)
    )
  end

  defp execute("SA2A-BOUNDS-004", f, ctx, env, projection) do
    tag = tag(env, f)
    package = F.static_package!(projection, 4)

    result =
      Context.stimulus(ctx, f, fn ->
        F.run!(package, F.envelope!(parallelism: 2), env,
          bind: F.bind(&F.record(tag, &1, stage: 1, delay_ms: 40)),
          parallelism: 2
        )
      end)

    records = Context.observed(ctx, f)

    max_in_flight =
      records
      |> Enum.filter(&(&1.activity == "episode.transition.start"))
      |> Enum.map(& &1.attributes["in_flight"])
      |> Enum.filter(&is_integer/1)
      |> Enum.max(fn -> 0 end)

    overlap = F.actuation_overlap(records)
    rows = F.rows(tag)

    Result.negative(f,
      attempt_observed?:
        F.count(ctx, f, "episode.transition.start") == 4 and F.count(ctx, f, "brce.commit") >= 4,
      forbidden_outcome_observed?: max_in_flight > 2 or overlap > 2 or length(rows) != 4,
      evidence:
        result
        |> evidence(rows)
        |> Map.merge(%{"max_in_flight" => max_in_flight, "max_actuation_overlap" => overlap})
    )
  end

  defp execute("SA2A-BOUNDS-005", f, ctx, env, projection) do
    tag = tag(env, f)
    package = F.static_package!(projection, 2)

    result =
      Context.stimulus(ctx, f, fn ->
        F.run!(package, F.envelope!(memory_bytes: 1_024), env, bind: F.bind(&F.record(tag, &1)))
      end)

    rows = F.rows(tag)

    Result.negative(f,
      attempt_observed?:
        F.seen?(ctx, f, "episode.admission", %{"outcome" => "admitted"}) and
          F.seen?(ctx, f, "episode.transition.request"),
      forbidden_outcome_observed?:
        F.seen?(ctx, f, "episode.transition.start") or F.seen?(ctx, f, "brce.actuate.start") or
          rows != [] or {result.outcome, result.resource} != {:resource_exhausted, :memory_bytes},
      evidence: evidence(result, rows)
    )
  end

  defp execute("SA2A-BOUNDS-006", f, ctx, env, projection) do
    tag = tag(env, f)
    package = F.static_package!(projection, 6)

    result =
      Context.stimulus(ctx, f, fn ->
        F.run!(package, F.envelope!(wall_time_ms: 250), env,
          bind: F.bind(&F.record(tag, &1, delay_ms: 100))
        )
      end)

    rows = F.rows(tag)

    Result.negative(f,
      attempt_observed?:
        F.seen?(ctx, f, "episode.start", %{"plan_size" => "6"}) and
          F.count(ctx, f, "brce.commit") >= 1,
      forbidden_outcome_observed?:
        F.count(ctx, f, "brce.actuate.start") >= 4 or length(rows) >= 4 or
          {result.outcome, result.resource} != {:resource_exhausted, :wall_time_ms},
      evidence: evidence(result, rows)
    )
  end

  defp execute("SA2A-BOUNDS-007", f, ctx, env, projection) do
    tag = tag(env, f)
    package = F.static_package!(projection, 1)

    result =
      Context.stimulus(ctx, f, fn ->
        F.run!(package, F.envelope!(retries: 2, executions: 16), env,
          bind: F.bind(&F.work(tag, &1, mode: "fail"))
        )
      end)

    rows = F.rows(tag)

    Result.negative(f,
      attempt_observed?:
        F.seen?(ctx, f, "episode.start") and F.count(ctx, f, "brce.actuate.start") >= 3,
      forbidden_outcome_observed?:
        F.count(ctx, f, "brce.actuate.start") >= 4 or length(rows) > 3 or
          {result.outcome, result.resource} != {:resource_exhausted, :retries},
      evidence: Map.put(evidence(result, rows), "retries", result.retries)
    )
  end

  # §127 delegation ----------------------------------------------------------------

  defp execute("SA2A-BOUNDS-011", f, ctx, env, projection) do
    tag = tag(env, f)
    two = F.static_package!(projection, 2)
    one = F.static_package!(projection, 1)
    record = F.bind(&F.record(tag, &1))

    outcome =
      Context.stimulus(ctx, f, fn ->
        parent = F.envelope!(executions: 2, depth: 4)
        stale = parent
        parent_run = F.run!(two, parent, env, bind: record)

        from_parent = Episode.delegate(parent, executions: 1)
        from_stale = Episode.delegate(stale, executions: 1)
        forged = %Envelope{id: "envelope-forged-#{env.nonce}", issued_by: {:host, :forged}}
        forged_run = F.run!(one, forged, env, bind: record)
        {:ok, zero} = Episode.delegate(parent, [])
        zero_run = F.run!(one, zero, env, bind: record, parent: parent.id)
        fresh = F.envelope!()
        fresh_run = F.run!(one, fresh, env, bind: record, parent: parent.id)

        parent2 = F.envelope!(executions: 1, depth: 4)

        subplan_run =
          F.run!(two, parent2, env,
            bind:
              F.bind(fn
                1 ->
                  F.record(tag, 1)

                2 ->
                  %{
                    kind: :subplan,
                    package: one,
                    bind: F.bind(&F.record(tag <> "-child", &1)),
                    control: F.control(),
                    delegate: [executions: 1]
                  }
              end)
          )

        {:ok, parent_snapshot} = Episode.snapshot(parent)

        %{
          parent_run: parent_run,
          from_parent: from_parent,
          from_stale: from_stale,
          forged_run: forged_run,
          zero_run: zero_run,
          fresh_run: fresh_run,
          subplan_run: subplan_run,
          parent_snapshot: parent_snapshot
        }
      end)

    child_runs = [outcome.forged_run, outcome.zero_run, outcome.fresh_run]
    rows = F.rows(tag)

    Result.negative(f,
      attempt_observed?:
        F.count(ctx, f, "episode.allocation") >= 7 and F.count(ctx, f, "episode.start") >= 5,
      forbidden_outcome_observed?:
        match?({:ok, _}, outcome.from_parent) or match?({:ok, _}, outcome.from_stale) or
          Enum.any?(child_runs, &(&1.committed > 0)) or F.rows(tag <> "-child") != [] or
          F.count(ctx, f, "brce.actuate.start") >= 4 or
          outcome.parent_snapshot.executions.consumed > outcome.parent_snapshot.executions.limit,
      evidence: %{
        "parent_run" => "#{outcome.parent_run.outcome}:#{outcome.parent_run.committed}",
        "from_parent" => refusal_code(outcome.from_parent),
        "from_stale" => refusal_code(outcome.from_stale),
        "forged_run" => "#{outcome.forged_run.outcome}:#{outcome.forged_run.code}",
        "zero_run" =>
          "#{outcome.zero_run.outcome}:#{outcome.zero_run.code}:#{outcome.zero_run.resource}",
        "fresh_run" => "#{outcome.fresh_run.outcome}:#{outcome.fresh_run.code}",
        "subplan_run" =>
          "#{outcome.subplan_run.outcome}:#{outcome.subplan_run.code}:#{outcome.subplan_run.committed}",
        "parent_executions" => outcome.parent_snapshot.executions,
        "step_rows" => length(rows)
      }
    )
  end

  defp execute("SA2A-BOUNDS-012", f, ctx, env, projection) do
    tag = tag(env, f)
    one = F.static_package!(projection, 1)

    outcome =
      Context.stimulus(ctx, f, fn ->
        parent = F.envelope!()
        authority = Authority.new(Identity.principal(env.escalated), F.external_capability())

        with_authority = Episode.delegate(parent, executions: 1, authority: authority)
        with_principal = Episode.delegate(parent, executions: 1, principal: env.escalated)

        widened =
          Episode.delegate(parent,
            executions: 1,
            capabilities: F.capabilities() ++ ["AshA2A.Some.Undelegated.capability"]
          )

        external_child = F.bind(&F.external(tag <> "-child", &1))

        limited_subplan =
          F.run!(one, parent, env,
            principal: env.limited,
            bind:
              F.bind(fn 1 ->
                %{
                  kind: :subplan,
                  package: one,
                  bind: external_child,
                  control: F.control(),
                  delegate: [executions: 1, capabilities: [F.external_capability()]]
                }
              end)
          )

        named_principal =
          F.run!(one, parent, env,
            principal: env.limited,
            bind:
              F.bind(fn 1 ->
                %{
                  kind: :subplan,
                  package: one,
                  bind: external_child,
                  control: F.control(),
                  delegate: [executions: 1],
                  principal: env.escalated
                }
              end)
          )

        %{
          with_authority: with_authority,
          with_principal: with_principal,
          widened: widened,
          limited_subplan: limited_subplan,
          named_principal: named_principal
        }
      end)

    rows = F.rows(tag <> "-child")

    Result.negative(f,
      attempt_observed?:
        F.count(ctx, f, "episode.allocation") >= 5 and F.seen?(ctx, f, "brce.admission") and
          F.count(ctx, f, "episode.admission") >= 2,
      forbidden_outcome_observed?:
        Enum.any?(
          [outcome.with_authority, outcome.with_principal, outcome.widened],
          &match?({:ok, _}, &1)
        ) or F.seen?(ctx, f, "brce.actuate.start") or rows != [] or
          outcome.limited_subplan.committed > 0 or outcome.named_principal.committed > 0,
      evidence: %{
        "with_authority" => refusal_code(outcome.with_authority),
        "with_principal" => refusal_code(outcome.with_principal),
        "widened_capabilities" => refusal_code(outcome.widened),
        "limited_subplan" => "#{outcome.limited_subplan.outcome}:#{outcome.limited_subplan.code}",
        "named_principal_subplan" =>
          "#{outcome.named_principal.outcome}:#{outcome.named_principal.code}",
        "child_rows" => length(rows)
      }
    )
  end

  defp execute("SA2A-BOUNDS-013", f, ctx, env, projection) do
    tag = tag(env, f)
    four = F.static_package!(projection, 4)

    outcome =
      Context.stimulus(ctx, f, fn ->
        parent = F.envelope!(parallelism: 2)
        wider = Episode.delegate(parent, executions: 4, parallelism: 4)
        {:ok, child} = Episode.delegate(parent, executions: 4, parallelism: 2)

        child_run =
          F.run!(four, child, env,
            bind: F.bind(&F.record(tag, &1, stage: 1)),
            parallelism: 4,
            parent: parent.id
          )

        {:ok, snapshot} = Episode.snapshot(child)
        %{wider: wider, child_run: child_run, child_parallelism: snapshot.parallelism}
      end)

    Result.negative(f,
      attempt_observed?:
        F.seen?(ctx, f, "episode.allocation", %{
          "kind" => "delegate",
          "requested_parallelism" => "4"
        }) and F.seen?(ctx, f, "episode.start", %{"requested_parallelism" => "4"}),
      forbidden_outcome_observed?:
        match?({:ok, _}, outcome.wider) or F.seen?(ctx, f, "episode.transition.start") or
          F.rows(tag) != [] or outcome.child_parallelism > 2,
      evidence: %{
        "wider_delegation" => refusal_code(outcome.wider),
        "child_run" => "#{outcome.child_run.outcome}:#{outcome.child_run.code}",
        "child_parallelism_ceiling" => outcome.child_parallelism
      }
    )
  end

  # §132 ------------------------------------------------------------------------------

  defp execute("SA2A-BOUNDS-014", f, ctx, env, projection) do
    tag = tag(env, f)
    package = F.static_package!(projection, 2)

    {result, envelope} =
      Context.stimulus(ctx, f, fn ->
        envelope = F.envelope!(tokens: 2_000)

        result =
          F.run!(package, envelope, env,
            bind:
              F.bind(fn
                1 -> F.work(tag, 1, mode: "need_more", need_tokens: 5_000, cost: %{tokens: 1_000})
                2 -> F.work(tag, 2, cost: %{tokens: 3_000})
              end)
          )

        {result, envelope}
      end)

    {:ok, snapshot} = Episode.snapshot(envelope)
    rows = F.rows(tag)

    Result.negative(f,
      attempt_observed?:
        F.seen?(ctx, f, "episode.transition.stop", %{"resource_request" => "true"}),
      forbidden_outcome_observed?:
        F.seen?(ctx, f, "episode.allocation", %{"kind" => "extension", "outcome" => "admitted"}) or
          F.count(ctx, f, "brce.actuate.start") >= 2 or length(rows) > 1 or
          snapshot.spend.limits.tokens != 2_000 or
          snapshot.spend.consumed.tokens > snapshot.spend.limits.tokens or
          result.code != :self_grant_refused,
      evidence:
        result
        |> evidence(rows)
        |> Map.merge(%{
          "extension" =>
            result.extension && Map.take(result.extension, [:request, :outcome, :code]),
          "token_limit" => snapshot.spend.limits.tokens,
          "tokens_consumed" => snapshot.spend.consumed.tokens
        })
    )
  end

  # §99 integer edges -----------------------------------------------------------------

  defp execute("SA2A-BOUNDS-016", f, ctx, _env, _projection) do
    edges = [
      executions: -1,
      parallelism: 1.5,
      retries: :infinity,
      tokens: Integer.pow(2, 64),
      fan_out: Integer.pow(2, 63),
      memory_bytes: -5
    ]

    results =
      Context.stimulus(ctx, f, fn ->
        for {key, value} <- edges do
          {key, Episode.issue({:host, :sa2a_chicago_court}, F.envelope_spec([{key, value}]))}
        end
      end)

    Result.negative(f,
      attempt_observed?: F.count(ctx, f, "episode.allocation") >= 6,
      forbidden_outcome_observed?:
        F.seen?(ctx, f, "episode.allocation", %{"outcome" => "admitted"}) or
          Enum.any?(results, fn {_k, r} -> match?({:ok, _}, r) end),
      evidence: Map.new(results, fn {key, r} -> {Atom.to_string(key), refusal_code(r)} end)
    )
  end

  defp execute("SA2A-BOUNDS-017", f, ctx, env, projection) do
    tag = tag(env, f)
    one = F.static_package!(projection, 1)
    two_wide = F.static_package!(projection, 2)

    outcome =
      Context.stimulus(ctx, f, fn ->
        negative_env = F.envelope!(tokens: 1_000)

        negative_cost =
          F.run!(one, negative_env, env, bind: F.bind(&F.work(tag, &1, cost: %{tokens: -500})))

        overflow_cost =
          F.run!(one, F.envelope!(), env,
            bind: F.bind(&F.work(tag, &1, cost: %{tokens: Integer.pow(2, 70)}))
          )

        zero_executions =
          F.run!(one, F.envelope!(executions: 0), env, bind: F.bind(&F.record(tag, &1)))

        zero_fan_out =
          F.run!(two_wide, F.envelope!(fan_out: 0), env,
            bind: F.bind(&F.record(tag, &1, stage: 1))
          )

        negative_parallelism =
          F.run!(one, F.envelope!(), env, bind: F.bind(&F.record(tag, &1)), parallelism: -1)

        parent = F.envelope!()

        %{
          negative_cost: negative_cost,
          overflow_cost: overflow_cost,
          zero_executions: zero_executions,
          zero_fan_out: zero_fan_out,
          negative_parallelism: negative_parallelism,
          negative_delegation: Episode.delegate(parent, executions: -1),
          overflow_delegation: Episode.delegate(parent, executions: Integer.pow(2, 64)),
          negative_snapshot: elem(Episode.snapshot(negative_env), 1)
        }
      end)

    runs = [
      outcome.negative_cost,
      outcome.overflow_cost,
      outcome.zero_executions,
      outcome.zero_fan_out,
      outcome.negative_parallelism
    ]

    Result.negative(f,
      attempt_observed?: F.count(ctx, f, "episode.start") >= 5,
      forbidden_outcome_observed?:
        F.seen?(ctx, f, "brce.actuate.start") or F.rows(tag) != [] or
          Enum.any?(runs, &(&1.committed > 0)) or
          match?({:ok, _}, outcome.negative_delegation) or
          match?({:ok, _}, outcome.overflow_delegation) or
          outcome.negative_snapshot.spend.consumed.tokens != 0 or
          outcome.negative_snapshot.spend.limits.tokens != 1_000,
      evidence: %{
        "runs" => Enum.map(runs, &"#{&1.outcome}:#{&1.code}:#{&1.resource}"),
        "negative_delegation" => refusal_code(outcome.negative_delegation),
        "overflow_delegation" => refusal_code(outcome.overflow_delegation),
        "negative_cost_tokens_consumed" => outcome.negative_snapshot.spend.consumed.tokens
      }
    )
  end

  # positive controls -----------------------------------------------------------------

  defp execute("SA2A-BOUNDS-015", f, ctx, env, projection) do
    tag = tag(env, f)
    one = F.static_package!(projection, 1)

    outcome =
      Context.stimulus(ctx, f, fn ->
        envelope = F.envelope!(tokens: 2_000)

        need =
          F.run!(one, envelope, env,
            bind:
              F.bind(
                &F.work(tag, &1, mode: "need_more", need_tokens: 5_000, cost: %{tokens: 1_000})
              )
          )

        model = Episode.reallocate(envelope, {:model, "sa2a-court-model"}, tokens: 8_000)
        below = Episode.reallocate(envelope, {:host, :sa2a_ops}, tokens: 500)
        {:ok, renewed} = Episode.reallocate(envelope, {:host, :sa2a_ops}, tokens: 8_000)

        stale = F.run!(one, envelope, env, bind: F.bind(&F.work(tag <> "-stale", &1)))

        continued =
          F.run!(one, renewed, env, bind: F.bind(&F.work(tag, &1, cost: %{tokens: 3_000})))

        {:ok, old} = Episode.snapshot(envelope)
        {:ok, new} = Episode.snapshot(renewed)

        %{
          need: need,
          model: model,
          below: below,
          stale: stale,
          continued: continued,
          old: old,
          new: new
        }
      end)

    Result.positive(f,
      attempt_observed?:
        F.seen?(ctx, f, "episode.transition.stop", %{"resource_request" => "true"}) and
          F.seen?(ctx, f, "episode.allocation", %{"kind" => "reissue"}),
      expected_outcome_observed?:
        outcome.need.code == :self_grant_refused and
          refusal_code(outcome.model) == "model_issued_budget_refused" and
          refusal_code(outcome.below) == "reissue_below_consumed" and
          outcome.stale.code == :episode_envelope_superseded and
          outcome.continued.outcome == :completed and outcome.old.status == :superseded and
          outcome.new.spend.limits.tokens == 8_000 and outcome.new.spend.consumed.tokens == 4_000,
      evidence: %{
        "need" => "#{outcome.need.outcome}:#{outcome.need.code}",
        "model_reissue" => refusal_code(outcome.model),
        "below_consumed_reissue" => refusal_code(outcome.below),
        "stale_spend" => "#{outcome.stale.outcome}:#{outcome.stale.code}",
        "continued" => "#{outcome.continued.outcome}:#{outcome.continued.committed}",
        "renewed_tokens" => outcome.new.spend,
        "superseded_status" => outcome.old.status
      }
    )
  end

  defp execute("SA2A-BOUNDS-018", f, ctx, env, projection) do
    tag = tag(env, f)
    package = F.static_package!(projection, 4)

    bind =
      F.bind(fn
        1 -> F.record(tag, 1, stage: :a, cost: %{money_micros: 400_000})
        2 -> F.work(tag, 2, stage: :a, cost: %{tokens: 1_500})
        3 -> F.work(tag, 3, stage: :b, cost: %{tokens: 1_500, money_micros: 400_000})
        4 -> F.external(tag, 4, stage: :b, cost: %{external_requests: 1})
      end)

    {result, snapshot} =
      Context.stimulus(ctx, f, fn ->
        envelope =
          F.envelope!(
            executions: 4,
            fan_out: 2,
            parallelism: 2,
            tokens: 3_000,
            money_micros: 800_000,
            external_requests: 1
          )

        result = F.run!(package, envelope, env, bind: bind, parallelism: 2)
        {:ok, snapshot} = Episode.snapshot(envelope)
        {result, snapshot}
      end)

    rows = F.rows(tag)

    Result.positive(f,
      attempt_observed?: F.seen?(ctx, f, "episode.start"),
      expected_outcome_observed?:
        result.outcome == :completed and result.committed == 4 and length(rows) == 4 and
          snapshot.executions.remaining == 0 and snapshot.spend.consumed.tokens == 3_000 and
          snapshot.spend.consumed.money_micros == 800_000 and
          snapshot.spend.consumed.external_requests == 1 and
          not F.seen?(ctx, f, "episode.bound", %{"outcome" => "refused"}),
      evidence:
        result
        |> evidence(rows)
        |> Map.merge(%{"executions" => snapshot.executions, "spend" => snapshot.spend})
    )
  end

  defp execute("SA2A-BOUNDS-019", f, ctx, env, projection) do
    tag = tag(env, f)
    three = F.static_package!(projection, 3)
    two = F.static_package!(projection, 2)

    child_bind =
      F.bind(fn
        1 -> F.record(tag <> "-child", 1)
        2 -> F.work(tag <> "-child", 2, cost: %{tokens: 1_000})
      end)

    {result, snapshot} =
      Context.stimulus(ctx, f, fn ->
        parent = F.envelope!(executions: 4, tokens: 3_000, depth: 4)

        result =
          F.run!(three, parent, env,
            bind:
              F.bind(fn
                2 ->
                  %{
                    kind: :subplan,
                    package: two,
                    bind: child_bind,
                    control: F.control(),
                    delegate: [executions: 2, tokens: 1_000, depth: 2]
                  }

                n ->
                  F.record(tag, n)
              end)
          )

        {:ok, snapshot} = Episode.snapshot(parent)
        {result, snapshot}
      end)

    child = result.routes |> Enum.map(&Map.get(&1, :child)) |> Enum.find(& &1)

    Result.positive(f,
      attempt_observed?: F.seen?(ctx, f, "episode.start"),
      expected_outcome_observed?:
        result.outcome == :completed and result.committed == 3 and
          match?(%Episode.Result{outcome: :completed, committed: 2}, child) and
          length(F.rows(tag)) == 2 and length(F.rows(tag <> "-child")) == 2 and
          snapshot.executions.remaining == 0 and snapshot.spend.consumed.tokens == 1_000,
      evidence:
        result
        |> evidence(F.rows(tag))
        |> Map.merge(%{
          "child" => child && "#{child.outcome}:#{child.committed}",
          "parent_executions" => snapshot.executions,
          "parent_tokens_consumed" => snapshot.spend.consumed.tokens
        })
    )
  end

  # B4 ----------------------------------------------------------------------------------

  defp execute("SA2A-BOUNDS-020", f, ctx, env, _projection) do
    if File.exists?(HddlSolver.cli_path()) do
      tag = tag(env, f)
      {ir, ontology} = F.admitted()

      {planned, result, envelope} =
        Context.stimulus(ctx, f, fn ->
          plans =
            for _ <- 1..3 do
              {:ok, planned} =
                Episode.plan(ir, ontology, F.domain_hddl(), F.problem_hddl(),
                  package: F.package_opts()
                )

              planned
            end

          planned = List.last(plans)
          envelope = F.envelope!()

          result =
            F.run!(planned.package, envelope, env,
              bind: fn "htn:exec:" <> exec ->
                {:ok,
                 %{
                   capability_id: F.record_capability(),
                   input: %{"episode_tag" => tag, "label" => exec}
                 }}
              end
            )

          {planned, result, envelope}
        end)

      b4(f, ctx, planned, result, envelope)
    else
      Result.blocked(f, "real hddl_cli not built at #{HddlSolver.cli_path()}")
    end
  end

  # Every spend-like attack: a 4-transition plan whose envelope admits 2.
  defp spend(f, ctx, env, projection, attack) do
    %{resource: resource, envelope: envelope, builder: builder, cost: cost} = attack
    {planned, admitted} = {4, 2}
    opts = [cost: cost]
    tag = tag(env, f)
    package = F.static_package!(projection, planned)

    {result, snapshot} =
      Context.stimulus(ctx, f, fn ->
        envelope = F.envelope!(envelope)
        result = F.run!(package, envelope, env, bind: F.bind(&builder.(tag, &1, opts)))
        {:ok, snapshot} = Episode.snapshot(envelope)
        {result, snapshot}
      end)

    rows = F.rows(tag)

    within =
      snapshot.executions.consumed <= snapshot.executions.limit and
        Enum.all?(snapshot.spend.consumed, fn {dim, used} ->
          used <= Map.fetch!(snapshot.spend.limits, dim)
        end)

    Result.negative(f,
      attempt_observed?:
        F.seen?(ctx, f, "episode.start", %{"plan_size" => "#{planned}"}) and
          F.count(ctx, f, "brce.commit") >= admitted,
      forbidden_outcome_observed?:
        F.count(ctx, f, "brce.actuate.start") > admitted or length(rows) > admitted or
          not within or {result.outcome, result.resource} != {:resource_exhausted, resource},
      evidence:
        result
        |> evidence(rows)
        |> Map.merge(%{"executions" => snapshot.executions, "spend" => snapshot.spend})
    )
  end

  defp b4(f, ctx, planned, result, envelope) do
    records = Context.observed(ctx, f)
    planning = Enum.filter(records, &(&1.activity == "episode.planning"))
    phase = fn name -> Enum.filter(planning, &(&1.attributes["phase"] == name)) end

    durations = fn rs ->
      rs |> Enum.map(& &1.attributes["duration_us"]) |> Enum.filter(&is_integer/1)
    end

    stops = Enum.filter(records, &(&1.activity == "episode.transition.stop"))
    admission = Enum.find(records, &(&1.activity == "episode.admission"))
    package_record = phase.("package_admission") |> List.last()
    planner_record = phase.("planner") |> List.last()

    actuations =
      records |> Enum.filter(&(&1.activity == "brce.actuate.start")) |> Enum.map(& &1.seq)

    {:ok, snapshot} = Episode.snapshot(envelope)
    attr = fn record, key -> record && record.attributes[key] end

    measurements = %{
      "planning_projection_us" => F.stats(durations.(phase.("projection"))),
      "planner_invocation_us" => F.stats(durations.(phase.("planner"))),
      "plan_admission_us" => F.stats(durations.(phase.("package_admission"))),
      "episode_admission_us" => F.stats(durations.([admission] |> Enum.reject(&is_nil/1))),
      "plan_size" => attr.(package_record, "plan_size"),
      "planner_plan_size" => attr.(planner_record, "plan_size"),
      "planner_methods" => attr.(planner_record, "methods"),
      "plan_bounds" => %{
        "max_fan_out" => attr.(package_record, "max_fan_out"),
        "max_depth" => attr.(package_record, "max_depth"),
        "max_parallelism" => attr.(package_record, "max_parallelism")
      },
      "plan_resource_envelope" => %{
        "max_wall_ms" => attr.(package_record, "max_wall_ms"),
        "max_memory_bytes" => attr.(package_record, "max_memory_bytes"),
        "max_invocations" => attr.(package_record, "max_invocations")
      },
      "effective_bounds" => %{
        "depth" => attr.(admission, "depth_ceiling"),
        "fan_out" => attr.(admission, "fan_out_ceiling"),
        "parallelism" => attr.(admission, "parallelism_ceiling"),
        "executions" => attr.(admission, "executions_ceiling"),
        "memory_bytes" => attr.(admission, "memory_ceiling"),
        "wall_ms" => attr.(admission, "wall_ceiling_ms")
      },
      "host_envelope" => %{"executions" => snapshot.executions, "spend" => snapshot.spend},
      "authority_decision_us" =>
        F.stats(stops |> Enum.map(& &1.attributes["authority_us"]) |> Enum.filter(&is_integer/1)),
      "do_us" =>
        F.stats(stops |> Enum.map(& &1.attributes["do_us"]) |> Enum.filter(&is_integer/1)),
      "episode_outcome" => "#{result.outcome}:#{result.committed}",
      "planning_events_carry_command" =>
        Enum.any?(planning, fn r -> F.object(r, "command") != nil end),
      "planning_precedes_first_actuation" =>
        planning != [] and actuations != [] and
          Enum.max(Enum.map(planning, & &1.seq)) < Enum.min(actuations),
      "plan_digest" => planned.package.plan_digest,
      "environment" => environment()
    }

    Result.measured(f,
      attempt_observed?:
        length(phase.("planner")) >= 3 and length(phase.("projection")) >= 3 and
          length(phase.("package_admission")) >= 3 and result.outcome == :completed,
      measurements: measurements
    )
  end

  defp environment do
    cli = HddlSolver.cli_path()

    %{
      "otp_release" => to_string(:erlang.system_info(:otp_release)),
      "elixir" => System.version(),
      "erts" => to_string(:erlang.system_info(:version)),
      "system_architecture" => to_string(:erlang.system_info(:system_architecture)),
      "schedulers_online" => :erlang.system_info(:schedulers_online),
      "logical_processors" => :erlang.system_info(:logical_processors_available),
      "os" => :os.type() |> Tuple.to_list() |> Enum.map_join("/", &to_string/1),
      "planner" => "hddl_cli",
      "planner_binary_bytes" =>
        case File.stat(cli) do
          {:ok, %{size: size}} -> size
          _ -> nil
        end
    }
  end

  defp evidence(%Episode.Result{} = r, rows) do
    %{
      "episode_outcome" => r.outcome,
      "episode_code" => r.code,
      "episode_resource" => r.resource,
      "stages_total" => r.stages_total,
      "stages_run" => r.stages_run,
      "committed" => r.committed,
      "executions_used" => r.executions_used,
      "step_rows" => length(rows)
    }
  end

  defp refusal_code({:ok, %Envelope{}}), do: "admitted"
  defp refusal_code({:error, %{code: code}}), do: Atom.to_string(code)
  defp refusal_code(other), do: inspect(other, limit: 5)

  defp tag(env, %Falsifier{id: id}), do: "#{String.downcase(id)}-#{env.nonce}"
end
