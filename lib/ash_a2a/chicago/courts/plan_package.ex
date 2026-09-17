defmodule AshA2A.Chicago.Courts.PlanPackage do
  @moduledoc """
  `SA2A-PLAN` -- Plan Package Court and Planner Non-Authority Court
  (RFC-SA2A-002 §58, §59, §28; RFC-SA2A-001 S24).

  ## §58: identity and bounds, fail closed under Strict

  Falsifiers 001-013 each withhold one §58 required identity or production
  bound from a real `AshA2A.Semantic.PlanPackage.from_projection/3` call under
  `profile: :strict` over a really-admitted projection; the package boundary
  must refuse (no `plan.package` built). 014 presents a package whose
  `plan_digest` no longer matches its content to the real SELECT and
  PREFLIGHT boundaries. 015 is the §100 control: the complete package builds.

  | falsifier | §58 field withheld |
  |---|---|
  | 001 | semantic goal (projection with no goal) |
  | 002 | initial admitted state identity |
  | 003 | planning-domain identity |
  | 004 | action/method identities |
  | 005 | preconditions/effects |
  | 006 | nondeterministic outcomes (undeclared) |
  | 007 | consequence class |
  | 008 | required capabilities |
  | 009 | fan-out/depth/parallelism |
  | 010 | resource envelope |
  | 011 | authority requirements |
  | 012 | receipt obligations |
  | 013 | planner identity |
  | 014 | plan digest (content no longer matches) |

  ## §59: a valid, admitted, feasible, optimal plan is not authority

  016 manufactures a plan that is syntactically valid (strict package that
  verifies), semantically admitted (projection from the real
  `AshA2A.Semantic.Admission`), feasible under the planning model (the real
  `native/hddl_cli` solver confirms the step sequence reaches the goal via
  `AshA2A.Planning.HddlDeterministicSynthesis`), optimal (lowest-cost SELECT),
  CONSTRUCTED and preflighted -- then the planner identity submits its steps
  to the real `AshA2A.CommandBus` carrying the plan's own authority-requirement
  statement and feasibility fingerprint, with no authority. 017 is the control: the same feasible plan
  executes when real authority is presented.
  """

  use AshA2A.Chicago.Court

  alias AshA2A.{CommandBus, Identity}
  alias AshA2A.Chicago.{Context, Falsifier, Result}
  alias AshA2A.Chicago.Fixtures.Brce.Planned
  alias AshA2A.Chicago.Fixtures.PlanGates, as: Fx
  alias AshA2A.Planning.{HddlDeterministicSynthesis, Preflight}
  alias AshA2A.Semantic.{CanonicalTermDigest, PlanProjection, Select}
  alias AshA2A.Semantic.PlanPackage, as: Package

  @court "SA2A-PLAN"

  @withheld [
    {1, "semantic goal", :semantic_goal},
    {2, "initial admitted state identity", :initial_state_identity},
    {3, "planning-domain identity", :planning_domain_identity},
    {4, "action/method identities", :action_method_identities},
    {5, "preconditions/effects", :preconditions_effects},
    {6, "nondeterministic outcomes", :nondeterministic_outcomes},
    {7, "consequence class", :consequence_class},
    {8, "required capabilities", :required_capabilities},
    {9, "fan-out/depth/parallelism", :fan_out_depth_parallelism},
    {10, "resource envelope", :resource_envelope},
    {11, "authority requirements", :authority_requirements},
    {12, "receipt obligations", :receipt_obligations},
    {13, "planner identity", :planner_identity}
  ]

  @section58 [
    :semantic_goal,
    :initial_state_identity,
    :planning_domain_identity,
    :method_identities,
    :action_identities,
    :preconditions,
    :effects,
    :nondeterministic_outcomes,
    :consequence_class,
    :required_capabilities,
    :max_fan_out,
    :max_depth,
    :max_parallelism,
    :resource_envelope,
    :authority_requirements,
    :receipt_obligations,
    :planner_identity,
    :plan_digest
  ]

  @reached_boundary {:observed, "brce.target", %{"outcome" => "resolved"}}

  @feasible_plan [
    {:observed, "plan.package", %{"outcome" => "built", "profile" => "strict"}},
    {:observed, "planning.admit", %{"outcome" => "admitted", "planner" => "hddl_solver"}},
    {:observed, "plan.select", %{"outcome" => "selected"}},
    {:observed, "plan.construct", %{"outcome" => "constructed"}},
    {:observed, "plan.preflight", %{"outcome" => "preflighted"}}
  ]

  @impl true
  def id, do: @court
  @impl true
  def title, do: "Plan package identity and bounds; planner non-authority"
  @impl true
  def gate, do: nil
  @impl true
  def profile, do: :plan
  @impl true
  def rfc_sections, do: ["§28", "§58", "§59", "§100"]

  @impl true
  def ocel_mappings, do: Fx.mappings()

  # --- falsifier declarations (§11) -----------------------------------------

  @impl true
  def falsifiers do
    withheld =
      for {n, label, _key} <- @withheld do
        negative(n,
          invariant: "§58: a Strict plan package missing its #{label} is refused",
          stimulus:
            "PlanPackage.from_projection/3 under profile: :strict over the really-admitted projection with #{label} withheld",
          boundary: "AshA2A.Semantic.PlanPackage.from_projection/3 (enforce_profile/1)",
          forbidden_outcome: "a Strict plan package built without #{label}",
          attempt_evidence: "plan.package decided with profile=strict for this stimulus",
          survival_evidence: "plan.package outcome=built attributed to the stimulus",
          guard: "PlanPackage strict-profile refusal of a package missing #{label}",
          failure_class: :planning_failure,
          attempt_predicate: {:observed, "plan.package", %{"profile" => "strict"}},
          outcome_predicate: {:observed, "plan.package", %{"outcome" => "built"}}
        )
      end

    withheld ++
      [
        negative(14,
          invariant:
            "§58: a plan package whose plan_digest does not identify its content is neither selected nor preflighted",
          stimulus:
            "a strict package's plan_digest replaced after manufacture, presented to Select.select/3 and (inside its bounded plan) Preflight.preflight/1",
          boundary: "AshA2A.Semantic.Select / AshA2A.Planning.Preflight (PlanPackage.verify/1)",
          forbidden_outcome:
            "plan.select selected or plan.preflight preflighted for the tampered package",
          attempt_evidence: "plan.select and plan.preflight decided for this stimulus",
          survival_evidence:
            "plan.select selected / plan.preflight preflighted attributed to the stimulus",
          guard: "PlanPackage.verify/1 in Select.verify_all/1 and Preflight.package/1",
          failure_class: :planning_failure,
          attempt_predicate: {:all, [{:observed, "plan.select"}, {:observed, "plan.preflight"}]},
          outcome_predicate:
            {:any,
             [
               {:observed, "plan.select", %{"outcome" => "selected"}},
               {:observed, "plan.preflight", %{"outcome" => "preflighted"}}
             ]}
        ),
        positive(15,
          invariant:
            "§100 a complete Strict package carrying every §58 identity and bound is built (control for 001-014)",
          stimulus: "PlanPackage.from_projection/3 under profile: :strict with every §58 field",
          boundary: "AshA2A.Semantic.PlanPackage.from_projection/3",
          attempt_evidence: "plan.package decided with profile=strict",
          survival_evidence:
            "plan.package outcome=built; PlanPackage.verify/1 ok; every §58 field present",
          attempt_predicate: {:observed, "plan.package", %{"profile" => "strict"}},
          outcome_predicate:
            {:observed, "plan.package", %{"outcome" => "built", "profile" => "strict"}}
        ),
        negative(16,
          invariant:
            "§59: a syntactically valid, admitted, feasible, optimal plan does not reach DO without authority",
          stimulus:
            "real hddl_cli feasibility (HddlDeterministicSynthesis.synthesize/3), strict package, lowest-cost SELECT, CONSTRUCT, preflight; the planner identity runs every step carrying the plan's authority_requirements statement and feasibility fingerprint, with no authority",
          boundary: "AshA2A.CommandBus admission (admit/2)",
          forbidden_outcome: "any actuation of the planned steps; advance/unlock rows written",
          attempt_evidence:
            "plan.package built, planning.admit admitted by hddl_solver, plan.select selected, plan.construct constructed, plan.preflight preflighted, brce.target resolved",
          survival_evidence:
            "brce.actuate.start / dispatch.actuate attributed to the stimulus; token rows visible to Ash.read!",
          guard:
            "CommandBus.admit/2 accepts only a real %AshA2A.Authority{} admitting the command",
          failure_class: :authority_failure,
          attempt_predicate: {:all, @feasible_plan ++ [@reached_boundary]},
          outcome_predicate: Fx.actuation_predicate()
        ),
        positive(17,
          invariant:
            "§100 the same feasible plan executes when real authority is presented (control for 016)",
          stimulus:
            "the §59 pipeline, then every step run by the requesting principal with a real AshA2A.Authority",
          boundary: "AshA2A.CommandBus preflight + admission + BRCE",
          attempt_evidence: "the §59 pipeline observed and brce.target resolved",
          survival_evidence:
            "brce.admission admitted; prepare ≺ actuate ≺ commit; both token rows visible",
          attempt_predicate: {:all, @feasible_plan ++ [@reached_boundary]},
          outcome_predicate:
            {:all,
             [
               {:observed, "brce.admission", %{"outcome" => "admitted"}},
               Fx.receipted_do_predicate()
             ]}
        )
      ]
  end

  defp negative(n, fields), do: declare(n, :negative, fields)
  defp positive(n, fields), do: declare(n, :positive_control, fields)

  defp declare(n, kind, fields) do
    Falsifier.new!(
      [id: falsifier_id(n), court_id: @court, kind: kind, rfc_sections: ["§58", "§59"]] ++
        fields
    )
  end

  defp falsifier_id(n), do: @court <> "-" <> String.pad_leading(Integer.to_string(n), 3, "0")

  # --- execution ---------------------------------------------------------------

  @impl true
  def run(%Context{} = ctx) do
    f = Map.new(falsifiers(), &{&1.id, &1})
    get = fn n -> Map.fetch!(f, falsifier_id(n)) end
    {projection, _ontology} = Fx.projection()

    (Enum.map(@withheld, fn {n, _label, key} -> {n, &withheld(ctx, &1, projection, key)} end) ++
       [
         {14, &tampered_digest(ctx, &1)},
         {15, &complete_package(ctx, &1, projection)},
         {16, &planner_non_authority(ctx, &1, :negative)},
         {17, &planner_non_authority(ctx, &1, :positive)}
       ])
    |> Enum.map(fn {n, fun} -> Fx.fenced(ctx, get.(n), fn -> fun.(get.(n)) end) end)
  end

  # 001-013
  defp withheld(ctx, falsifier, projection, key) do
    token = Fx.token()
    result = Context.stimulus(ctx, falsifier, fn -> build_withheld(projection, token, key) end)

    Result.negative(falsifier,
      attempt_observed?: Fx.observed?(ctx, falsifier, "plan.package", %{"profile" => "strict"}),
      forbidden_outcome_observed?:
        match?({:ok, _}, result) or
          Fx.observed?(ctx, falsifier, "plan.package", %{"outcome" => "built"}),
      evidence: %{
        "withheld" => Atom.to_string(key),
        "reply_code" => Fx.reply_code(result),
        "fields" => Fx.attr_values(ctx, falsifier, "plan.package", "fields")
      }
    )
  end

  defp build_withheld(projection, token, key) do
    planner = Fx.planner_identity()

    case key do
      :semantic_goal ->
        Package.from_projection(forge(projection, goals: []), planner, Fx.package_opts(token))

      :initial_state_identity ->
        Package.from_projection(
          forge(projection, planning_ir_fingerprint: ""),
          planner,
          Fx.package_opts(token)
        )

      :planning_domain_identity ->
        Fx.package(projection, token, planning_domain_identity: nil)

      :action_method_identities ->
        Fx.package(projection, token, action_identities: [], method_identities: [])

      :preconditions_effects ->
        Fx.package(projection, token, preconditions: [], effects: [])

      :nondeterministic_outcomes ->
        opts = token |> Fx.package_opts() |> Keyword.delete(:nondeterministic_outcomes)
        Package.from_projection(projection, planner, opts)

      :consequence_class ->
        Fx.package(projection, token, consequence_class: nil)

      :required_capabilities ->
        Fx.package(projection, token, required_capabilities: [])

      :fan_out_depth_parallelism ->
        Fx.package(projection, token, max_fan_out: nil, max_depth: nil, max_parallelism: nil)

      :resource_envelope ->
        Fx.package(projection, token, resource_envelope: nil)

      :authority_requirements ->
        Fx.package(projection, token, authority_requirements: [])

      :receipt_obligations ->
        Fx.package(projection, token, receipt_obligations: [])

      :planner_identity ->
        Package.from_projection(projection, "", Fx.package_opts(token))
    end
  end

  # A projection edited and re-digested so its own S27 tamper check passes:
  # only the package boundary's §58 check can refuse what it lacks.
  defp forge(projection, changes) do
    edited = struct!(projection, changes)
    %{edited | projection_digest: PlanProjection.content_digest(edited)}
  end

  # 014
  defp tampered_digest(ctx, falsifier) do
    planned = Fx.planned()

    tampered = %{
      planned.package
      | plan_digest: CanonicalTermDigest.digest({:tampered, Fx.token()})
    }

    {selected, preflighted} =
      Context.stimulus(ctx, falsifier, fn ->
        {Select.select([tampered], & &1.max_fan_out, profile: :strict),
         Preflight.preflight(%{planned.plan | plan_package: tampered})}
      end)

    Result.negative(falsifier,
      attempt_observed?:
        Fx.observed?(ctx, falsifier, "plan.select") and
          Fx.observed?(ctx, falsifier, "plan.preflight"),
      forbidden_outcome_observed?:
        match?({:ok, _}, selected) or match?({:ok, _}, preflighted) or
          Fx.observed?(ctx, falsifier, "plan.select", %{"outcome" => "selected"}) or
          Fx.observed?(ctx, falsifier, "plan.preflight", %{"outcome" => "preflighted"}),
      evidence: %{
        "select" => Fx.reply_code(selected),
        "preflight" => Fx.reply_code(preflighted)
      }
    )
  end

  # 015
  defp complete_package(ctx, falsifier, projection) do
    token = Fx.token()
    result = Context.stimulus(ctx, falsifier, fn -> Fx.package(projection, token) end)

    {complete?, absent} =
      case result do
        {:ok, package} ->
          absent = Enum.filter(@section58, &blank?(Map.fetch!(package, &1)))
          {match?({:ok, _}, Package.verify(package)) and absent == [], absent}

        _ ->
          {false, @section58}
      end

    Result.positive(falsifier,
      attempt_observed?: Fx.observed?(ctx, falsifier, "plan.package", %{"profile" => "strict"}),
      expected_outcome_observed?:
        complete? and
          Fx.observed?(ctx, falsifier, "plan.package", %{
            "outcome" => "built",
            "profile" => "strict"
          }),
      evidence: %{
        "reply_code" => Fx.reply_code(result),
        "absent_section58_fields" => Enum.map(absent, &Atom.to_string/1)
      }
    )
  end

  # `nondeterministic_outcomes: []` is a DECLARED deterministic plan, not blank.
  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  # 016 (negative) / 017 (positive)
  defp planner_non_authority(ctx, falsifier, kind) do
    token = Fx.token()

    outcome =
      Fx.with_store(fn store_opts ->
        Context.stimulus(ctx, falsifier, fn ->
          case HddlDeterministicSynthesis.synthesize(Planned, Fx.goal_facts(token)) do
            {:ok, feasible} ->
              planned = Fx.planned(token)

              replies =
                for step <- planned.plan.steps do
                  command =
                    case kind do
                      :negative ->
                        Fx.step_command(step,
                          principal: Identity.principal(Fx.planner_identity()),
                          metadata: %{
                            "planner_identity" => Fx.planner_identity(),
                            "feasibility_fingerprint" => feasible.fingerprint,
                            "authority_requirements" =>
                              inspect(planned.package.authority_requirements)
                          }
                        )

                      :positive ->
                        Fx.step_command(step, authority: :granted)
                    end

                  CommandBus.run(
                    command,
                    Fx.step_message(step),
                    Planned,
                    store_opts ++ [plan: planned.plan, preflight: planned.preflight]
                  )
                end

              {:ok, planned, replies}

            {:error, reason} ->
              {:error, reason}
          end
        end)
      end)

    case outcome do
      {:ok, planned, replies} ->
        rows = Fx.consequence_rows(planned.token)

        attempt? =
          Fx.observed?(ctx, falsifier, "plan.package", %{"outcome" => "built"}) and
            Fx.observed?(ctx, falsifier, "planning.admit", %{
              "outcome" => "admitted",
              "planner" => "hddl_solver"
            }) and
            Fx.observed?(ctx, falsifier, "plan.select", %{"outcome" => "selected"}) and
            Fx.observed?(ctx, falsifier, "plan.construct", %{"outcome" => "constructed"}) and
            Fx.observed?(ctx, falsifier, "plan.preflight", %{"outcome" => "preflighted"}) and
            Fx.observed?(ctx, falsifier, "brce.target", %{"outcome" => "resolved"})

        evidence = %{
          "plan_digest" => planned.package.plan_digest,
          "reply_codes" => Enum.map(replies, &Fx.reply_code/1),
          "token_rows" => rows
        }

        case kind do
          :negative ->
            Result.negative(falsifier,
              attempt_observed?: attempt?,
              forbidden_outcome_observed?: rows > 0 or Fx.actuated?(ctx, falsifier),
              evidence: evidence
            )

          :positive ->
            Result.positive(falsifier,
              attempt_observed?: attempt?,
              expected_outcome_observed?:
                rows == 2 and Enum.all?(replies, &match?({:ok, _}, &1)) and
                  Fx.receipted_do?(ctx, falsifier),
              evidence: evidence
            )
        end

      {:error, %{code: :hddl_cli_not_built} = reason} ->
        Result.blocked(
          falsifier,
          "real hddl_cli binary unavailable: #{inspect(reason, limit: 6)}",
          :resource_blocked
        )

      {:error, reason} ->
        Result.unknown(
          falsifier,
          "the fixture plan was not confirmed feasible by the real planner: #{inspect(reason, limit: 6)}",
          :planning_failure
        )
    end
  end
end
