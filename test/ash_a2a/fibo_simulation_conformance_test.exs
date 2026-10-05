# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

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

  test "live AshA2A.Command and Receipt structs align with canonical SHACL shape contracts" do
    alias AshA2A.{Command, Receipt}

    # 1. Instantiate real runtime command
    cmd = Command.new("test:capability:001",
      agent_id: "agent:worker:1",
      principal_id: "principal:admin:1",
      input: %{"target" => "system_update"}
    )

    assert is_binary(cmd.capability_id)
    assert is_binary(cmd.principal_id.value)
    assert is_binary(cmd.fingerprint)

    # 2. Project to canonical RDF Triples matching sa2a-bp:CommandEnvelope
    cmd_subject = RDF.iri("urn:uuid:#{cmd.command_id.value}")
    cmd_envelope_class = ~I<https://spec.seanchatmangpt.dev/sa2a/ontology/BP/ExecutionEnvelopes/CommandEnvelope>
    p_capability_id = ~I<https://spec.seanchatmangpt.dev/sa2a/ontology/BP/ExecutionEnvelopes/capabilityId>
    p_principal_id = ~I<https://spec.seanchatmangpt.dev/sa2a/ontology/BP/ExecutionEnvelopes/principalId>
    p_payload_digest = ~I<https://spec.seanchatmangpt.dev/sa2a/ontology/BP/ExecutionEnvelopes/payloadDigest>

    graph =
      RDF.Graph.new()
      |> RDF.Graph.add({cmd_subject, RDF.type(), cmd_envelope_class})
      |> RDF.Graph.add({cmd_subject, p_capability_id, RDF.literal(cmd.capability_id)})
      |> RDF.Graph.add({cmd_subject, p_principal_id, RDF.literal(cmd.principal_id.value)})
      |> RDF.Graph.add({cmd_subject, p_payload_digest, RDF.literal(cmd.fingerprint)})

    assert RDF.Graph.include?(graph, {cmd_subject, RDF.type(), cmd_envelope_class})
    assert RDF.Graph.include?(graph, {cmd_subject, p_capability_id, RDF.literal("test:capability:001")})

    # 3. Instantiate real runtime receipt and project to sa2a-evi:ActuationReceipt
    authority = AshA2A.Authority.new(cmd.principal_id, cmd.capability_id, source: :transport_verified)
    cmd_with_auth = %{cmd | authority: authority}
    exec_id = AshA2A.Identity.execution("exec:001")

    receipt = Receipt.from_reply(
      cmd_with_auth,
      exec_id,
      :observe,
      {:reply, :ok}
    )

    assert receipt.receipt_id != nil
    assert receipt.fingerprint != nil
    assert receipt.status == :completed
    assert receipt.terminal_status == :executed
    assert receipt.standing == :observed
  end

  test "monolithic canonical AllSA2A.ttl contains the entire consolidated ontology suite" do
    all_path = Path.join(@canonical_dir, "AllSA2A.ttl")
    assert File.exists?(all_path)

    {:ok, graph} = RDF.Turtle.read_file(all_path)
    assert RDF.Graph.triple_count(graph) >= 50

    # 1. Check classes from all domains
    rdf_type = RDF.type()
    owl_class = ~I<http://www.w3.org/2002/07/owl#Class>
    sh_nodeshape = ~I<http://www.w3.org/ns/shacl#NodeShape>

    expected_classes = [
      ~I<https://spec.seanchatmangpt.dev/sa2a/ontology/FND/Agents/Agents/AutonomousAgent>,
      ~I<https://spec.seanchatmangpt.dev/sa2a/ontology/FND/Agreements/Leases/AuthorityCeiling>,
      ~I<https://spec.seanchatmangpt.dev/sa2a/ontology/FND/Agreements/Leases/ActuationLease>,
      ~I<https://spec.seanchatmangpt.dev/sa2a/ontology/FND/Law/OperatingDoctrine/DoctrineLaw>,
      ~I<https://spec.seanchatmangpt.dev/sa2a/ontology/CAP/CoreCapabilities/Capability>,
      ~I<https://spec.seanchatmangpt.dev/sa2a/ontology/BP/ExecutionEnvelopes/CommandEnvelope>,
      ~I<https://spec.seanchatmangpt.dev/sa2a/ontology/EVI/Receipts/ActuationReceipt>
    ]

    for cls <- expected_classes do
      assert RDF.Graph.include?(graph, {cls, rdf_type, owl_class})
    end

    # 2. Check SHACL shapes
    expected_shapes = [
      ~I<https://spec.seanchatmangpt.dev/sa2a/shapes/core#CommandEnvelopeShape>,
      ~I<https://spec.seanchatmangpt.dev/sa2a/shapes/core#ActuationReceiptShape>
    ]

    for shape <- expected_shapes do
      assert RDF.Graph.include?(graph, {shape, rdf_type, sh_nodeshape})
    end

    # 3. Check OWL equivalence axioms
    owl_equivalent_class = ~I<http://www.w3.org/2002/07/owl#equivalentClass>
    a2a_urn_cmd = ~I<urn:ash-a2a:vocab:Command>
    sa2a_bp_cmd = ~I<https://spec.seanchatmangpt.dev/sa2a/ontology/BP/ExecutionEnvelopes/CommandEnvelope>

    assert RDF.Graph.include?(graph, {a2a_urn_cmd, owl_equivalent_class, sa2a_bp_cmd})
  end
end
