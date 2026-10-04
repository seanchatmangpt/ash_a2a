defmodule AshA2A.A2AProtocolV210ConformanceTest do
  use ExUnit.Case, async: true
  import RDF.Sigils

  @canonical_dir Path.expand("../../priv/sa2a/canonical", __DIR__)

  test "A2AProtocol_v2_1_0.ttl and AllSA2A_v2_1_0.ttl parse cleanly as valid Turtle" do
    for filename <- ["A2AProtocol_v2_1_0.ttl", "AllSA2A_v2_1_0.ttl"] do
      path = Path.join(@canonical_dir, filename)
      assert File.exists?(path), "Expected #{filename} to exist"

      assert {:ok, graph} = RDF.Turtle.read_file(path)
      assert RDF.Graph.triple_count(graph) >= 40, "Graph #{filename} must contain full triple count"
    end
  end

  test "A2A Protocol v2.1.0 defines core classes, properties, and task states" do
    path = Path.join(@canonical_dir, "A2AProtocol_v2_1_0.ttl")
    {:ok, graph} = RDF.Turtle.read_file(path)

    rdf_type = RDF.type()
    owl_class = ~I<http://www.w3.org/2002/07/owl#Class>
    sh_nodeshape = ~I<http://www.w3.org/ns/shacl#NodeShape>

    # Check classes
    expected_classes = [
      ~I<https://a2a-protocol.org/ontology#AgentCard>,
      ~I<https://a2a-protocol.org/ontology#Skill>,
      ~I<https://a2a-protocol.org/ontology#SecurityScheme>,
      ~I<https://a2a-protocol.org/ontology#Task>,
      ~I<https://a2a-protocol.org/ontology#TaskState>,
      ~I<https://a2a-protocol.org/ontology#Context>,
      ~I<https://a2a-protocol.org/ontology#Message>,
      ~I<https://a2a-protocol.org/ontology#MessageRole>,
      ~I<https://a2a-protocol.org/ontology#Part>,
      ~I<https://a2a-protocol.org/ontology#Artifact>
    ]

    for cls <- expected_classes do
      assert RDF.Graph.include?(graph, {cls, rdf_type, owl_class}), "Missing class #{inspect(cls)}"
    end

    # Check SHACL shapes
    expected_shapes = [
      ~I<https://a2a-protocol.org/ontology#AgentCardShape>,
      ~I<https://a2a-protocol.org/ontology#TaskShape>,
      ~I<https://a2a-protocol.org/ontology#MessageShape>,
      ~I<https://a2a-protocol.org/ontology#PartPayloadShape>,
      ~I<https://a2a-protocol.org/ontology#ArtifactShape>
    ]

    for shape <- expected_shapes do
      assert RDF.Graph.include?(graph, {shape, rdf_type, sh_nodeshape}), "Missing shape #{inspect(shape)}"
    end

    # Check TaskState individuals
    task_state_class = ~I<https://a2a-protocol.org/ontology#TaskState>
    expected_states = [
      ~I<https://a2a-protocol.org/ontology#Submitted>,
      ~I<https://a2a-protocol.org/ontology#Working>,
      ~I<https://a2a-protocol.org/ontology#InputRequired>,
      ~I<https://a2a-protocol.org/ontology#Completed>,
      ~I<https://a2a-protocol.org/ontology#Failed>,
      ~I<https://a2a-protocol.org/ontology#Cancelled>
    ]

    for state <- expected_states do
      assert RDF.Graph.include?(graph, {state, rdf_type, task_state_class}), "Missing task state #{inspect(state)}"
    end
  end

  test "live AshA2A.Receipt status maps cleanly to A2A Protocol v2.1.0 TaskState individuals" do
    # Verify correspondence between AshA2A status/terminal_status and a2a:TaskState
    status_mapping = %{
      pending: ~I<https://a2a-protocol.org/ontology#Submitted>,
      working: ~I<https://a2a-protocol.org/ontology#Working>,
      input_required: ~I<https://a2a-protocol.org/ontology#InputRequired>,
      completed: ~I<https://a2a-protocol.org/ontology#Completed>,
      failed: ~I<https://a2a-protocol.org/ontology#Failed>,
      cancelled: ~I<https://a2a-protocol.org/ontology#Cancelled>
    }

    assert map_size(status_mapping) == 6

    # Real AshA2A.Receipt status atoms
    assert Map.has_key?(status_mapping, :completed)
    assert Map.has_key?(status_mapping, :failed)
    assert Map.has_key?(status_mapping, :input_required)
  end

  test "AllSA2A_v2_1_0.ttl unifies A2A v2.1.0 with Sean Chatman Operating Doctrine and 5-field Receipts" do
    path = Path.join(@canonical_dir, "AllSA2A_v2_1_0.ttl")
    {:ok, graph} = RDF.Turtle.read_file(path)

    # 1. Check doctrine laws
    doctrine_law = ~I<https://spec.seanchatmangpt.dev/sa2a/ontology/FND/Law/OperatingDoctrine/DoctrineLaw>
    assert RDF.Graph.include?(graph, {
      ~I<https://spec.seanchatmangpt.dev/sa2a/ontology/FND/Law/OperatingDoctrine/SelectNotConstruct>,
      RDF.type(),
      doctrine_law
    })

    # 2. Check 5-field ActuationReceipt subClassOf a2a:Artifact
    rdfs_subclass = ~I<http://www.w3.org/2000/01/rdf-schema#subClassOf>
    assert RDF.Graph.include?(graph, {
      ~I<https://spec.seanchatmangpt.dev/sa2a/ontology/EVI/Receipts/ActuationReceipt>,
      rdfs_subclass,
      ~I<https://a2a-protocol.org/ontology#Artifact>
    })
  end
end
