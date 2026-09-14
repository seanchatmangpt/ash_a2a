defmodule AshA2A.Semantic.PlanningIRTest do
  use ExUnit.Case, async: true

  alias AshA2A.Semantic.{IR, Ontology, PlanningIR}

  defp admitted_ir do
    %IR{
      source_id: "src-1",
      standing: :admitted,
      authority: :none,
      entities: [
        %{
          "id" => "e1",
          "kind" => "entity",
          "type" => "schema:Person",
          "label" => "Leader",
          "description" => "the leader entity",
          "source_quote" => "the leader"
        }
      ],
      relations: [
        %{
          "id" => "r1",
          "kind" => "relation",
          "subject" => "e1",
          "predicate" => "schema:role",
          "object" => "leader",
          "description" => "e1 has role leader",
          "source_quote" => "leads"
        }
      ],
      events: [],
      goals: [
        %{
          "id" => "g1",
          "kind" => "goal",
          "description" => "lead the people",
          "source_quote" => "lead the people"
        }
      ],
      constraints: [
        %{
          "id" => "c1",
          "kind" => "constraint",
          "description" => "must remain accountable",
          "source_quote" => "accountable"
        }
      ],
      capabilities: [
        %{
          "id" => "cap1",
          "kind" => "capability",
          "description" => "can organize people",
          "source_quote" => "organize"
        }
      ],
      authorities: [],
      observations: [
        %{
          "id" => "o1",
          "kind" => "observation",
          "description" => "people gathered",
          "source_quote" => "gathered"
        }
      ],
      uncertainties: [
        %{
          "id" => "u1",
          "kind" => "uncertainty",
          "description" => "outcome unclear",
          "source_quote" => "unclear"
        }
      ],
      exclusions: [
        %{
          "id" => "ex1",
          "kind" => "exclusion",
          "description" => "no coercion",
          "source_quote" => "no coercion"
        }
      ],
      temporal_relations: [],
      causal_hypotheses: [],
      unresolved: []
    }
  end

  defp admitted_ontology(ir) do
    {:ok, ontology} = Ontology.from_ir(ir)
    ontology
  end

  test "from_ir/2 projects each IR field via the documented Map.fetch!/Map.take shape" do
    ir = admitted_ir()
    ontology = admitted_ontology(ir)

    assert {:ok, planning} = PlanningIR.from_ir(ir, ontology)

    assert planning.goals == ["lead the people"]
    assert planning.objects == [%{"id" => "e1", "type" => "schema:Person", "label" => "Leader"}]

    assert planning.predicates == [
             %{"subject" => "e1", "predicate" => "schema:role", "object" => "leader"}
           ]

    assert planning.constraints == ["must remain accountable"]
    assert planning.task_candidates == ["can organize people"]
    assert planning.nondeterminism == ["outcome unclear"]
    assert planning.observations == ["people gathered"]
    assert planning.exclusions == ["no coercion"]

    assert planning.ontology_fingerprint == ontology.fingerprint

    assert is_binary(planning.fingerprint)
    assert String.length(planning.fingerprint) == 64
    assert planning.fingerprint =~ ~r/^[0-9a-f]{64}$/
  end

  test "from_ir/2 is deterministic for identical admitted input" do
    ir = admitted_ir()
    ontology = admitted_ontology(ir)

    {:ok, planning_a} = PlanningIR.from_ir(ir, ontology)
    {:ok, planning_b} = PlanningIR.from_ir(ir, ontology)

    assert planning_a.fingerprint == planning_b.fingerprint
  end

  test "from_ir/2 refuses a non-admitted IR" do
    ir = %{admitted_ir() | standing: :candidate}
    ontology = admitted_ontology(admitted_ir())

    assert PlanningIR.from_ir(ir, ontology) ==
             {:error, %{code: :planning_ir_requires_admitted_semantics}}
  end

  test "primary_goal/1 returns the first goal string on the happy path" do
    ir = admitted_ir()
    ontology = admitted_ontology(ir)
    {:ok, planning} = PlanningIR.from_ir(ir, ontology)

    assert PlanningIR.primary_goal(planning) == "lead the people"
  end

  test "primary_goal/1 raises FunctionClauseError on an empty goals list" do
    empty_planning = %PlanningIR{
      ontology_fingerprint: "fp",
      goals: [],
      objects: [],
      predicates: [],
      fingerprint: "fp"
    }

    assert_raise FunctionClauseError, fn -> apply(PlanningIR, :primary_goal, [empty_planning]) end
  end

  test "observation/1 returns a string-keyed map without the fingerprint key" do
    ir = admitted_ir()
    ontology = admitted_ontology(ir)
    {:ok, planning} = PlanningIR.from_ir(ir, ontology)

    observation = PlanningIR.observation(planning)

    assert is_map(observation)
    refute Map.has_key?(observation, "fingerprint")
    refute Map.has_key?(observation, :fingerprint)

    assert Enum.all?(Map.keys(observation), &is_binary/1)
    assert observation["goals"] == ["lead the people"]
  end

  test "with_observation/2 appends the observation and changes the fingerprint" do
    ir = admitted_ir()
    ontology = admitted_ontology(ir)
    {:ok, planning} = PlanningIR.from_ir(ir, ontology)

    new_observation = %{"kind" => "runtime_receipt", "status" => "ok"}
    next = PlanningIR.with_observation(planning, new_observation)

    assert List.last(next.observations) == new_observation
    assert next.observations == planning.observations ++ [new_observation]
    assert next.fingerprint != planning.fingerprint
  end
end
