defmodule AshA2A.Semantic.IRTest do
  use ExUnit.Case, async: true

  alias AshA2A.Semantic.IR

  @all_fields ~w(entities relations events goals constraints capabilities authorities observations uncertainties exclusions temporal_relations causal_hypotheses unresolved)a

  describe "from_map/2" do
    test "happy path admits authority none and populated fields, defaulting the rest to []" do
      goal = %{"id" => "g1", "kind" => "goal", "source_quote" => "do the thing"}

      assert {:ok, %IR{} = ir} =
               IR.from_map("src-1", %{"goals" => [goal], "authority" => "none"})

      assert ir.source_id == "src-1"
      assert ir.standing == :candidate
      assert ir.authority == :none
      assert ir.goals == [goal]

      for field <- @all_fields, field != :goals do
        assert Map.fetch!(ir, field) == []
      end
    end

    test "authority other than the literal string \"none\" marks the struct :invalid" do
      assert {:ok, %IR{authority: :invalid}} =
               IR.from_map("src-2", %{"authority" => "granted"})
    end

    test "authority key entirely absent marks the struct :invalid" do
      assert {:ok, %IR{authority: :invalid}} = IR.from_map("src-3", %{})
    end

    test "a non-list field value is coerced to []" do
      assert {:ok, %IR{goals: []}} =
               IR.from_map("src-4", %{"goals" => "oops", "authority" => "none"})
    end

    test "returns an error tuple when given a non-map" do
      assert {:error, %{code: :invalid_semantic_ir, detail: "not a map"}} =
               IR.from_map("src-5", "not a map")
    end
  end

  describe "items/1" do
    test "returns [] for an empty IR" do
      {:ok, ir} = IR.from_map("src-6", %{})
      assert IR.items(ir) == []
    end

    test "flattens every populated field into {field, item} tuples in declared order" do
      entity = %{"id" => "e1", "kind" => "entity", "source_quote" => "an entity"}
      relation = %{"subject" => "e1", "predicate" => "rel", "object" => "e2"}
      goal = %{"id" => "g1", "kind" => "goal", "source_quote" => "goal quote"}
      unresolved = %{"id" => "u1", "kind" => "unresolved", "source_quote" => "?"}

      {:ok, ir} =
        IR.from_map("src-7", %{
          "entities" => [entity],
          "relations" => [relation],
          "goals" => [goal],
          "unresolved" => [unresolved],
          "authority" => "none"
        })

      assert IR.items(ir) == [
               {:entities, entity},
               {:relations, relation},
               {:goals, goal},
               {:unresolved, unresolved}
             ]
    end
  end

  describe "fields/0" do
    test "returns exactly the 13-atom declared field list, pinned against drift" do
      assert IR.fields() == [
               :entities,
               :relations,
               :events,
               :goals,
               :constraints,
               :capabilities,
               :authorities,
               :observations,
               :uncertainties,
               :exclusions,
               :temporal_relations,
               :causal_hypotheses,
               :unresolved
             ]

      assert length(IR.fields()) == 13
    end
  end
end
