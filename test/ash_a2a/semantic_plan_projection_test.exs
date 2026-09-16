defmodule AshA2A.Semantic.PlanProjectionTest do
  @moduledoc """
  RFC-SA2A-001 S23 (the planning projection is derived; the graph stays
  authoritative) and S27 (a projection must not become a second source of
  semantic truth).

  Chicago style throughout: every IR here was admitted by the **real**
  `AshA2A.Semantic.Admission.admit/2` (see `AshA2A.Test.SA2APlanFixture`),
  every ontology by the real `Ontology.from_ir/1`, and every assertion is on
  real returned state (digests, refusal tuples) rather than on whether some
  function was called.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Semantic.{IR, Ontology, PlanningIR, PlanProjection}
  alias AshA2A.Test.SA2APlanFixture, as: Fixture

  describe "S23 -- the projection is derived from admitted objects only" do
    test "from_admitted/2 binds the projection to the real admitted graph's digest" do
      {projection, ontology} = Fixture.projection()

      assert projection.standing == :derived
      assert projection.authority == :none
      assert projection.source_graph_digest == ontology.fingerprint
      assert projection.planning_ir_fingerprint == Fixture.planning_ir().fingerprint
      assert projection.source_id == ontology.source_id

      # The projected content is the admitted planning IR's content, not a
      # re-derivation: a second source of truth is exactly what S27 forbids.
      planning = Fixture.planning_ir()
      assert projection.goals == planning.goals
      assert projection.objects == planning.objects
      assert projection.predicates == planning.predicates
      assert projection.constraints == planning.constraints
      assert projection.task_candidates == planning.task_candidates
      assert projection.nondeterminism == planning.nondeterminism
      assert projection.exclusions == planning.exclusions
    end

    test "the projection digest is a value-level digest, stable across runs" do
      {a, _ontology} = Fixture.projection()
      {b, _ontology} = Fixture.projection()

      assert a.projection_digest == b.projection_digest
      assert a.projection_digest =~ ~r/\Asha256:[0-9a-f]{64}\z/
    end

    test "a non-admitted ontology is refused" do
      planning = Fixture.planning_ir()
      candidate_ontology = %{Fixture.ontology() | standing: :candidate}

      assert {:error, %{code: :projection_requires_admitted_graph}} =
               PlanProjection.from_admitted(planning, candidate_ontology)
    end

    test "a planning IR carrying any authority at all is refused by the fence" do
      planning = %{Fixture.planning_ir() | authority: :granted}

      assert {:error, %{code: :projection_authority_ceiling_violated, detail: :granted}} =
               PlanProjection.from_admitted(planning, Fixture.ontology())
    end

    test "a planning IR cannot be stapled onto an unrelated graph" do
      # Real second graph: a genuinely different admitted IR produces a
      # genuinely different real ontology fingerprint.
      other_ir = %IR{
        Fixture.admitted_ir()
        | goals: [
            %{
              "id" => "goal-close",
              "kind" => "goal",
              "description" => "a completely different goal",
              "source_quote" => "advance the room through every"
            }
          ]
      }

      {:ok, other_ontology} = Ontology.from_ir(other_ir)
      refute other_ontology.fingerprint == Fixture.ontology().fingerprint

      assert {:error, %{code: :projection_ontology_mismatch, detail: detail}} =
               PlanProjection.from_admitted(Fixture.planning_ir(), other_ontology)

      assert detail.planning_ir_expects == Fixture.ontology().fingerprint
      assert detail.ontology_is == other_ontology.fingerprint
    end

    test "PlanningIR.from_ir/2 itself still refuses a genuinely candidate IR" do
      # The upstream gate S23 depends on: the fixture's candidate_ir/0 has
      # never been through Admission.admit/2.
      candidate = Fixture.candidate_ir()
      assert candidate.standing == :candidate

      assert {:error, %{code: :planning_ir_requires_admitted_semantics}} =
               PlanningIR.from_ir(candidate, Fixture.ontology())
    end
  end

  describe "S27 -- a projection must not become a second source of semantic truth" do
    test "verify/2 admits an untouched projection against its own graph" do
      {projection, ontology} = Fixture.projection()
      assert {:ok, ^projection} = PlanProjection.verify(projection, ontology)
    end

    test "a manually edited projection is REFUSED, never promoted to canonical" do
      {projection, ontology} = Fixture.projection()

      # The literal S27 case: somebody hand-edits the projection's content.
      edited = %{projection | goals: ["a goal nobody admitted"]}

      assert {:error, %{code: :projection_manual_edit_not_canonical, detail: detail}} =
               PlanProjection.verify(edited, ontology)

      assert detail.recorded == projection.projection_digest
      assert detail.recomputed != detail.recorded

      # And there is deliberately no way to promote it: the module exposes no
      # promote/commit/adopt function that would make the edit canonical.
      exported = PlanProjection.__info__(:functions) |> Keyword.keys() |> Enum.uniq()
      refute :promote in exported
      refute :commit in exported
      refute :adopt in exported
    end

    test "editing a projection's recorded source digest does not launder it" do
      {projection, ontology} = Fixture.projection()
      forged = %{projection | source_graph_digest: "sha256:" <> String.duplicate("0", 64)}

      # Tamper check runs FIRST, so the forgery surfaces as an edit, not as a
      # plausible-looking drift.
      assert {:error, %{code: :projection_manual_edit_not_canonical}} =
               PlanProjection.verify(forged, ontology)
    end

    test "source drift against a real different graph is refused" do
      {projection, _ontology} = Fixture.projection()

      moved_ir = %IR{
        Fixture.admitted_ir()
        | observations: [
            %{
              "id" => "obs-open",
              "kind" => "observation",
              "description" => "the graph moved on after this projection was taken",
              "source_quote" => "The room starts at the open phase"
            }
          ]
      }

      {:ok, moved_ontology} = Ontology.from_ir(moved_ir)
      refute moved_ontology.fingerprint == projection.source_graph_digest

      assert {:error, %{code: :projection_source_drift, detail: detail}} =
               PlanProjection.verify(projection, moved_ontology)

      assert detail.recorded == projection.source_graph_digest
      assert detail.current == moved_ontology.fingerprint
    end

    test "verify_self/1 catches an edit with no graph in hand" do
      {projection, _ontology} = Fixture.projection()

      assert {:ok, ^projection} = PlanProjection.verify_self(projection)

      assert {:error, %{code: :projection_manual_edit_not_canonical}} =
               PlanProjection.verify_self(%{projection | task_candidates: ["forged"]})
    end

    test "re-projecting from the moved graph is the only lawful way to change it" do
      {stale, _ontology} = Fixture.projection()

      moved_ir = %IR{
        Fixture.admitted_ir()
        | constraints: [
            %{
              "id" => "constraint-order",
              "kind" => "constraint",
              "description" => "phases must be advanced in order, strictly",
              "source_quote" => "in order"
            }
          ]
      }

      {:ok, moved_ontology} = Ontology.from_ir(moved_ir)
      {:ok, moved_planning} = PlanningIR.from_ir(moved_ir, moved_ontology)
      {:ok, fresh} = PlanProjection.from_admitted(moved_planning, moved_ontology)

      # The stale projection is refused against the moved graph...
      assert {:error, %{code: :projection_source_drift}} =
               PlanProjection.verify(stale, moved_ontology)

      # ...and the re-projection is admitted, carries the moved content, and
      # has a different digest.
      assert {:ok, ^fresh} = PlanProjection.verify(fresh, moved_ontology)
      assert fresh.constraints == ["phases must be advanced in order, strictly"]
      refute fresh.projection_digest == stale.projection_digest
    end
  end
end
