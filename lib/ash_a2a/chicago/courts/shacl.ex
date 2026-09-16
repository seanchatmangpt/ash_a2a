defmodule AshA2A.Chicago.Courts.Shacl do
  @moduledoc """
  RFC-SA2A-002 §46 SHACL semantic falsifier court (`SA2A-SHACL`).

  Every stimulus is one real `AshA2A.Semantic.AdmissionPipeline.admit/2` over
  the real `praxis-graphlaw` wasm, judged under the Gate 2 world law
  (`AshA2A.Chicago.Fixtures.ShexShaclAdmission`), whose SHACL shapes encode
  the RFC-SA2A-001 S15 invariants. Each negative vector is the lawful world
  graph with exactly one semantic mutation that stays ShEx-valid, so the
  boundary expected to decide is the pipeline's SHACL stage.

  ## Severity (§46 last paragraph, RFC-SA2A-001 S15)

    * `SA2A-SHACL-007` (negative): a `sh:Violation` together with a
      `sh:Warning` MUST be refused -- the warning must not soften it.
    * `SA2A-SHACL-009` (positive control): a graph whose only SHACL result is
      a `sh:Warning` is admitted. Without it, a SHACL stage that refuses on
      any result whatsoever would pass -007 vacuously (§100: a verifier that
      always refuses is not conformant merely because it blocks attacks).

  `SA2A-SHACL-008` is the §100 "invalid SHACL refused / valid graph admitted"
  positive control.

  ## Defect found by this court and repaired

  Before `AshA2A.Semantic.ShaclSeverity`, `SA2A-SHACL-009` reported
  `:positive_control_failed`: the pinned engine reports SHACL `REFUSED` for
  any result regardless of severity and the pipeline read that directly, so a
  warning-only world was refused at `:shacl` with `:shacl_nonconformant`. The
  pipeline now decides S15 by a violations-only partition run of the same
  engine; -007 stays killed.

  When the real engine is unavailable every falsifier is `:blocked` with the
  measured reason -- never killed.
  """

  use AshA2A.Chicago.Court

  alias AshA2A.Chicago.{Context, Falsifier, Result}
  alias AshA2A.Chicago.Fixtures.ShexShaclAdmission, as: World
  alias AshA2A.Chicago.Fixtures.ShexShaclAdmission.Evidence

  @id "SA2A-SHACL"

  @impl true
  def id, do: @id
  @impl true
  def title, do: "SHACL semantic falsifiers over the real admission pipeline"
  @impl true
  def gate, do: 2
  @impl true
  def profile, do: :core
  @impl true
  def rfc_sections, do: ["§46", "§44", "§100"]

  @negatives [
    {"001", "consequence without authority requirement",
     "Consequence(a) => AuthorityRequirement(a)",
     "ex:action1 carries sa:hasConsequence with no sa:requiresAuthority",
     :shacl_consequence_without_authority, :authority_failure},
    {"002", "DO without receipt requirement", "DO(a) => ReceiptRequirement(a)",
     "ex:do1 is an sa:DoStep with no sa:preparedReceipt", :shacl_do_without_receipt,
     :receipt_failure},
    {"003", "plan with unknown capability", "Plan(p) => KnownCapability(action_i)",
     "ex:plan1 sa:usesCapability a capability outside the admitted set",
     :shacl_plan_unknown_capability, :planning_failure},
    {"004", "private term without namespace admission",
     "PrivateSemanticTerm(x) => PrivateNamespaceAdmission(x)",
     "an sa:PrivateTerm minted in urn:acme:private:, outside the admitted namespace",
     :shacl_private_term_without_namespace_admission, :admission_failure},
    {"005", "resource bound violation", "Plan(p) => FanOut(p) <= 8 AND Cost(p) <= Budget(p)",
     "ex:plan1 with sa:fanOut 9 and sa:resourceCost 11 over sa:resourceBudget 10",
     :shacl_resource_bound_violation, :bound_failure},
    {"006", "canonical mutation outside consequence law",
     "CanonicalMutation(m) => via(m, CommandBus)",
     "ex:mutation1 is an sa:CanonicalMutation via ex:directStoreWrite",
     :shacl_canonical_mutation_outside_consequence_law, :actuation_failure},
    {"007", "warning does not override a MUST-level violation",
     "Violation(x) AND Warning(x) => Refused(x)",
     "the world lacks its sh:Warning documentation AND ex:plan1 exceeds the sh:Violation fan-out bound",
     :shacl_violation_and_warning, :validator_failure}
  ]

  @impl true
  def falsifiers do
    negatives =
      for {n, name, law, stimulus, _vector, class} <- @negatives do
        Falsifier.new!(
          id: "#{@id}-#{n}",
          court_id: @id,
          kind: :negative,
          invariant:
            "#{name}: #{law} -- an object violating it MUST NOT acquire standing (RFC-SA2A-001 S15)",
          stimulus:
            "AdmissionPipeline.admit/2 of the ShEx-valid Gate 2 world graph mutated so that: " <>
              stimulus,
          boundary: "AshA2A.Semantic.AdmissionPipeline :shacl stage (GraphLaw SHACL dialect)",
          forbidden_outcome:
            "the :shacl stage passes, or the candidate reaches :admitted, or canonical state changes",
          attempt_evidence: "admission.stage event for stage=shacl attributed to this stimulus",
          survival_evidence:
            "admission.stage stage=shacl outcome=ok or admission.stop outcome=admitted in OCEL; " <>
              "{:ok, _} returned; independent canonical snapshot differs",
          guard:
            "AdmissionPipeline.run_stage(:shacl, ...): SHACL REFUSED -> :shacl_nonconformant unless the " <>
              "violations-only partition run ADMITTED",
          failure_class: class,
          rfc_sections: ["§46"],
          attempt_predicate: Evidence.stage(:shacl),
          outcome_predicate: {:any, [Evidence.stage(:shacl, :ok), Evidence.admitted()]}
        )
      end

    negatives ++
      [
        Falsifier.new!(
          id: "#{@id}-008",
          court_id: @id,
          kind: :positive_control,
          invariant:
            "A graph satisfying every admitted SHACL invariant is admitted: SHACL discriminates (§100)",
          stimulus: "AdmissionPipeline.admit/2 of the lawful Gate 2 world graph",
          boundary: "AshA2A.Semantic.AdmissionPipeline :shacl stage",
          attempt_evidence: "admission.stage event for stage=shacl attributed to this stimulus",
          survival_evidence:
            "admission.stage stage=shacl outcome=ok and admission.stop outcome=admitted",
          rfc_sections: ["§46", "§100"],
          attempt_predicate: Evidence.stage(:shacl),
          outcome_predicate: {:all, [Evidence.stage(:shacl, :ok), Evidence.admitted()]}
        ),
        Falsifier.new!(
          id: "#{@id}-009",
          court_id: @id,
          kind: :positive_control,
          invariant:
            "A graph whose only SHACL result has sh:Warning severity is admitted: severity discriminates (RFC-SA2A-001 S15)",
          stimulus:
            "AdmissionPipeline.admit/2 of the world graph lacking only its sh:Warning-severity rdfs:comment",
          boundary:
            "AshA2A.Semantic.AdmissionPipeline :shacl stage + AshA2A.Semantic.ShaclSeverity",
          attempt_evidence: "admission.stage event for stage=shacl attributed to this stimulus",
          survival_evidence:
            "admission.stage stage=shacl outcome=ok and admission.stop outcome=admitted",
          failure_class: :validator_failure,
          rfc_sections: ["§46", "§100"],
          attempt_predicate: Evidence.stage(:shacl),
          outcome_predicate: {:all, [Evidence.stage(:shacl, :ok), Evidence.admitted()]}
        )
      ]
  end

  @impl true
  def run(%Context{} = ctx) do
    falsifiers = falsifiers()

    case Evidence.engine() do
      {:blocked, reason} ->
        Evidence.blocked(falsifiers, reason)

      :ok ->
        scratch = Evidence.scratch_dir(ctx, @id)
        by_id = Map.new(falsifiers, &{&1.id, &1})

        negatives =
          for {n, _name, _law, _stimulus, vector, _class} <- @negatives do
            f = Map.fetch!(by_id, "#{@id}-#{n}")
            candidate = World.candidate(graph_ttl: apply(World, vector, []))
            Evidence.stage_negative(ctx, f, candidate, scratch, :shacl)
          end

        negatives ++
          [
            admitted_control(ctx, Map.fetch!(by_id, "#{@id}-008"), World.world_graph(), scratch),
            admitted_control(
              ctx,
              Map.fetch!(by_id, "#{@id}-009"),
              World.shacl_warning_only(),
              scratch
            )
          ]
    end
  end

  defp admitted_control(ctx, %Falsifier{} = f, graph, scratch) do
    {result, before, after_snapshot} =
      Evidence.admit(ctx, f, World.candidate(graph_ttl: graph), scratch)

    Result.positive(f,
      attempt_observed?: Evidence.stage_seen?(ctx, f, :shacl),
      expected_outcome_observed?:
        Evidence.stage_seen?(ctx, f, :shacl, :ok) and Evidence.admitted_seen?(ctx, f) and
          match?({:ok, %{standing: :admitted, authority: :none}}, result),
      evidence: Evidence.admission_evidence(result, before, after_snapshot)
    )
  end
end
