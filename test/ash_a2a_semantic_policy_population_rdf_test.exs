defmodule AshA2A.Semantic.PolicyPopulationRDFTest do
  use ExUnit.Case, async: true

  alias AshA2A.Semantic.PolicyPhenotype
  alias AshA2A.Semantic.PolicyPopulation
  alias AshA2A.Semantic.PolicyPopulationRDF
  alias AshA2A.Semantic.Serialize

  defp population do
    assert {:ok, first} =
             PolicyPhenotype.new(
               capability_iri: "urn:sa2a:capability:Example.Search.read",
               policy_family: "planner:Astar",
               conditionable_axes: %{
                 "exploration" => %{min: 0.0, max: 1.0},
                 "initiative" => %{min: 0.0, max: 1.0}
               },
               condition: %{"exploration" => 0.1, "initiative" => 0.9},
               evidence_refs: ["urn:evidence:paper"]
             )

    assert {:ok, second} =
             PolicyPhenotype.new(
               capability_iri: "urn:sa2a:capability:Example.Search.read",
               policy_family: "planner:Astar",
               conditionable_axes: %{
                 "exploration" => %{min: 0.0, max: 1.0},
                 "initiative" => %{min: 0.0, max: 1.0}
               },
               condition: %{"exploration" => 0.9, "initiative" => 0.1},
               evidence_refs: ["urn:evidence:paper"]
             )

    assert {:ok, population} =
             PolicyPopulation.new(
               :engineered,
               [{first, 1.0}, {second, 2.0}],
               evidence_refs: ["https://arxiv.org/abs/2609.29423"]
             )

    population
  end

  test "public RDF projection independently parse-back verifies" do
    source = population()
    triples = PolicyPopulationRDF.to_triples(source)

    assert :ok = PolicyPopulationRDF.verify_public_vocabulary(triples)
    assert {:ok, ntriples} = Serialize.to_ntriples(triples)
    assert {:ok, count} = Serialize.verify(triples, ntriples, format: :ntriples)
    assert count > 0

    assert {:ok, decoded} =
             PolicyPopulationRDF.from_triples(
               triples,
               PolicyPopulation.digest(source)
             )

    assert decoded == source
  end

  test "Turtle is emitted only after the real RDF.ex parse-back gate" do
    assert {:ok, turtle} = PolicyPopulationRDF.to_turtle(population())
    assert turtle =~ "policy_population"
    assert turtle =~ "policy_phenotype"
    assert turtle =~ "temperament_measurement"
  end

  test "projection uses no SA2A-private RDF predicate or class" do
    triples = PolicyPopulationRDF.to_triples(population())

    refute Enum.any?(triples, fn triple ->
             String.starts_with?(to_string(triple.predicate), "urn:sa2a:")
           end)

    refute Enum.any?(triples, fn
             %{
               predicate: "http://www.w3.org/1999/02/22-rdf-syntax-ns#type",
               object: {:iri, "urn:sa2a:" <> _}
             } ->
               true

             _ ->
               false
           end)
  end

  test "tampered population root identity is refused" do
    triples = PolicyPopulationRDF.to_triples(population())
    root = PolicyPopulationRDF.population_iri(population())

    tampered =
      Enum.map(triples, fn triple ->
        if triple.subject == root,
          do: %{triple | subject: "urn:sa2a:policy-population:tampered"},
          else: triple
      end)

    assert {:error, %{code: :policy_population_rdf_identity_mismatch}} =
             PolicyPopulationRDF.from_triples(tampered)
  end

  test "custom predicate is refused even when lossless value remains intact" do
    source = population()
    triples =
      PolicyPopulationRDF.to_triples(source) ++
        [
          %{
            subject: PolicyPopulationRDF.population_iri(source),
            predicate: "urn:sa2a:privatePredicate",
            object: {:literal, "no"}
          }
        ]

    assert {:error, %{code: :policy_population_custom_rdf_predicate}} =
             PolicyPopulationRDF.from_triples(triples)
  end
end
