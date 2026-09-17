defmodule AshA2A.Chicago.Courts.PlanAuthority do
  @moduledoc """
  `CHI-PLAN-AUTH` -- Gate 4 Planning Candidate-Only (RFC-SA2A-002 §35;
  RFC-SA2A-001 §4.3-§4.6, S25, S26).

      ValidPlan ⇏ DO

  The court attempts to obtain consequence solely from planner output. Every
  stimulus first runs the real candidate pipeline
  (`AshA2A.Chicago.Fixtures.PlanGates.planned/0`: admitted projection -> two
  strict `PlanPackage`s -> real `Select` -> real `Construct` -> real
  `Preflight`), so the plan is observed SELECTED and CONSTRUCTED at those
  boundaries, then presents the constructed steps to the real
  `AshA2A.CommandBus` (or the real `AshA2A.Agent` A2A handler) carrying one
  kind of planner output and no authority:

  | falsifier | planner output presented |
  |---|---|
  | 001 | the valid, preflighted plan itself (no authority) |
  | 002 | the optimizer's selection (digest + selector identity) |
  | 003 | a real proof of safety (STRIPS entailment chain + admitted bounds) |
  | 004 | a real Ed25519 signature over the plan and preflight digests |
  | 005 | an A2A task assignment of a plan step to an authenticated, ungranted principal |

  Positive controls (§100): 006 the same plan with real authority executes
  receipted (control for 001-004); 007 the A2A task assignment to a granted
  principal executes (control for 005).

  Attempt evidence is the plan having reached SELECTED/CONSTRUCTED and the
  step having reached the consequence boundary (`brce.target` resolved) --
  never the authority refusal itself, so deleting the authority guard makes
  every negative falsifier SURVIVE (§11, §22).
  """

  use AshA2A.Chicago.Court

  alias AshA2A.{CommandBus, Identity}
  alias AshA2A.Chicago.{Context, Falsifier, Result}
  alias AshA2A.Chicago.Fixtures.Brce.{Planned, PlannedAgent}
  alias AshA2A.Chicago.Fixtures.PlanGates, as: Fx
  alias AshA2A.Semantic.{Bounds, CapabilityComposition}

  @court "CHI-PLAN-AUTH"

  @impl true
  def id, do: @court
  @impl true
  def title, do: "Planning candidate-only: planner output never yields consequence"
  @impl true
  def gate, do: 4
  @impl true
  def profile, do: :plan
  @impl true
  def rfc_sections, do: ["§35", "§59", "§100"]

  @impl true
  def ocel_mappings, do: Fx.mappings()

  @selected_constructed [
    {:observed, "plan.select", %{"outcome" => "selected"}},
    {:observed, "plan.construct", %{"outcome" => "constructed"}}
  ]

  @reached_boundary {:observed, "brce.target", %{"outcome" => "resolved"}}

  # --- falsifier declarations (§11) -----------------------------------------

  @impl true
  def falsifiers do
    [
      negative(1,
        invariant:
          "ValidPlan ⇏ DO: a valid, selected, constructed, preflighted plan grants nothing",
        stimulus:
          "PlanGates.planned/0 then CommandBus.run of every constructed step with authority nil, plan: and preflight: presented",
        boundary: "AshA2A.CommandBus admission (admit/2)",
        forbidden_outcome: "any actuation of a plan step; advance/unlock rows written",
        attempt_evidence:
          "plan.select selected, plan.construct constructed and brce.target resolved for this stimulus",
        survival_evidence:
          "brce.actuate.start / dispatch.actuate attributed to the stimulus; token rows visible to Ash.read!",
        guard:
          "CommandBus.admit/2 :authority_required refusal for a :change/:external_do command",
        failure_class: :authority_failure,
        attempt_predicate: {:all, @selected_constructed ++ [@reached_boundary]},
        outcome_predicate: Fx.actuation_predicate()
      ),
      negative(2,
        invariant: "SELECT ⇏ DO: the optimizer-selected action carries no authority",
        stimulus:
          "Select.select/3 picks the lowest-cost of two strict packages; its chosen action is run with the selection digest and selector identity in command metadata and no authority",
        boundary: "AshA2A.CommandBus admission (admit/2)",
        forbidden_outcome: "actuation of the selected action; advance row written",
        attempt_evidence:
          "plan.select selected over 2 candidates, plan.construct constructed, brce.target resolved",
        survival_evidence:
          "brce.actuate.start / dispatch.actuate attributed to the stimulus; token rows visible to Ash.read!",
        guard: "CommandBus.admit/2 accepts only a real %AshA2A.Authority{} admitting the command",
        failure_class: :authority_failure,
        attempt_predicate:
          {:all,
           [
             {:observed, "plan.select", %{"outcome" => "selected", "candidates" => "2"}},
             {:observed, "plan.construct", %{"outcome" => "constructed"}},
             @reached_boundary
           ]},
        outcome_predicate: Fx.actuation_predicate()
      ),
      negative(3,
        invariant: "Proof(x) ⇏ Authority(x): a real proof of safety grants nothing",
        stimulus:
          "CapabilityComposition.chain/2 proves the steps' preconditions entailed and the goal reached from the initial state; Bounds.new/1 admits the plan's fan-out, depth and parallelism; the proof accompanies every step in command metadata with no authority",
        boundary: "AshA2A.CommandBus admission (admit/2)",
        forbidden_outcome: "any actuation of a plan step; advance/unlock rows written",
        attempt_evidence:
          "plan.select selected, plan.construct constructed and brce.target resolved for this stimulus",
        survival_evidence:
          "brce.actuate.start / dispatch.actuate attributed to the stimulus; token rows visible to Ash.read!",
        guard: "CommandBus.admit/2 accepts only a real %AshA2A.Authority{} admitting the command",
        failure_class: :authority_failure,
        attempt_predicate: {:all, @selected_constructed ++ [@reached_boundary]},
        outcome_predicate: Fx.actuation_predicate()
      ),
      negative(4,
        invariant: "a signed plan is not authority",
        stimulus:
          "a real Ed25519 key signs plan_digest <> preflight_digest (verified with :crypto.verify/5); every step is run with the signature, public key and signed digests in command metadata and no authority",
        boundary: "AshA2A.CommandBus admission (admit/2)",
        forbidden_outcome: "any actuation of a plan step; advance/unlock rows written",
        attempt_evidence:
          "plan.select selected, plan.construct constructed and brce.target resolved for this stimulus",
        survival_evidence:
          "brce.actuate.start / dispatch.actuate attributed to the stimulus; token rows visible to Ash.read!",
        guard: "CommandBus.admit/2 :authority_required refusal (metadata is never consulted)",
        failure_class: :authority_failure,
        attempt_predicate: {:all, @selected_constructed ++ [@reached_boundary]},
        outcome_predicate: Fx.actuation_predicate()
      ),
      negative(5,
        invariant:
          "an A2A task assignment of a plan step is not authority (Authenticated ⇏ Authorized)",
        stimulus:
          "PlannedAgent.call/3 (real supervised A2A.Agent) assigning skill advance with the plan and preflight digests in metadata, by a transport-authenticated principal the real broker holds no grant for",
        boundary:
          "AshA2A.Agent.dispatch_skill/4 -> Authority.Grant.authorize/2 -> AshA2A.CommandBus",
        forbidden_outcome: "actuation of the assigned step; advance row written",
        attempt_evidence:
          "plan.construct constructed, agent.dispatch route=command_bus and brce.target resolved",
        survival_evidence:
          "brce.actuate.start / dispatch.actuate attributed to the stimulus; token rows visible to Ash.read!",
        guard:
          "Authority.Grant.authorize/2 returns nil without a broker grant; CommandBus.admit/2 :authority_required",
        failure_class: :authority_failure,
        attempt_predicate:
          {:all,
           [
             {:observed, "plan.construct", %{"outcome" => "constructed"}},
             {:observed, "agent.dispatch", %{"route" => "command_bus"}},
             @reached_boundary
           ]},
        outcome_predicate: Fx.actuation_predicate()
      ),
      positive(6,
        invariant:
          "§100 the same selected, constructed, preflighted plan executes when real authority is presented (control for 001-004)",
        stimulus:
          "PlanGates.planned/0 then CommandBus.run of every step with a real AshA2A.Authority, plan: and preflight:",
        boundary: "AshA2A.CommandBus preflight + admission + BRCE",
        attempt_evidence: "plan.construct constructed and brce.target resolved",
        survival_evidence:
          "brce.preflight verified, brce.admission admitted, prepare ≺ actuate ≺ commit; both token rows visible",
        attempt_predicate: {:all, @selected_constructed ++ [@reached_boundary]},
        outcome_predicate:
          {:all,
           [
             {:observed, "brce.preflight", %{"outcome" => "verified"}},
             {:observed, "brce.admission", %{"outcome" => "admitted"}},
             Fx.receipted_do_predicate()
           ]}
      ),
      positive(7,
        invariant:
          "§100 the A2A task assignment of a plan step to a granted principal executes (control for 005)",
        stimulus:
          "PlannedAgent.call/3 assigning skill advance to a transport-authenticated principal holding a real broker grant",
        boundary: "AshA2A.Agent -> AshA2A.CommandBus",
        attempt_evidence: "agent.dispatch route=command_bus and brce.target resolved",
        survival_evidence:
          "brce.admission admitted, prepare ≺ actuate ≺ commit; the advance row visible to Ash.read!",
        attempt_predicate:
          {:all,
           [
             {:observed, "plan.construct", %{"outcome" => "constructed"}},
             {:observed, "agent.dispatch", %{"route" => "command_bus"}},
             @reached_boundary
           ]},
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
      [id: falsifier_id(n), court_id: @court, kind: kind, rfc_sections: ["§35"]] ++ fields
    )
  end

  defp falsifier_id(n), do: @court <> "-" <> String.pad_leading(Integer.to_string(n), 3, "0")

  # --- execution ---------------------------------------------------------------

  @impl true
  def run(%Context{} = ctx) do
    f = Map.new(falsifiers(), &{&1.id, &1})
    get = fn n -> Map.fetch!(f, falsifier_id(n)) end

    [
      {1, &unauthorized_plan(ctx, &1, fn _planned -> nil end, :all_steps, %{})},
      {2, &selected_action(ctx, &1)},
      {3, &proof_of_safety(ctx, &1)},
      {4, &signed_plan(ctx, &1)},
      {5, &task_assignment(ctx, &1, :negative)},
      {6, &authorized_plan(ctx, &1)},
      {7, &task_assignment(ctx, &1, :positive)}
    ]
    |> Enum.map(fn {n, fun} -> Fx.fenced(ctx, get.(n), fn -> fun.(get.(n)) end) end)
  end

  # 001 (and the shared shape of 002-004): the plan pipeline plus step
  # submission with `authority_for.(planned)` in the authority slot.
  defp unauthorized_plan(ctx, falsifier, authority_for, which, extra_evidence) do
    {planned, replies, extra} =
      Fx.with_store(fn store_opts ->
        Context.stimulus(ctx, falsifier, fn ->
          planned = Fx.planned()
          {authority, metadata, extra} = authority_material(authority_for.(planned), planned)

          replies =
            for step <- steps(planned, which) do
              CommandBus.run(
                Fx.step_command(step, authority: authority || :none, metadata: metadata),
                Fx.step_message(step),
                Planned,
                store_opts ++ [plan: planned.plan, preflight: planned.preflight]
              )
            end

          {planned, replies, extra}
        end)
      end)

    rows = Fx.consequence_rows(planned.token)

    Result.negative(falsifier,
      attempt_observed?:
        Fx.observed?(ctx, falsifier, "plan.select", %{"outcome" => "selected"}) and
          Fx.observed?(ctx, falsifier, "plan.construct", %{"outcome" => "constructed"}) and
          Fx.observed?(ctx, falsifier, "brce.target", %{"outcome" => "resolved"}),
      forbidden_outcome_observed?: rows > 0 or Fx.actuated?(ctx, falsifier),
      evidence:
        Map.merge(
          %{
            "plan_digest" => planned.package.plan_digest,
            "selection_standing" => to_string(planned.selection.standing),
            "construction_standing" => to_string(planned.construction.standing),
            "reply_codes" => Enum.map(replies, &Fx.reply_code/1),
            "admission" => Fx.attr_values(ctx, falsifier, "brce.admission", "code"),
            "token_rows" => rows
          },
          Map.merge(extra_evidence, extra)
        )
    )
  end

  defp authority_material(nil, _planned), do: {nil, %{}, %{}}
  defp authority_material({:metadata, metadata, extra}, _planned), do: {nil, metadata, extra}

  defp steps(planned, :all_steps), do: planned.plan.steps
  defp steps(planned, :first_step), do: Enum.take(planned.plan.steps, 1)

  # 002
  defp selected_action(ctx, falsifier) do
    unauthorized_plan(
      ctx,
      falsifier,
      fn planned ->
        {:metadata,
         %{
           "selection_digest" => planned.selection.selection_digest,
           "selector_identity" => planned.selection.selector_identity
         },
         %{
           "selection_digest" => planned.selection.selection_digest,
           "considered" => length(planned.selection.considered_digests)
         }}
      end,
      :first_step,
      %{}
    )
  end

  # 003
  defp proof_of_safety(ctx, falsifier) do
    unauthorized_plan(ctx, falsifier, &safety_proof/1, :all_steps, %{})
  end

  defp safety_proof(planned) do
    [advance, unlock] =
      for name <- [:advance, :unlock] do
        {:ok, skill} = AshA2A.Info.skill(Planned, name)
        [operator | _] = skill.hddl_operators
        {skill, operator}
      end

    {from, to} = Fx.phases(planned.token)
    profiles = Enum.map([advance, unlock], &profile(&1, from, to))
    initial = [{:current_phase, [from]}]
    chain = CapabilityComposition.chain(profiles, initial_state: initial)

    goal_entailed? =
      case chain do
        {:ok, {_compositions, final}} ->
          CapabilityComposition.entails?(final, planned.package.effects)

        _ ->
          false
      end

    bounds =
      with {:ok, bounds} <-
             Bounds.new(
               fan_out: planned.package.max_fan_out,
               depth: planned.package.max_depth,
               parallelism: planned.package.max_parallelism,
               capabilities: planned.package.required_capabilities
             ),
           :ok <- Bounds.admit_fan_out(bounds, planned.plan.fan_out),
           :ok <- Bounds.admit_depth(bounds, planned.plan.cascade_depth),
           :ok <- Bounds.admit_parallelism(bounds, planned.plan.parallelism) do
        :admitted
      end

    proof = %{
      kind: :proof_of_safety,
      chain: match?({:ok, _}, chain),
      goal_entailed: goal_entailed?,
      bounds: bounds,
      plan_digest: planned.package.plan_digest
    }

    {:metadata,
     %{
       "proof_of_safety" => %{
         "chain" => proof.chain,
         "goal_entailed" => goal_entailed?,
         "bounds" => inspect(bounds),
         "plan_digest" => proof.plan_digest
       }
     },
     %{
       "proof_chain_ok" => proof.chain,
       "proof_goal_entailed" => goal_entailed?,
       "proof_bounds" => inspect(bounds)
     }}
  end

  # A composition profile of a real skill's HDDL operator, grounded on this
  # plan's phases (the operator's parameters are variables).
  defp profile({skill, operator}, from, to) do
    binding = %{from: from, to: to, who: to}

    ground = fn facts ->
      Enum.map(facts, fn {p, args} -> {p, Enum.map(args, &binding[&1])} end)
    end

    %AshA2A.Semantic.CapabilityProfile{
      capability_id: skill.id,
      consequence: skill.consequence,
      preconditions: ground.(operator.preconditions),
      add_effects: ground.(operator.add_effects),
      delete_effects: ground.(operator.delete_effects)
    }
  end

  # 004
  defp signed_plan(ctx, falsifier) do
    unauthorized_plan(
      ctx,
      falsifier,
      fn planned ->
        {public, private} = :crypto.generate_key(:eddsa, :ed25519)
        signed = planned.package.plan_digest <> "|" <> planned.preflight.preflight_digest
        signature = :crypto.sign(:eddsa, :none, signed, [private, :ed25519])
        verified? = :crypto.verify(:eddsa, :none, signed, signature, [public, :ed25519])

        {:metadata,
         %{
           "plan_signature" => Base.encode64(signature),
           "plan_signer_public_key" => Base.encode64(public),
           "signed_digests" => signed
         }, %{"signature_verified" => verified?}}
      end,
      :all_steps,
      %{}
    )
  end

  # 005 (negative, ungranted) / 007 (positive, granted)
  defp task_assignment(ctx, falsifier, kind) do
    who = "chicago-plan-gates-a2a-#{kind}-#{Fx.token()}"
    # SA2A-AUTH-017 (RFC-SA2A-002 S66): the real dispatch path
    # (`AshA2A.Agent.build_command/4`) now resolves the dispatched skill's
    # canonical capability id (`AshA2A.Info.skill/2`) before calling
    # `AshA2A.Authority.Grant.authorize/3`, so the grant `Fx.with_broker/2`
    # issues below must be keyed on that same canonical id -- exactly what
    # `Fx.capability_ids/0` already resolves for `Planned.advance` -- rather
    # than the bare wire selector "advance", or CHI-PLAN-AUTH-007's granted
    # dispatch would stop matching its own grant.
    [advance_id, _unlock_id] = Fx.capability_ids()
    grants = if kind == :positive, do: [{who, advance_id}], else: []

    {planned, reply} =
      Fx.with_broker(grants, fn ->
        {:ok, agent} = GenServer.start(PlannedAgent, [])

        try do
          Context.stimulus(ctx, falsifier, fn ->
            planned = Fx.planned()
            [step | _] = planned.plan.steps

            message = %{
              Fx.step_message(step)
              | metadata: %{
                  "skill" => "advance",
                  "plan_digest" => planned.package.plan_digest,
                  "preflight_digest" => planned.preflight.preflight_digest
                }
            }

            reply =
              PlannedAgent.call(agent, message, metadata: %{"a2a.auth" => %{identity: who}})

            {planned, reply}
          end)
        after
          if Process.alive?(agent), do: GenServer.stop(agent)
        end
      end)

    rows = Fx.consequence_rows(planned.token)

    attempt? =
      Fx.observed?(ctx, falsifier, "plan.construct", %{"outcome" => "constructed"}) and
        Fx.observed?(ctx, falsifier, "agent.dispatch", %{"route" => "command_bus"}) and
        Fx.observed?(ctx, falsifier, "brce.target", %{"outcome" => "resolved"})

    evidence = %{
      "principal" => Identity.external(Identity.principal(who)),
      "task" => task_state(reply),
      "admission" => Fx.attr_values(ctx, falsifier, "brce.admission", "outcome"),
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
            rows == 1 and
              Fx.observed?(ctx, falsifier, "brce.admission", %{"outcome" => "admitted"}) and
              Fx.receipted_do?(ctx, falsifier),
          evidence: evidence
        )
    end
  end

  # 006
  defp authorized_plan(ctx, falsifier) do
    {planned, replies} =
      Fx.with_store(fn store_opts ->
        Context.stimulus(ctx, falsifier, fn ->
          planned = Fx.planned()

          replies =
            for step <- planned.plan.steps do
              CommandBus.run(
                Fx.step_command(step, authority: :granted),
                Fx.step_message(step),
                Planned,
                store_opts ++ [plan: planned.plan, preflight: planned.preflight]
              )
            end

          {planned, replies}
        end)
      end)

    rows = Fx.consequence_rows(planned.token)

    Result.positive(falsifier,
      attempt_observed?:
        Fx.observed?(ctx, falsifier, "plan.construct", %{"outcome" => "constructed"}) and
          Fx.observed?(ctx, falsifier, "brce.target", %{"outcome" => "resolved"}),
      expected_outcome_observed?:
        rows == 2 and Enum.all?(replies, &match?({:ok, _}, &1)) and
          Fx.observed?(ctx, falsifier, "brce.preflight", %{"outcome" => "verified"}) and
          Fx.receipted_do?(ctx, falsifier),
      evidence: %{
        "reply_codes" => Enum.map(replies, &Fx.reply_code/1),
        "preflight" => Fx.attr_values(ctx, falsifier, "brce.preflight", "outcome"),
        "token_rows" => rows
      }
    )
  end

  defp task_state({:ok, %A2A.Task{status: status}}), do: to_string(status.state)
  defp task_state(other), do: Fx.reply_code(other)
end
