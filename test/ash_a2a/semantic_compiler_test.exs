defmodule AshA2A.Semantic.CompilerTest do
  use ExUnit.Case, async: true

  alias AshA2A.Semantic.{Compiler, IR}
  alias AshA2A.Test.Fixture.Echo

  test "compiles text through ontology and HDDL/FOND candidate without DO" do
    extract = fn _, _, _, _ -> {:ok, extraction()} end

    plan = fn _, _, _, _ ->
      {:ok,
       %{
         "request_id" => "semantic-plan-1",
         "authority" => "none",
         "capability_ids" => ["AshA2A.Test.Fixture.Echo.read"],
         "hddl" => "(:task lead)",
         "fond" => "(:policy observe-or-replan)"
       }}
    end

    assert {:ok, package} =
             Compiler.compile(Echo, "The goal is to lead the people.",
               generate_object: extract,
               plan_generate_object: plan
             )

    assert package.semantic_ir.standing == :admitted
    assert package.ontology.standing == :admitted
    assert package.planning_ir.standing == :admitted
    assert package.plan_candidate.formalism == :hddl_fond
    assert package.authority == :none
  end

  defp extraction do
    IR.fields()
    |> Map.new(&{Atom.to_string(&1), []})
    |> Map.put("authority", "none")
    |> Map.put("goals", [
      %{"id" => "lead", "kind" => "goal", "description" => "lead the people", "source_quote" => "The goal is to lead the people."}
    ])
  end
end
