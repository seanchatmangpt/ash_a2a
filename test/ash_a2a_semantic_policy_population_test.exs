defmodule AshA2A.Semantic.PolicyPopulationTest do
  use ExUnit.Case, async: true

  alias AshA2A.Semantic.PolicyPhenotype
  alias AshA2A.Semantic.PolicyPopulation
  alias AshA2A.Semantic.Refusal

  defp phenotype(value, opts \ []) do
    reaction_norms =
      if Keyword.get(opts, :adaptive, false),
        do: %{"exploration" => %{slope: 0.5, reference_cue: 0.0}},
        else: %{}

    assert {:ok, phenotype} =
             PolicyPhenotype.new(
               capability_iri: "urn:sa2a:capability:Example.Search.read",
               policy_family: "planner:Astar",
               conditionable_axes: %{"exploration" => %{min: 0.0, max: 1.0}},
               condition: %{"exploration" => value},
               reaction_norms: reaction_norms,
               evidence_refs: ["urn:evidence:paper"]
             )

    phenotype
  end

  test "engineered population separates disparity from effective complexity" do
    assert {:ok, population} =
             PolicyPopulation.new(
               :engineered,
               [
                 {phenotype(0.0), 1.0},
                 {phenotype(1.0), 1.0}
               ]
             )

    assert PolicyPopulation.diversity(population).disparity == 1.0
    assert PolicyPopulation.diversity(population).complexity == 2.0
    refute PolicyPopulation.grant?(population)
    assert PolicyPopulation.standing(population) == :candidate
    assert PolicyPopulation.actuation_boundary() == :external_command_bus_brce
  end

  test "weighted complexity is inverse Simpson effective member count" do
    assert {:ok, population} =
             PolicyPopulation.new(
               :engineered,
               [
                 {phenotype(0.0), 1.0},
                 {phenotype(0.5), 1.0},
                 {phenotype(1.0), 2.0}
               ]
             )

    assert PolicyPopulation.normalized_weights(population) == [0.25, 0.25, 0.5]
    assert_in_delta PolicyPopulation.diversity(population).complexity, 8.0 / 3.0, 1.0e-12
  end

  test "homogeneous population refuses multiple phenotypes" do
    assert {:error, %{code: :homogeneous_population_requires_one_phenotype}} =
             PolicyPopulation.new(
               :homogeneous,
               [{phenotype(0.25), 1.0}, {phenotype(0.75), 1.0}]
             )
  end

  test "adaptive population requires reaction norms on every member" do
    assert {:error, %{code: :adaptive_population_requires_reaction_norm}} =
             PolicyPopulation.new(:adaptive, [{phenotype(0.25), 1.0}])

    assert {:ok, _population} =
             PolicyPopulation.new(
               :adaptive,
               [{phenotype(0.25, adaptive: true), 1.0}]
             )
  end

  test "adaptive population conditions every member without changing weights" do
    assert {:ok, population} =
             PolicyPopulation.new(
               :adaptive,
               [
                 {phenotype(0.25, adaptive: true), 1.0},
                 {phenotype(0.5, adaptive: true), 2.0}
               ]
             )

    assert {:ok, conditioned} = PolicyPopulation.condition(population, 1.0)

    assert Enum.map(conditioned.members, & &1.weight) == [1.0, 2.0]

    assert Enum.map(
             conditioned.members,
             & &1.phenotype.condition["exploration"]
           ) == [0.75, 1.0]
  end

  test "canonical population transport round-trips with member digests" do
    assert {:ok, population} =
             PolicyPopulation.new(
               :engineered,
               [{phenotype(0.1), 1.0}, {phenotype(0.9), 3.0}],
               evidence_refs: ["urn:evidence:population-design"]
             )

    map = PolicyPopulation.to_map(population)
    digest = PolicyPopulation.digest(population)

    assert {:ok, decoded} = PolicyPopulation.from_map(map, digest)
    assert decoded == population
    assert PolicyPopulation.digest(decoded) == digest

    assert Enum.all?(map["members"], fn member ->
             is_binary(member["phenotype_digest"])
           end)
  end

  test "population transport cannot grant authority" do
    assert {:ok, population} =
             PolicyPopulation.new(:engineered, [{phenotype(0.5), 1.0}])

    map =
      population
      |> PolicyPopulation.to_map()
      |> Map.put("credential", "secret")

    assert {:error, %{code: :population_authority_smuggling}} =
             PolicyPopulation.from_map(map)

    assert Refusal.classify(:population_authority_smuggling) == :refused_authority
  end

  test "tampered population digest is refused as identity mismatch" do
    assert {:ok, population} =
             PolicyPopulation.new(:engineered, [{phenotype(0.5), 1.0}])

    assert {:error, %{code: :policy_population_digest_mismatch}} =
             PolicyPopulation.from_map(PolicyPopulation.to_map(population), "sha256:no")

    assert Refusal.classify(:policy_population_digest_mismatch) == :refused_identity
  end
end
