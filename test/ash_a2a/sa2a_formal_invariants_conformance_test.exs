defmodule AshA2A.Sa2aFormalInvariantsConformanceTest do
  use ExUnit.Case, async: true
  import RDF.Sigils

  @canonical_dir Path.expand("../../priv/sa2a/canonical", __DIR__)

  test "sa2a-patch.ttl parses cleanly and contains all 4 formal invariants" do
    patch_path = Path.join(@canonical_dir, "sa2a-patch.ttl")
    assert File.exists?(patch_path)

    {:ok, graph} = RDF.Turtle.read_file(patch_path)
    assert RDF.Graph.triple_count(graph) >= 30

    # 1. Disjointness axioms
    owl_disjoint = ~I<http://www.w3.org/2002/07/owl#disjointWith>
    construct_cap = ~I<https://spec.seanchatmangpt.dev/sa2a/ontology/CAP/CoreCapabilities/ConstructCapability>
    do_cap = ~I<https://spec.seanchatmangpt.dev/sa2a/ontology/CAP/CoreCapabilities/DoCapability>

    assert RDF.Graph.include?(graph, {construct_cap, owl_disjoint, do_cap})

    cmd_envelope = ~I<https://spec.seanchatmangpt.dev/sa2a/ontology/BP/ExecutionEnvelopes/CommandEnvelope>
    act_receipt = ~I<https://spec.seanchatmangpt.dev/sa2a/ontology/EVI/Receipts/ActuationReceipt>

    assert RDF.Graph.include?(graph, {cmd_envelope, owl_disjoint, act_receipt})

    # 2. Standing enumeration individuals
    standing_class = ~I<https://spec.seanchatmangpt.dev/sa2a/ontology/EVI/Receipts/VerificationStanding>
    for standing <- [
          ~I<https://spec.seanchatmangpt.dev/sa2a/ontology/EVI/Receipts/StandingPass>,
          ~I<https://spec.seanchatmangpt.dev/sa2a/ontology/EVI/Receipts/StandingRefused>,
          ~I<https://spec.seanchatmangpt.dev/sa2a/ontology/EVI/Receipts/StandingBlocked>
        ] do
      assert RDF.Graph.include?(graph, {standing, RDF.type(), standing_class})
    end

    # 3. Cryptographic lease shape
    lease_shape = ~I<https://spec.seanchatmangpt.dev/sa2a/shapes/core#ActuationLeaseShape>
    sh_nodeshape = ~I<http://www.w3.org/ns/shacl#NodeShape>
    assert RDF.Graph.include?(graph, {lease_shape, RDF.type(), sh_nodeshape})

    # 4. Idempotency key shape
    idempotency_shape = ~I<https://spec.seanchatmangpt.dev/sa2a/shapes/core#CommandEnvelopeIdempotencyShape>
    assert RDF.Graph.include?(graph, {idempotency_shape, RDF.type(), sh_nodeshape})
  end

  test "AllSA2A.ttl contains the integrated patch invariants" do
    all_path = Path.join(@canonical_dir, "AllSA2A.ttl")
    {:ok, graph} = RDF.Turtle.read_file(all_path)

    owl_disjoint = ~I<http://www.w3.org/2002/07/owl#disjointWith>
    construct_cap = ~I<https://spec.seanchatmangpt.dev/sa2a/ontology/CAP/CoreCapabilities/ConstructCapability>
    do_cap = ~I<https://spec.seanchatmangpt.dev/sa2a/ontology/CAP/CoreCapabilities/DoCapability>

    assert RDF.Graph.include?(graph, {construct_cap, owl_disjoint, do_cap})

    cmd_envelope = ~I<https://spec.seanchatmangpt.dev/sa2a/ontology/BP/ExecutionEnvelopes/CommandEnvelope>
    act_receipt = ~I<https://spec.seanchatmangpt.dev/sa2a/ontology/EVI/Receipts/ActuationReceipt>

    assert RDF.Graph.include?(graph, {cmd_envelope, owl_disjoint, act_receipt})
  end

  test "runtime AshA2A.Json canonical encoding supports all formal invariant fields" do
    alias AshA2A.{Authority, Command, Json, Receipt}

    cmd = Command.new("cap:system:eval",
      agent_id: "agent:001",
      principal_id: "principal:001",
      input: %{"mode" => "strict"}
    )

    authority = Authority.new(cmd.principal_id, cmd.capability_id, source: :transport_verified)
    cmd_with_auth = %{cmd | authority: authority}
    exec_id = AshA2A.Identity.execution("exec:001")

    receipt = Receipt.from_reply(
      cmd_with_auth,
      exec_id,
      :observe,
      {:reply, :ok}
    )

    receipt_map =
      receipt
      |> Map.from_struct()
      |> Map.take([:receipt_id, :fingerprint, :status, :terminal_status, :standing])
      |> Map.new(fn
        {k, %AshA2A.Identity{value: v}} -> {Atom.to_string(k), to_string(v)}
        {k, v} -> {Atom.to_string(k), to_string(v)}
      end)

    json_output = Json.canonical(receipt_map)
    assert is_binary(json_output)
    {:ok, decoded} = Jason.decode(json_output)

    # Validate essential fields required by SHACL shapes
    assert is_binary(decoded["receipt_id"])
    assert is_binary(decoded["fingerprint"])
    assert decoded["status"] == "completed"
    assert decoded["terminal_status"] == "executed"
  end
end
