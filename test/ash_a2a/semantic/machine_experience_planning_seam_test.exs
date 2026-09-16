defmodule AshA2A.Semantic.MachineExperiencePlanningSeamTest do
  @moduledoc """
  RFC S39/S65's compile-back, wired into this codebase's **existing**
  evidence-feedback seam rather than a parallel one.

  `ash_a2a` already carries `Receipt -> observation ->
  AshA2A.Semantic.PlanningIR.with_observation/2 -> re-synthesis with a
  `parent_fingerprint``. `AshA2A.Semantic.MachineExperience.record_in_planning_ir/2`
  feeds a compiled-back machinery observation through that same real
  function, so "class X now routes deterministically" enters the same
  observation stream as a runtime receipt does.

  The assertions below are on real state produced by the real
  `PlanningIR`: the real appended observation map and the real
  recomputed content-addressed fingerprint. Real `IR`, real `Ontology`,
  real `PlanningIR` -- no doubles anywhere.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Semantic.LlmBoundary
  alias AshA2A.Semantic.MachineExperience
  alias AshA2A.Semantic.{IR, Ontology, PlanningIR, Unknown}

  defp admitted_ir do
    %IR{
      source_id: "src-machine-experience",
      standing: :admitted,
      authority: :none,
      entities: [
        %{
          "id" => "e1",
          "kind" => "entity",
          "type" => "schema:Thing",
          "label" => "Shipment",
          "description" => "the shipment",
          "source_quote" => "the shipment"
        }
      ],
      relations: [],
      events: [],
      goals: [
        %{
          "id" => "g1",
          "kind" => "goal",
          "description" => "estimate the shipment eta",
          "source_quote" => "estimate the shipment eta"
        }
      ],
      constraints: [],
      capabilities: [],
      authorities: [],
      observations: [],
      uncertainties: [],
      exclusions: [],
      temporal_relations: [],
      causal_hypotheses: [],
      unresolved: []
    }
  end

  defp real_planning_ir do
    ir = admitted_ir()
    {:ok, ontology} = Ontology.from_ir(ir)
    {:ok, planning} = PlanningIR.from_ir(ir, ontology)
    planning
  end

  defp compiled_machinery do
    {:ok, resolution} =
      LlmBoundary.candidate(
        Unknown.declare("shipment-eta-estimate", %{"days" => 3}),
        :llm,
        %{"eta_hours" => 72}
      )

    {:ok, machinery} =
      MachineExperience.compile_back(resolution, :rule, fn %{"days" => d} -> {:ok, d * 24} end)

    {resolution, machinery}
  end

  test "a compile-back projects into the same observation shape runtime receipts use" do
    {resolution, machinery} = compiled_machinery()

    observation = MachineExperience.observation(machinery)

    assert observation["kind"] == "compiled_back_machinery"
    assert observation["class"] == "shipment-eta-estimate"
    assert observation["machinery_kind"] == "rule"
    assert observation["resolver"] == "llm"
    assert observation["resolution_fingerprint"] == resolution.fingerprint
    assert observation["machinery_fingerprint"] == machinery.fingerprint

    # Carries no standing and no authority -- it is evidence, not a claim.
    refute Map.has_key?(observation, "standing")
    refute Map.has_key?(observation, "authority")
  end

  test "record_in_planning_ir/2 appends through the real PlanningIR.with_observation/2 and moves its fingerprint" do
    planning = real_planning_ir()
    {_resolution, machinery} = compiled_machinery()

    assert planning.observations == []
    before_fingerprint = planning.fingerprint

    next = MachineExperience.record_in_planning_ir(planning, machinery)

    assert %PlanningIR{} = next
    assert length(next.observations) == 1
    assert hd(next.observations)["kind"] == "compiled_back_machinery"
    assert hd(next.observations)["class"] == "shipment-eta-estimate"

    # Real content-addressed change, recomputed by the real PlanningIR.
    refute next.fingerprint == before_fingerprint
    assert String.length(next.fingerprint) == 64

    # Standing and authority are untouched by feeding in evidence.
    assert next.standing == :admitted
    assert next.authority == :none
  end

  test "recording the same machinery twice is a real second observation, not an idempotent no-op" do
    planning = real_planning_ir()
    {_resolution, machinery} = compiled_machinery()

    once = MachineExperience.record_in_planning_ir(planning, machinery)
    twice = MachineExperience.record_in_planning_ir(once, machinery)

    assert length(twice.observations) == 2
    refute twice.fingerprint == once.fingerprint
  end
end
