defmodule AshA2A.FiboSimulationConformanceTest do
  use ExUnit.Case, async: true
  import RDF.Sigils

  @canonical_dir Path.expand("../../priv/sa2a/canonical", __DIR__)

  test "canonical FIBO-grade SA2A ontologies parse cleanly as valid Turtle" do
    files = [
      "MetadataSA2A.ttl",
      "AboutSA2AProd.ttl",
      "FND/Agents/Agents.ttl",
      "FND/Agreements/Leases.ttl",
      "FND/Law/OperatingDoctrine.ttl",
      "CAP/CoreCapabilities.ttl",
      "BP/ExecutionEnvelopes.ttl",
      "EVI/Receipts.ttl",
      "shapes/sa2a_core_shapes.shacl.ttl"
    ]

    for file <- files do
      path = Path.join(@canonical_dir, file)
      assert File.exists?(path), "Expected file #{path} to exist"

      content = File.read!(path)
      assert {:ok, graph} = RDF.Turtle.read_string(content)
      assert RDF.Graph.triple_count(graph) > 0, "Graph in #{file} must not be empty"
    end
  end

  test "AboutSA2AProd references all canonical module IRIs via owl:imports" do
    prod_path = Path.join(@canonical_dir, "AboutSA2AProd.ttl")
    {:ok, graph} = RDF.Turtle.read_file(prod_path)

    owl_imports = ~I<http://www.w3.org/2002/07/owl#imports>
    imported_iris =
      RDF.Graph.descriptions(graph)
      |> Enum.flat_map(fn desc -> RDF.Description.get(desc, owl_imports, []) end)
      |> Enum.map(&to_string/1)

    expected = [
      "https://spec.seanchatmangpt.dev/sa2a/ontology/FND/Agents/Agents/",
      "https://spec.seanchatmangpt.dev/sa2a/ontology/FND/Agreements/Leases/",
      "https://spec.seanchatmangpt.dev/sa2a/ontology/FND/Law/OperatingDoctrine/",
      "https://spec.seanchatmangpt.dev/sa2a/ontology/CAP/CoreCapabilities/",
      "https://spec.seanchatmangpt.dev/sa2a/ontology/BP/ExecutionEnvelopes/",
      "https://spec.seanchatmangpt.dev/sa2a/ontology/EVI/Receipts/"
    ]

    for expected_iri <- expected do
      assert expected_iri in imported_iris, "Expected #{expected_iri} in owl:imports of AboutSA2AProd.ttl"
    end
  end

  test "OperatingDoctrine enforces fundamental explanation laws" do
    doc_path = Path.join(@canonical_dir, "FND/Law/OperatingDoctrine.ttl")
    {:ok, graph} = RDF.Turtle.read_file(doc_path)

    expected_laws = [
      ~I<https://spec.seanchatmangpt.dev/sa2a/ontology/FND/Law/OperatingDoctrine/SelectNotConstruct>,
      ~I<https://spec.seanchatmangpt.dev/sa2a/ontology/FND/Law/OperatingDoctrine/ConstructNotDo>,
      ~I<https://spec.seanchatmangpt.dev/sa2a/ontology/FND/Law/OperatingDoctrine/IntentNotAuthority>,
      ~I<https://spec.seanchatmangpt.dev/sa2a/ontology/FND/Law/OperatingDoctrine/ReceiptNotSuccess>
    ]

    law_class = ~I<https://spec.seanchatmangpt.dev/sa2a/ontology/FND/Law/OperatingDoctrine/DoctrineLaw>
    rdf_type = RDF.type()

    for law <- expected_laws do
      assert RDF.Graph.include?(graph, {law, rdf_type, law_class})
    end
  end
end
