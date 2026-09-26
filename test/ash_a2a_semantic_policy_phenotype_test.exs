defmodule AshA2A.Semantic.PolicyPhenotypeTest do
  use ExUnit.Case, async: true

  alias AshA2A.Semantic.PolicyPhenotype

  test "same capability can expose distinct behavioral phenotypes without becoming distinct grants" do
    common = [
      capability_iri: "urn:sa2a:capability:Example.Search.read",
      policy_family: "planner:Astar",
      conditionable_axes: %{
        "exploration" => %{min: 0.0, max: 1.0},
        "initiative" => %{min: 0.0, max: 1.0}
      }
    ]

    assert {:ok, conservative} =
             PolicyPhenotype.new(
               common ++ [condition: %{"exploration" => 0.1, "initiative" => 0.2}]
             )

    assert {:ok, exploratory} =
             PolicyPhenotype.new(
               common ++ [condition: %{"exploration" => 0.9, "initiative" => 0.8}]
             )

    assert conservative.capability_iri == exploratory.capability_iri
    assert conservative.policy_family == exploratory.policy_family
    refute conservative.condition == exploratory.condition
    refute PolicyPhenotype.grant?(conservative)
    refute PolicyPhenotype.grant?(exploratory)
    assert PolicyPhenotype.actuation_boundary() == :external_command_bus_brce
  end

  test "reaction norm changes only behavioral condition and clamps it to declared bounds" do
    assert {:ok, phenotype} =
             PolicyPhenotype.new(
               capability_iri: "urn:sa2a:capability:Example.Search.read",
               policy_family: "planner:MCTS",
               conditionable_axes: %{
                 "exploration" => %{min: 0.0, max: 1.0},
                 "initiative" => %{min: 0.0, max: 0.75}
               },
               condition: %{"exploration" => 0.25, "initiative" => 0.4},
               reaction_norms: %{
                 "exploration" => %{slope: 0.75, reference_cue: 0.0},
                 "initiative" => %{slope: 1.0, reference_cue: 0.0}
               },
               evidence_refs: ["urn:evidence:temperament-engineering"]
             )

    assert {:ok, conditioned} = PolicyPhenotype.condition(phenotype, 1.0)

    assert conditioned.capability_iri == phenotype.capability_iri
    assert conditioned.policy_family == phenotype.policy_family
    assert conditioned.evidence_refs == phenotype.evidence_refs
    assert conditioned.condition == %{"exploration" => 1.0, "initiative" => 0.75}
    refute PolicyPhenotype.grant?(conditioned)
  end

  test "authority-like axes are refused before they can become phenotype state" do
    for axis <- ~w(authority permission execution_grant execution_authority do) do
      assert {:error,
              %{code: :temperament_cannot_encode_authority, detail: ^axis}} =
               PolicyPhenotype.new(
                 capability_iri: "urn:sa2a:capability:Example.Search.read",
                 policy_family: "planner:Astar",
                 conditionable_axes: %{axis => %{min: 0.0, max: 1.0}},
                 condition: %{axis => 1.0}
               )
    end
  end

  test "reaction norm cannot name an undeclared behavioral axis" do
    assert {:error, %{code: :unknown_condition_axis, detail: "sociability"}} =
             PolicyPhenotype.new(
               capability_iri: "urn:sa2a:capability:Example.Search.read",
               policy_family: "planner:Astar",
               conditionable_axes: %{"exploration" => %{min: 0.0, max: 1.0}},
               reaction_norms: %{"sociability" => %{slope: 0.5}}
             )
  end

  test "default vocabulary is behavioral and contains no authority axis" do
    axes = PolicyPhenotype.default_axes()

    assert "initiative" in axes
    assert "expressiveness" in axes
    refute "authority" in axes
    refute "permission" in axes
    refute "execution_grant" in axes
  end
end
