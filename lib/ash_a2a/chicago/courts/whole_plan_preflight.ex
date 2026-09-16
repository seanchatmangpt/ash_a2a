defmodule AshA2A.Chicago.Courts.WholePlanPreflight do
  @moduledoc """
  `CHI-PREFLIGHT` -- Gate 5 Whole Bounded Plan Preflighted (RFC-SA2A-002 §36;
  RFC-SA2A-001 S34, S35).

      Consequence(step) ⇒ PreflightIdentity(executing plan) = PreflightIdentity(preflighted plan)

  Every stimulus runs the real candidate pipeline
  (`AshA2A.Chicago.Fixtures.PlanGates.planned/0`), whose last stage is the
  real `AshA2A.Planning.Preflight.preflight/1`, then mutates the plan AFTER
  preflight and presents a plan step -- with real authority, so authority is
  not the deciding guard -- to the real `AshA2A.CommandBus` together with the
  ORIGINAL preflight identity.

  Falsifiers 001-009 mutate one RFC §36 field each, always to a value a fresh
  preflight would admit (`lawful_mutation` evidence), so only the preflight
  identity binding can refuse it:

  | falsifier | field | mutation |
  |---|---|---|
  | 001 | `fan_out` | 2 -> 3 |
  | 002 | `cascade_depth` | 1 -> 2 |
  | 003 | `parallelism` | 1 -> 2 |
  | 004 | `retry_count` | 0 -> 1 |
  | 005 | `resource_budget` | `max_invocations` 8 -> 16 |
  | 006 | `external_request_count` | 1 -> 2 |
  | 007 | `financial_envelope` | `max_minor_units` 0 -> 50_000 |
  | 008 | `authority_requirement` | scope `"room"` -> `"any-room"` |
  | 009 | `semantic_subject` | a different manufacturer digest |

  010 proves coverage: it enumerates every field of `%BoundedPlan{}`
  independently of `Preflight.bound_fields/0`, mutates each after preflight
  and requires each mutation to be refused before consequence by an identity
  mismatch naming exactly that field. 011 presents a plan step with no
  preflight identity; 012 presents a hand-forged identity over a plan the real
  preflight refused (fan-out above the package bound). 013 is the §100
  positive control: the unmutated preflighted plan executes receipted.

  Attempt evidence is the real preflight having issued an identity (or, for
  012, having refused) plus the step reaching the consequence boundary
  (`brce.target` resolved) -- never the preflight refusal itself, so removing
  the `CommandBus` preflight check makes every negative falsifier SURVIVE.
  """

  use AshA2A.Chicago.Court

  alias AshA2A.CommandBus
  alias AshA2A.Chicago.{Context, Falsifier, Result}
  alias AshA2A.Chicago.Fixtures.Brce.Planned
  alias AshA2A.Chicago.Fixtures.PlanGates, as: Fx
  alias AshA2A.Planning.{BoundedPlan, Preflight}
  alias AshA2A.Semantic.Construct
  alias AshA2A.SemanticSubject

  @court "CHI-PREFLIGHT"

  @fields [
    {1, :fan_out},
    {2, :cascade_depth},
    {3, :parallelism},
    {4, :retry_count},
    {5, :resource_budget},
    {6, :external_request_count},
    {7, :financial_envelope},
    {8, :authority_requirement},
    {9, :semantic_subject}
  ]

  @reached_boundary {:observed, "brce.target", %{"outcome" => "resolved"}}
  @preflighted {:observed, "plan.preflight", %{"outcome" => "preflighted"}}

  @impl true
  def id, do: @court
  @impl true
  def title, do: "Whole bounded plan preflighted: every consequence-changing field is bound"
  @impl true
  def gate, do: 5
  @impl true
  def profile, do: :plan
  @impl true
  def rfc_sections, do: ["§36", "§100"]

  @impl true
  def ocel_mappings, do: Fx.mappings()

  @doc "Every field of `%BoundedPlan{}`, enumerated from the struct itself."
  @spec plan_fields() :: [atom()]
  def plan_fields do
    BoundedPlan.__struct__() |> Map.keys() |> List.delete(:__struct__) |> Enum.sort()
  end

  # --- falsifier declarations (§11) -----------------------------------------

  @impl true
  def falsifiers do
    field_falsifiers =
      for {n, field} <- @fields do
        negative(n,
          invariant:
            "§36: a post-preflight mutation of #{field} is refused before consequence (bound by the preflight identity)",
          stimulus:
            "PlanGates.planned/0; mutate #{field} after preflight to a value a fresh preflight admits; CommandBus.run of the advance step with real authority, the mutated plan and the ORIGINAL preflight",
          boundary: "AshA2A.CommandBus preflight check (AshA2A.Planning.Preflight.admit_step/3)",
          forbidden_outcome: "actuation under the un-preflighted #{field}; advance row written",
          attempt_evidence:
            "plan.preflight preflighted and brce.target resolved for this stimulus",
          survival_evidence:
            "brce.actuate.start / dispatch.actuate attributed to the stimulus; token row visible to Ash.read!",
          guard: "Preflight.admit_step/3 same_identity/2 over the #{field} field digest",
          failure_class: :planning_failure,
          attempt_predicate: {:all, [@preflighted, @reached_boundary]},
          outcome_predicate: Fx.actuation_predicate()
        )
      end

    field_falsifiers ++
      [
        negative(10,
          invariant:
            "§36: every consequence-changing field of the executing plan is bound by the preflight identity",
          stimulus:
            "for every field of %BoundedPlan{} (enumerated from the struct, not from Preflight.bound_fields/0): mutate it after preflight and CommandBus.run the advance step with real authority",
          boundary: "AshA2A.CommandBus preflight check (AshA2A.Planning.Preflight.admit_step/3)",
          forbidden_outcome:
            "any actuation, or any field whose mutation is not refused by an identity mismatch naming that field",
          attempt_evidence:
            "plan.preflight preflighted and one brce.target resolved per struct field",
          survival_evidence:
            "actuation attributed to the stimulus, or a field with no brce.preflight refused code=preflight_identity_mismatch fields=<field>",
          guard: "Preflight.bound_fields/0 covering every BoundedPlan field; admit_step/3",
          failure_class: :planning_failure,
          attempt_predicate:
            {:all, [@preflighted, {:count, "brce.target", :gte, length(plan_fields())}]},
          outcome_predicate:
            {:any,
             [Fx.actuation_predicate()] ++
               for field <- plan_fields() do
                 {:not_observed, "brce.preflight",
                  %{
                    "outcome" => "refused",
                    "code" => "preflight_identity_mismatch",
                    "fields" => Atom.to_string(field)
                  }}
               end}
        ),
        negative(11,
          invariant: "§36: a plan step without the plan's preflight identity never actuates",
          stimulus:
            "CommandBus.run of the advance step with real authority and plan: but no preflight:",
          boundary: "AshA2A.CommandBus preflight check (AshA2A.Planning.Preflight.admit_step/3)",
          forbidden_outcome: "actuation of an un-preflighted plan step; advance row written",
          attempt_evidence: "plan.preflight preflighted and brce.target resolved",
          survival_evidence:
            "brce.actuate.start / dispatch.actuate attributed to the stimulus; token row visible",
          guard: "Preflight.admit_step(nil, plan, command) :preflight_required",
          failure_class: :planning_failure,
          attempt_predicate: {:all, [@preflighted, @reached_boundary]},
          outcome_predicate: Fx.actuation_predicate()
        ),
        negative(12,
          invariant:
            "§36: an identity not issued by the preflight boundary cannot carry an out-of-bounds plan to consequence",
          stimulus:
            "a plan with fan_out above the package's max_fan_out is refused by Preflight.preflight/1; a %Preflight{} is then hand-forged over it (field_digests/1 + identity_digest/1) and the advance step is run with real authority",
          boundary: "AshA2A.CommandBus preflight check (admit_step/3 re-validation)",
          forbidden_outcome: "actuation of the out-of-bounds plan; advance row written",
          attempt_evidence: "plan.preflight refused and brce.target resolved",
          survival_evidence:
            "brce.actuate.start / dispatch.actuate attributed to the stimulus; token row visible",
          guard: "Preflight.admit_step/3 re-running validate/1 over the executing plan",
          failure_class: :planning_failure,
          attempt_predicate:
            {:all,
             [
               {:observed, "plan.preflight", %{"outcome" => "refused"}},
               @reached_boundary
             ]},
          outcome_predicate: Fx.actuation_predicate()
        ),
        positive(13,
          invariant:
            "§100 the unmutated preflighted plan executes with authority (control for 001-012)",
          stimulus:
            "CommandBus.run of every step with real authority, the preflighted plan and its preflight",
          boundary: "AshA2A.CommandBus preflight + admission + BRCE",
          attempt_evidence: "plan.preflight preflighted and brce.target resolved",
          survival_evidence:
            "brce.preflight verified ≺ actuation; prepare ≺ actuate ≺ commit; both token rows visible",
          attempt_predicate: {:all, [@preflighted, @reached_boundary]},
          outcome_predicate:
            {:all,
             [
               {:observed, "brce.preflight", %{"outcome" => "verified"}},
               {:precedes, "brce.preflight", "brce.actuate.start", "command"},
               Fx.receipted_do_predicate()
             ]}
        )
      ]
  end

  defp negative(n, fields), do: declare(n, :negative, fields)
  defp positive(n, fields), do: declare(n, :positive_control, fields)

  defp declare(n, kind, fields) do
    Falsifier.new!(
      [id: falsifier_id(n), court_id: @court, kind: kind, rfc_sections: ["§36"]] ++ fields
    )
  end

  defp falsifier_id(n), do: @court <> "-" <> String.pad_leading(Integer.to_string(n), 3, "0")

  # --- execution ---------------------------------------------------------------

  @impl true
  def run(%Context{} = ctx) do
    f = Map.new(falsifiers(), &{&1.id, &1})
    get = fn n -> Map.fetch!(f, falsifier_id(n)) end

    (Enum.map(@fields, fn {n, field} -> {n, &mutated_field(ctx, &1, field)} end) ++
       [
         {10, &coverage(ctx, &1)},
         {11, &no_preflight(ctx, &1)},
         {12, &forged_identity(ctx, &1)},
         {13, &preflighted_plan(ctx, &1)}
       ])
    |> Enum.map(fn {n, fun} -> Fx.fenced(ctx, get.(n), fn -> fun.(get.(n)) end) end)
  end

  # 001-009
  defp mutated_field(ctx, falsifier, field) do
    {planned, lawful, reply} =
      Fx.with_store(fn store_opts ->
        Context.stimulus(ctx, falsifier, fn ->
          planned = Fx.planned()
          mutated = mutate(planned, field)
          lawful = lawful?(mutated)
          [step | _] = planned.plan.steps
          reply = run_step(step, mutated, planned.preflight, store_opts)
          {planned, lawful, reply}
        end)
      end)

    rows = Fx.consequence_rows(planned.token)

    Result.negative(falsifier,
      attempt_observed?: preflighted_and_reached?(ctx, falsifier),
      forbidden_outcome_observed?: rows > 0 or Fx.actuated?(ctx, falsifier),
      evidence: %{
        "field" => Atom.to_string(field),
        "lawful_mutation" => lawful,
        "reply_code" => Fx.reply_code(reply),
        "refused_fields" => Fx.attr_values(ctx, falsifier, "brce.preflight", "fields"),
        "token_rows" => rows
      }
    )
  end

  # 010
  defp coverage(ctx, falsifier) do
    fields = plan_fields()

    {planned, outcomes} =
      Fx.with_store(fn store_opts ->
        Context.stimulus(ctx, falsifier, fn ->
          planned = Fx.planned()
          [step | _] = planned.plan.steps

          outcomes =
            for field <- fields do
              reply = run_step(step, mutate(planned, field), planned.preflight, store_opts)
              {field, Fx.reply_code(reply)}
            end

          {planned, outcomes}
        end)
      end)

    rows = Fx.consequence_rows(planned.token)
    refused = Fx.attr_values(ctx, falsifier, "brce.preflight", "fields")
    codes = Fx.attr_values(ctx, falsifier, "brce.preflight", "code")

    uncovered =
      Enum.reject(fields, fn field ->
        Enum.zip(refused, codes)
        |> Enum.any?(fn {named, code} ->
          named == Atom.to_string(field) and code == "preflight_identity_mismatch"
        end)
      end)

    reached = Enum.count(Context.observed(ctx, falsifier), &(&1.activity == "brce.target"))

    Result.negative(falsifier,
      attempt_observed?:
        Fx.observed?(ctx, falsifier, "plan.preflight", %{"outcome" => "preflighted"}) and
          reached >= length(fields),
      forbidden_outcome_observed?: rows > 0 or Fx.actuated?(ctx, falsifier) or uncovered != [],
      evidence: %{
        "struct_fields" => Enum.map(fields, &Atom.to_string/1),
        "declared_bound_fields" => Enum.map(Preflight.bound_fields(), &Atom.to_string/1),
        "outcomes" => Map.new(outcomes, fn {k, v} -> {Atom.to_string(k), v} end),
        "uncovered" => Enum.map(uncovered, &Atom.to_string/1),
        "token_rows" => rows
      }
    )
  end

  # 011
  defp no_preflight(ctx, falsifier) do
    {planned, reply} =
      Fx.with_store(fn store_opts ->
        Context.stimulus(ctx, falsifier, fn ->
          planned = Fx.planned()
          [step | _] = planned.plan.steps

          reply =
            CommandBus.run(
              Fx.step_command(step, authority: :granted),
              Fx.step_message(step),
              Planned,
              store_opts ++ [plan: planned.plan]
            )

          {planned, reply}
        end)
      end)

    rows = Fx.consequence_rows(planned.token)

    Result.negative(falsifier,
      attempt_observed?: preflighted_and_reached?(ctx, falsifier),
      forbidden_outcome_observed?: rows > 0 or Fx.actuated?(ctx, falsifier),
      evidence: %{"reply_code" => Fx.reply_code(reply), "token_rows" => rows}
    )
  end

  # 012
  defp forged_identity(ctx, falsifier) do
    {planned, refusal, reply} =
      Fx.with_store(fn store_opts ->
        Context.stimulus(ctx, falsifier, fn ->
          planned = Fx.planned()
          unbounded = %{planned.plan | fan_out: planned.package.max_fan_out + 1}
          refusal = Preflight.preflight(unbounded)
          digests = Preflight.field_digests(unbounded)

          forged = %Preflight{
            preflight_digest: Preflight.identity_digest(digests),
            plan_digest: planned.package.plan_digest,
            field_digests: digests
          }

          [step | _] = planned.plan.steps
          {planned, refusal, run_step(step, unbounded, forged, store_opts)}
        end)
      end)

    rows = Fx.consequence_rows(planned.token)

    Result.negative(falsifier,
      attempt_observed?:
        Fx.observed?(ctx, falsifier, "plan.preflight", %{"outcome" => "refused"}) and
          Fx.observed?(ctx, falsifier, "brce.target", %{"outcome" => "resolved"}),
      forbidden_outcome_observed?: rows > 0 or Fx.actuated?(ctx, falsifier),
      evidence: %{
        "preflight_of_unbounded" => Fx.reply_code(refusal),
        "reply_code" => Fx.reply_code(reply),
        "token_rows" => rows
      }
    )
  end

  # 013
  defp preflighted_plan(ctx, falsifier) do
    {planned, replies} =
      Fx.with_store(fn store_opts ->
        Context.stimulus(ctx, falsifier, fn ->
          planned = Fx.planned()

          replies =
            for step <- planned.plan.steps,
                do: run_step(step, planned.plan, planned.preflight, store_opts)

          {planned, replies}
        end)
      end)

    rows = Fx.consequence_rows(planned.token)

    Result.positive(falsifier,
      attempt_observed?: preflighted_and_reached?(ctx, falsifier),
      expected_outcome_observed?:
        rows == 2 and Enum.all?(replies, &match?({:ok, _}, &1)) and
          Fx.observed?(ctx, falsifier, "brce.preflight", %{"outcome" => "verified"}) and
          Fx.receipted_do?(ctx, falsifier),
      evidence: %{"reply_codes" => Enum.map(replies, &Fx.reply_code/1), "token_rows" => rows}
    )
  end

  # --- stimuli material -------------------------------------------------------

  defp run_step(step, plan, preflight, store_opts) do
    CommandBus.run(
      Fx.step_command(step, authority: :granted),
      Fx.step_message(step),
      Planned,
      store_opts ++ [plan: plan, preflight: preflight]
    )
  end

  defp preflighted_and_reached?(ctx, falsifier) do
    Fx.observed?(ctx, falsifier, "plan.preflight", %{"outcome" => "preflighted"}) and
      Fx.observed?(ctx, falsifier, "brce.target", %{"outcome" => "resolved"})
  end

  # A fresh preflight of the mutated plan admits it: only the identity binding
  # can tell it apart from the plan that was preflighted.
  defp lawful?(mutated), do: match?({:ok, _}, Preflight.preflight(mutated))

  @doc false
  # Post-preflight mutations. The nine RFC §36 fields (and `:steps`) mutate to
  # values a fresh preflight admits; `:plan_package`, `:standing` and
  # `:authority` cannot change lawfully without also changing another bound
  # value, so they mutate to the nearest real alternative.
  @spec mutate(Fx.planned(), atom()) :: BoundedPlan.t()
  def mutate(%{plan: plan} = planned, field) do
    case field do
      :fan_out ->
        %{plan | fan_out: plan.fan_out + 1}

      :cascade_depth ->
        %{plan | cascade_depth: plan.cascade_depth + 1}

      :parallelism ->
        %{plan | parallelism: plan.parallelism + 1}

      :retry_count ->
        %{plan | retry_count: plan.retry_count + 1}

      :resource_budget ->
        %{plan | resource_budget: %{plan.resource_budget | max_invocations: 16}}

      :external_request_count ->
        %{plan | external_request_count: plan.external_request_count + 1}

      :financial_envelope ->
        %{plan | financial_envelope: %{plan.financial_envelope | max_minor_units: 50_000}}

      :authority_requirement ->
        %{
          plan
          | authority_requirement:
              Enum.map(plan.authority_requirement, &%{&1 | scope: "any-room"})
        }

      :semantic_subject ->
        {:ok, subject} =
          SemanticSubject.new(
            graph_digest: plan.semantic_subject.graph_digest,
            projection_digest: plan.semantic_subject.projection_digest,
            manufacturer_digest:
              Construct.manufacturer_digest("other-manufacturer", "v0", :strict)
          )

        %{plan | semantic_subject: subject}

      :steps ->
        [advance, unlock] = plan.steps
        %{plan | steps: [advance, %{unlock | input: %{"who" => unlock.input["who"] <> "-other"}}]}

      :plan_package ->
        {:ok, other} = Fx.package(planned.projection, planned.token, max_depth: 7)
        %{plan | plan_package: other}

      :standing ->
        %{plan | standing: :selected}

      :authority ->
        %{plan | authority: :do}

      other ->
        Map.put(plan, other, {:chicago_mutated, Map.get(plan, other)})
    end
  end
end
