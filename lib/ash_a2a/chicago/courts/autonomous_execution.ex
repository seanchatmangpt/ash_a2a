defmodule AshA2A.Chicago.Courts.AutonomousExecution do
  @moduledoc """
  RFC-SA2A-002 §37 Gate 6 -- Autonomous Execution Inside Envelope, with §133
  Production Boundedness, court id `CHI-AUTO`.

      AdmittedBoundedEpisode ⇒ ◇ LawfulTerminal ∧ Consumed ≤ Envelope
      KnownWork ∧ Control ≡ "reason until complete" ⇒ REFUSED

  The court drives `AshA2A.Semantic.Episode` -- the real bounded episode
  executor -- with plans admitted as strict `AshA2A.Semantic.PlanPackage`s
  (one planned by the real `hddl_cli` over really admitted semantics), and
  requires each episode to reach a lawful terminal condition in one call:
  successful completion and quiescence as positive controls (§100), explicit
  refusal, envelope exhaustion and bounded-depth termination as attacks.

  Every consequence goes through the real `AshA2A.CommandBus` under a real
  authority broker; post-state is read back through `Ash.read!/1`.
  """

  use AshA2A.Chicago.Court

  alias AshA2A.Chicago.{Context, Falsifier, Result}
  alias AshA2A.Chicago.Fixtures.AutonomyBounds, as: F
  alias AshA2A.Planning.HddlSolver
  alias AshA2A.Semantic.Episode

  @court "CHI-AUTO"

  @impl true
  def id, do: @court
  @impl true
  def title, do: "Autonomous execution inside an admitted envelope; production boundedness"
  @impl true
  def gate, do: 6
  @impl true
  def profile, do: :do
  @impl true
  def rfc_sections, do: ["§37", "§100", "§133"]

  @impl true
  def ocel_mappings, do: F.mappings()

  @impl true
  def falsifiers do
    [
      Falsifier.new!(
        id: "#{@court}-001",
        court_id: @court,
        kind: :positive_control,
        invariant:
          "An admitted bounded plan with more than one internal transition runs to successful completion in one executor call, without caller-by-caller reinterpretation",
        stimulus:
          "real Admission -> projection -> real hddl_cli plan (5 htn:exec actions) -> strict PlanPackage; ONE Episode.run over a host envelope, granted principal",
        boundary: "AshA2A.Semantic.Episode.run/3 stage loop over AshA2A.CommandBus",
        attempt_evidence: "episode.planning planner ok and episode.start",
        survival_evidence:
          "one episode.start; episode.stop completed with 5 committed; 5 brce.commit; 5 Step rows with the planned labels",
        rfc_sections: ["§37", "§100"],
        attempt_predicate:
          {:all,
           [
             {:observed, "episode.planning", %{"phase" => "planner", "outcome" => "ok"}},
             {:observed, "episode.start"}
           ]},
        outcome_predicate:
          {:all,
           [
             {:count, "episode.start", :eq, 1},
             {:observed, "episode.stop", %{"outcome" => "completed", "committed" => "5"}},
             {:count, "brce.commit", :eq, 5},
             {:count, "episode.transition.stop", :eq, 5},
             {:precedes, "episode.admission", "brce.actuate.start"}
           ]}
      ),
      negative("002",
        invariant:
          "§133: a known production operation whose control contract is 'continue reasoning until complete' is refused before any transition",
        stimulus:
          "four episodes over an admitted strict plan whose control is :until_believed_complete, a prose termination, max_steps :infinity, and a string-keyed map %{\"termination\" => \"until_done\"}",
        boundary: "Episode admission -> BoundedProduction.contract/2",
        forbidden_outcome: "any admitted episode, transition start, actuation or Step row",
        attempt_evidence: "four episode.admission decisions (any outcome)",
        survival_evidence:
          "episode.admission admitted, episode.transition.start, brce.actuate.start, rows",
        guard:
          "Episode.control_contract/2 (BoundedProduction.contract/2 + control normalization)",
        failure_class: :bound_failure,
        rfc_sections: ["§133"],
        attempt_predicate: {:count, "episode.admission", :gte, 4},
        outcome_predicate:
          {:any,
           [
             {:observed, "episode.admission", %{"outcome" => "admitted"}},
             {:observed, "episode.transition.start"},
             {:observed, "brce.actuate.start"}
           ]}
      ),
      negative("003",
        invariant:
          "An episode cannot exceed the admitted envelope its own plan package declares: max_invocations 3 on a 6-transition plan stops at 3",
        stimulus:
          "strict package with resource_envelope.max_invocations 3 and 6 record transitions; generous host envelope",
        boundary: "Episode stage guard on the package envelope (plan_invocations)",
        forbidden_outcome:
          "a 4th actuation, or any terminal other than resource_exhausted(plan_invocations)",
        attempt_evidence: "episode.start plan_size 6 and >= 3 committed transitions",
        survival_evidence:
          "brce.actuate.start >= 4; episode.stop not resource_exhausted; > 3 rows",
        guard: "Episode.executions_guard/3 against min(envelope, package) invocations",
        failure_class: :bound_failure,
        rfc_sections: ["§37"],
        attempt_predicate:
          {:all,
           [
             {:observed, "episode.start", %{"plan_size" => "6"}},
             {:count, "brce.commit", :gte, 3}
           ]},
        outcome_predicate:
          {:any,
           [
             {:count, "brce.actuate.start", :gte, 4},
             {:not_observed, "episode.stop",
              %{"outcome" => "resource_exhausted", "resource" => "plan_invocations"}}
           ]}
      ),
      negative("004",
        invariant:
          "Explicit refusal is a lawful terminal condition: a refused transition ends the episode instead of being skipped or reinterpreted",
        stimulus:
          "3-stage plan record -> call_external -> record for a principal granted only record_step",
        boundary: "Episode.run_transitions/4 halt on a refused CommandBus route",
        forbidden_outcome:
          "the third transition actuating, or a terminal other than refused(authority_required)",
        attempt_evidence: "episode.start and brce.admission refused authority_required",
        survival_evidence: "brce.actuate.start >= 2; episode.stop not refused; 2 rows",
        guard: "Episode.run_transitions/4 `refused != []` terminal",
        failure_class: :authority_failure,
        rfc_sections: ["§37", "§131"],
        attempt_predicate:
          {:all,
           [
             {:observed, "episode.start"},
             {:observed, "brce.admission",
              %{"outcome" => "refused", "code" => "authority_required"}}
           ]},
        outcome_predicate:
          {:any,
           [
             {:count, "brce.actuate.start", :gte, 2},
             {:not_observed, "episode.stop",
              %{"outcome" => "refused", "code" => "authority_required"}}
           ]}
      ),
      negative("005",
        invariant:
          "Bounded-depth termination: a control contract of max_steps 2 over a 5-stage plan whose predicate never holds halts after exactly 2 stages",
        stimulus: "5 record stages, termination fn _ -> false end, max_steps 2",
        boundary: "BoundedProduction.run/3 max_steps inside the episode loop",
        forbidden_outcome: "a 3rd actuation or a terminal other than bound_reached(max_steps)",
        attempt_evidence: "episode.admission admitted with contract_max_steps 2 and >= 2 commits",
        survival_evidence: "brce.actuate.start >= 3; no bound_reached stop; > 2 rows",
        guard: "BoundedProduction.run/3 `steps >= max_steps`",
        failure_class: :bound_failure,
        rfc_sections: ["§37", "§133"],
        attempt_predicate:
          {:all,
           [
             {:observed, "episode.admission",
              %{"outcome" => "admitted", "contract_max_steps" => "2"}},
             {:count, "brce.commit", :gte, 2}
           ]},
        outcome_predicate:
          {:any,
           [
             {:count, "brce.actuate.start", :gte, 3},
             {:not_observed, "episode.stop",
              %{"outcome" => "bound_reached", "resource" => "max_steps"}}
           ]}
      ),
      Falsifier.new!(
        id: "#{@court}-006",
        court_id: @court,
        kind: :positive_control,
        invariant:
          "Quiescence (§100 discrimination for 005): a real termination predicate over independent post-state ends a 4-stage episode after 2 stages, not by a bound",
        stimulus:
          "4 record stages; termination = two Step rows exist for the episode tag (read via Ash.read!)",
        boundary: "Episode loop termination predicate",
        attempt_evidence: "episode.start",
        survival_evidence:
          "episode.stop quiescent with 2 committed, 2 brce.commit, no refused bound",
        rfc_sections: ["§37", "§100"],
        attempt_predicate: {:observed, "episode.start"},
        outcome_predicate:
          {:all,
           [
             {:observed, "episode.stop", %{"outcome" => "quiescent", "committed" => "2"}},
             {:count, "brce.commit", :eq, 2},
             {:not_observed, "episode.bound", %{"outcome" => "refused"}}
           ]}
      )
    ]
  end

  defp negative(suffix, fields) do
    Falsifier.new!([id: "#{@court}-#{suffix}", court_id: @court, kind: :negative] ++ fields)
  end

  # --- execution --------------------------------------------------------------------

  @impl true
  def run(%Context{} = ctx) do
    F.with_env(fn env ->
      projection = F.projection()

      Enum.map(falsifiers(), fn f ->
        F.guarded(f, fn -> execute(f.id, f, ctx, env, projection) end)
      end)
    end)
  end

  defp execute("CHI-AUTO-001", f, ctx, env, _projection) do
    if File.exists?(HddlSolver.cli_path()) do
      tag = tag(env, f)
      {ir, ontology} = F.admitted()

      {planned, result} =
        Context.stimulus(ctx, f, fn ->
          {:ok, planned} =
            Episode.plan(ir, ontology, F.domain_hddl(), F.problem_hddl(),
              package: F.package_opts()
            )

          result =
            F.run!(planned.package, F.envelope!(), env,
              bind: fn "htn:exec:" <> exec ->
                label = exec |> String.split(":") |> List.last()

                {:ok,
                 %{
                   capability_id: F.record_capability(),
                   input: %{"episode_tag" => tag, "label" => label}
                 }}
              end
            )

          {planned, result}
        end)

      planned_labels =
        Enum.map(planned.package.action_identities, &(&1 |> String.split(":") |> List.last()))

      rows = F.labels(tag)
      {:ok, snapshot} = Episode.snapshot(result.envelope_id)

      Result.positive(f,
        attempt_observed?:
          F.seen?(ctx, f, "episode.planning", %{"phase" => "planner", "outcome" => "ok"}) and
            F.seen?(ctx, f, "episode.start"),
        expected_outcome_observed?:
          result.outcome == :completed and result.committed == 5 and
            length(planned_labels) == 5 and rows == Enum.sort(planned_labels) and
            F.count(ctx, f, "episode.start") == 1 and F.count(ctx, f, "brce.commit") == 5 and
            snapshot.executions.consumed == 5,
        evidence:
          f
          |> evidence(result, rows)
          |> Map.merge(%{
            "planned_actions" => planned.package.action_identities,
            "plan_digest" => planned.package.plan_digest,
            "planner_identity" => planned.package.planner_identity,
            "envelope_executions" => snapshot.executions
          })
      )
    else
      Result.blocked(f, "real hddl_cli not built at #{HddlSolver.cli_path()}")
    end
  end

  defp execute("CHI-AUTO-002", f, ctx, env, projection) do
    tag = tag(env, f)
    package = F.static_package!(projection, 2)
    bind = F.bind(&F.record(tag, &1))
    prose = "continue reasoning until you believe the task is complete"

    controls = [
      [termination: :until_believed_complete, max_steps: 8, max_wall_time_ms: 5_000],
      [termination: prose, max_steps: 8, max_wall_time_ms: 5_000],
      [termination: fn _ -> false end, max_steps: :infinity, max_wall_time_ms: 5_000],
      %{"termination" => "until_done", "max_steps" => 8, "max_wall_time_ms" => 5_000}
    ]

    results =
      Context.stimulus(ctx, f, fn ->
        for control <- controls,
            do: F.run!(package, F.envelope!(), env, bind: bind, control: control)
      end)

    rows = F.rows(tag)

    Result.negative(f,
      attempt_observed?: F.count(ctx, f, "episode.admission") >= 4,
      forbidden_outcome_observed?:
        F.seen?(ctx, f, "episode.admission", %{"outcome" => "admitted"}) or
          F.seen?(ctx, f, "brce.actuate.start") or rows != [] or
          Enum.any?(results, &(&1.code != :unbounded_production_operation)),
      evidence: %{
        "outcomes" => Enum.map(results, &"#{&1.outcome}:#{&1.code}"),
        "committed" => Enum.map(results, & &1.committed),
        "step_rows" => length(rows)
      }
    )
  end

  defp execute("CHI-AUTO-003", f, ctx, env, projection) do
    tag = tag(env, f)

    package =
      F.static_package!(projection, 6,
        resource_envelope: %{
          max_wall_ms: 60_000,
          max_memory_bytes: 1_000_000_000,
          max_invocations: 3
        }
      )

    result =
      Context.stimulus(ctx, f, fn ->
        F.run!(package, F.envelope!(), env, bind: F.bind(&F.record(tag, &1)))
      end)

    rows = F.rows(tag)

    Result.negative(f,
      attempt_observed?:
        F.seen?(ctx, f, "episode.start", %{"plan_size" => "6"}) and
          F.count(ctx, f, "brce.commit") >= 3,
      forbidden_outcome_observed?:
        F.count(ctx, f, "brce.actuate.start") > 3 or length(rows) > 3 or
          result.executions_used > 3 or
          {result.outcome, result.resource} != {:resource_exhausted, :plan_invocations},
      evidence: evidence(f, result, F.labels(tag))
    )
  end

  defp execute("CHI-AUTO-004", f, ctx, env, projection) do
    tag = tag(env, f)
    package = F.static_package!(projection, 3)

    bind =
      F.bind(fn
        2 -> F.external(tag, 2)
        n -> F.record(tag, n)
      end)

    result =
      Context.stimulus(ctx, f, fn ->
        F.run!(package, F.envelope!(), env, bind: bind, principal: env.limited)
      end)

    rows = F.rows(tag)

    Result.negative(f,
      attempt_observed?:
        F.seen?(ctx, f, "episode.start") and
          F.seen?(ctx, f, "brce.admission", %{
            "outcome" => "refused",
            "code" => "authority_required"
          }),
      forbidden_outcome_observed?:
        F.count(ctx, f, "brce.actuate.start") >= 2 or length(rows) > 1 or
          {result.outcome, result.code} != {:refused, :authority_required},
      evidence: evidence(f, result, F.labels(tag))
    )
  end

  defp execute("CHI-AUTO-005", f, ctx, env, projection) do
    tag = tag(env, f)
    package = F.static_package!(projection, 5)

    result =
      Context.stimulus(ctx, f, fn ->
        F.run!(package, F.envelope!(), env,
          bind: F.bind(&F.record(tag, &1)),
          control: F.control(max_steps: 2)
        )
      end)

    rows = F.rows(tag)

    Result.negative(f,
      attempt_observed?:
        F.seen?(ctx, f, "episode.admission", %{
          "outcome" => "admitted",
          "contract_max_steps" => "2"
        }) and F.count(ctx, f, "brce.commit") >= 2,
      forbidden_outcome_observed?:
        F.count(ctx, f, "brce.actuate.start") >= 3 or length(rows) > 2 or
          {result.outcome, result.resource} != {:bound_reached, :max_steps},
      evidence: evidence(f, result, F.labels(tag))
    )
  end

  defp execute("CHI-AUTO-006", f, ctx, env, projection) do
    tag = tag(env, f)
    package = F.static_package!(projection, 4)

    result =
      Context.stimulus(ctx, f, fn ->
        F.run!(package, F.envelope!(), env,
          bind: F.bind(&F.record(tag, &1)),
          control: F.control(termination: fn _view -> length(F.rows(tag)) >= 2 end)
        )
      end)

    rows = F.rows(tag)

    Result.positive(f,
      attempt_observed?: F.seen?(ctx, f, "episode.start"),
      expected_outcome_observed?:
        result.outcome == :quiescent and result.committed == 2 and length(rows) == 2 and
          F.count(ctx, f, "brce.commit") == 2 and
          not F.seen?(ctx, f, "episode.bound", %{"outcome" => "refused"}),
      evidence: evidence(f, result, F.labels(tag))
    )
  end

  defp evidence(_f, %Episode.Result{} = r, rows) do
    %{
      "episode_outcome" => r.outcome,
      "episode_code" => r.code,
      "episode_resource" => r.resource,
      "stages_total" => r.stages_total,
      "stages_run" => r.stages_run,
      "committed" => r.committed,
      "executions_used" => r.executions_used,
      "step_rows" => rows
    }
  end

  defp tag(env, %Falsifier{id: id}), do: "#{String.downcase(id)}-#{env.nonce}"
end
