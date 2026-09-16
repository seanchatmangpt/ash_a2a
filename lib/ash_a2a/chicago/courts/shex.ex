defmodule AshA2A.Chicago.Courts.Shex do
  @moduledoc """
  RFC-SA2A-002 §45 ShEx structural falsifier court (`SA2A-SHEX`).

  Every stimulus is one real `AshA2A.Semantic.AdmissionPipeline.admit/2` over
  the real `praxis-graphlaw` wasm, judged under the Gate 2 world law
  (`AshA2A.Chicago.Fixtures.ShexShaclAdmission`). Each negative vector is the
  lawful world graph with exactly one structural mutation; the boundary
  expected to decide is the pipeline's ShEx stage.

  Evidence is the pipeline's own `admission.*` telemetry. Attempt means "the
  ShEx stage emitted a stage event for this stimulus" (whatever its outcome),
  so a removed or bypassed ShEx guard is reported as a survival rather than as
  an unobserved attempt (§22).

  `SA2A-SHEX-006` is the §45 required control: a structurally valid but
  semantically invalid object must pass ShEx and be refused by SHACL, proving
  the two layers are not collapsed into one check. `SA2A-SHEX-007` is the
  §100 positive control: a structurally and semantically valid world passes
  ShEx and is admitted, so a ShEx stage that refuses everything cannot pass.

  When the real engine is unavailable every falsifier is `:blocked` with the
  measured reason -- never killed.
  """

  use AshA2A.Chicago.Court

  alias AshA2A.Chicago.{Context, Falsifier, Result}
  alias AshA2A.Chicago.Fixtures.ShexShaclAdmission, as: World
  alias AshA2A.Chicago.Fixtures.ShexShaclAdmission.Evidence

  @id "SA2A-SHEX"

  @impl true
  def id, do: @id
  @impl true
  def title, do: "ShEx structural falsifiers over the real admission pipeline"
  @impl true
  def gate, do: 2
  @impl true
  def profile, do: :core
  @impl true
  def rfc_sections, do: ["§45", "§44", "§100"]

  @negatives [
    {"001", "missing required predicate", "ex:world without its ShEx-required rdfs:label (min 1)",
     :shex_missing_required_predicate},
    {"002", "excess cardinality", "ex:world with two rdfs:label values (max 1)",
     :shex_excess_cardinality},
    {"003", "wrong datatype", "sa:version as a plain string where xsd:integer is required",
     :shex_wrong_datatype},
    {"004", "wrong node kind", "sa:homepage as a literal where nodeKind iri is required",
     :shex_wrong_node_kind},
    {"005", "invalid nested structure",
     "the capability node referenced through @CapabilityShape carries a non-integer sa:tier",
     :shex_invalid_nested_structure}
  ]

  @impl true
  def falsifiers do
    negatives =
      for {n, name, stimulus, _vector} <- @negatives do
        Falsifier.new!(
          id: "#{@id}-#{n}",
          court_id: @id,
          kind: :negative,
          invariant:
            "A structurally invalid object (#{name}) MUST NOT proceed past ShEx to semantic admission (RFC-SA2A-001 S14)",
          stimulus:
            "AdmissionPipeline.admit/2 of the Gate 2 world graph mutated so that: " <> stimulus,
          boundary: "AshA2A.Semantic.AdmissionPipeline :shex stage (GraphLaw SHEX dialect)",
          forbidden_outcome:
            "the :shex stage passes, or the candidate reaches :admitted, or canonical state changes",
          attempt_evidence: "admission.stage event for stage=shex attributed to this stimulus",
          survival_evidence:
            "admission.stage stage=shex outcome=ok or admission.stop outcome=admitted in OCEL; " <>
              "{:ok, _} returned; independent canonical snapshot differs",
          guard:
            "AdmissionPipeline.run_stage(:shex, ...) require_dialect SHEX REFUSED -> :shex_nonconformant",
          failure_class: :validator_failure,
          rfc_sections: ["§45"],
          attempt_predicate: Evidence.stage(:shex),
          outcome_predicate: {:any, [Evidence.stage(:shex, :ok), Evidence.admitted()]}
        )
      end

    negatives ++
      [
        Falsifier.new!(
          id: "#{@id}-006",
          court_id: @id,
          kind: :positive_control,
          invariant:
            "ShEx and SHACL are not collapsed: a structurally valid but semantically invalid object passes ShEx and is refused by SHACL",
          stimulus:
            "AdmissionPipeline.admit/2 of the world graph whose sa:DoStep lacks sa:preparedReceipt (ShEx-valid, SHACL-invalid)",
          boundary: "AshA2A.Semantic.AdmissionPipeline :shex then :shacl stages",
          attempt_evidence: "admission.stage event for stage=shex attributed to this stimulus",
          survival_evidence:
            "admission.stage stage=shex outcome=ok AND admission.stage stage=shacl outcome=refused code=shacl_nonconformant",
          rfc_sections: ["§45"],
          attempt_predicate: Evidence.stage(:shex),
          outcome_predicate:
            {:all,
             [
               Evidence.stage(:shex, :ok),
               {:observed, "admission.stage",
                %{"stage" => "shacl", "outcome" => "refused", "code" => "shacl_nonconformant"}},
               {:not, Evidence.admitted()}
             ]}
        ),
        Falsifier.new!(
          id: "#{@id}-007",
          court_id: @id,
          kind: :positive_control,
          invariant: "A structurally valid world passes ShEx and is admitted: ShEx discriminates",
          stimulus: "AdmissionPipeline.admit/2 of the lawful Gate 2 world graph",
          boundary: "AshA2A.Semantic.AdmissionPipeline :shex stage",
          attempt_evidence: "admission.stage event for stage=shex attributed to this stimulus",
          survival_evidence:
            "admission.stage stage=shex outcome=ok and admission.stop outcome=admitted",
          rfc_sections: ["§45", "§100"],
          attempt_predicate: Evidence.stage(:shex),
          outcome_predicate: {:all, [Evidence.stage(:shex, :ok), Evidence.admitted()]}
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
          for {n, _name, _stimulus, vector} <- @negatives do
            f = Map.fetch!(by_id, "#{@id}-#{n}")
            candidate = World.candidate(graph_ttl: apply(World, vector, []))
            Evidence.stage_negative(ctx, f, candidate, scratch, :shex)
          end

        negatives ++
          [
            not_collapsed(ctx, Map.fetch!(by_id, "#{@id}-006"), scratch),
            valid_admitted(ctx, Map.fetch!(by_id, "#{@id}-007"), scratch)
          ]
    end
  end

  defp not_collapsed(ctx, f, scratch) do
    candidate = World.candidate(graph_ttl: World.shacl_do_without_receipt())
    {result, before, after_snapshot} = Evidence.admit(ctx, f, candidate, scratch)

    Result.positive(f,
      attempt_observed?: Evidence.stage_seen?(ctx, f, :shex),
      expected_outcome_observed?:
        Evidence.stage_seen?(ctx, f, :shex, :ok) and
          Evidence.seen?(ctx, f, "admission.stage", %{
            "stage" => "shacl",
            "outcome" => "refused",
            "code" => "shacl_nonconformant"
          }) and match?({:error, %{stage: :shacl}}, result) and
          Evidence.canonical_unchanged?(before, after_snapshot),
      evidence: Evidence.admission_evidence(result, before, after_snapshot)
    )
  end

  defp valid_admitted(ctx, f, scratch) do
    {result, before, after_snapshot} = Evidence.admit(ctx, f, World.candidate(), scratch)

    Result.positive(f,
      attempt_observed?: Evidence.stage_seen?(ctx, f, :shex),
      expected_outcome_observed?:
        Evidence.stage_seen?(ctx, f, :shex, :ok) and Evidence.admitted_seen?(ctx, f) and
          match?({:ok, %{standing: :admitted, authority: :none}}, result),
      evidence: Evidence.admission_evidence(result, before, after_snapshot)
    )
  end
end
