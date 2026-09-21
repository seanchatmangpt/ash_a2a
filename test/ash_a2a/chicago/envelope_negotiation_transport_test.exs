defmodule AshA2A.Chicago.EnvelopeNegotiationTransportTest do
  @moduledoc """
  RFC-SA2A-002 §54/§55/§56/§75 courts, end to end: a real
  `AshA2A.Chicago.Runner` run over the real `SA2A-ENV`, `SA2A-NEG` and
  `SA2A-TRANSPORT` courts (real Peer in real A2A.Agent GenServers, real
  praxis-graphlaw wasm, real A2A.Plug on a real Bandit listener, real
  CommandBus over a real ETS resource, real authority broker), a durable
  OCEL artifact on disk, and the independent consumer's corroboration.

  `async: false` -- the observer attributes every telemetry event emitted
  between a stimulus start and stop to that falsifier.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  alias AshA2A.Chicago
  alias AshA2A.Chicago.{Court, Falsifier, Query, Runner}

  alias AshA2A.Chicago.Courts.{
    ExtensionNegotiation,
    SemanticBoundary,
    SemanticEnvelope,
    TransportIndependence
  }

  alias AshA2A.Chicago.Ocel.Mapping
  alias AshA2A.Semantic.{Extension, Peer, Refusal}

  @moduletag :tmp_dir
  @moduletag timeout: 300_000

  @courts [SemanticEnvelope, ExtensionNegotiation, TransportIndependence]

  @expected %{
    "SA2A-ENV-001" => :falsifier_killed,
    "SA2A-ENV-002" => :falsifier_killed,
    "SA2A-ENV-003" => :falsifier_killed,
    "SA2A-ENV-004" => :falsifier_killed,
    "SA2A-ENV-005" => :falsifier_killed,
    "SA2A-ENV-006" => :falsifier_killed,
    "SA2A-ENV-007" => :positive_control_passed,
    "SA2A-ENV-008" => :falsifier_killed,
    "SA2A-ENV-009" => :falsifier_killed,
    "SA2A-ENV-010" => :falsifier_killed,
    "SA2A-ENV-011" => :falsifier_killed,
    "SA2A-ENV-012" => :falsifier_killed,
    "SA2A-ENV-013" => :positive_control_passed,
    "SA2A-ENV-014" => :positive_control_passed,
    "SA2A-NEG-001" => :falsifier_killed,
    "SA2A-NEG-002" => :falsifier_killed,
    "SA2A-NEG-003" => :falsifier_killed,
    "SA2A-NEG-004" => :falsifier_killed,
    "SA2A-NEG-005" => :falsifier_killed,
    "SA2A-NEG-006" => :falsifier_killed,
    "SA2A-NEG-007" => :falsifier_killed,
    "SA2A-NEG-008" => :positive_control_passed,
    "SA2A-NEG-009" => :positive_control_passed,
    "SA2A-TRANSPORT-001" => :positive_control_passed,
    "SA2A-TRANSPORT-002" => :falsifier_killed,
    "SA2A-TRANSPORT-003" => :falsifier_killed,
    "SA2A-TRANSPORT-004" => :falsifier_killed,
    "SA2A-TRANSPORT-005" => :positive_control_passed
  }

  describe "a real run of the three courts" do
    test "every falsifier reaches its final verdict and every pass is OCEL-corroborated", %{
      tmp_dir: dir
    } do
      assert {:ok, run} = Runner.run(courts: @courts, profile: :core, evidence_dir: dir)

      verdicts = Map.new(run.results, &{&1.falsifier_id, &1.verdict})

      assert verdicts == @expected,
             "verdicts differ:\n" <>
               Enum.map_join(run.results, "\n", fn r ->
                 "#{r.falsifier_id} #{r.verdict} corroborated=#{inspect(r.ocel_corroborated?)} " <>
                   "detail=#{inspect(r.detail)} ocel=#{inspect(r.ocel_detail)} " <>
                   "evidence=#{inspect(r.evidence, limit: 30, printable_limit: 400)}"
               end)

      for result <- run.results do
        assert result.attempt_observed? == true, "#{result.falsifier_id}: attempt not observed"

        assert result.ocel_corroborated? == true,
               "#{result.falsifier_id}: #{inspect(result.ocel_detail)}"

        assert Chicago.Result.counts_as_pass?(result)
      end

      assert run.ocel.dropped == 0
      assert {:ok, _index} = Query.load(Path.join(dir, "ocel.json"), run.ocel.sha256)
    end
  end

  describe "court declarations" do
    test "the three courts are discoverable :core courts with §11-complete falsifiers" do
      discovered = Chicago.courts()

      for court <- @courts do
        assert Court.discoverable?(court)
        assert court in discovered
        assert court.profile() == :core

        for %Falsifier{} = f <- court.falsifiers() do
          assert String.starts_with?(f.id, court.id() <> "-")
          assert f.attempt_predicate, "#{f.id} has no attempt predicate"
          assert f.outcome_predicate, "#{f.id} has no outcome predicate"
        end
      end

      ids = Enum.flat_map(@courts, fn c -> Enum.map(c.falsifiers(), & &1.id) end)
      assert Enum.sort(ids) == Enum.sort(Map.keys(@expected))
    end

    test "each court admits its own court-scoped mapping of the peer boundary events" do
      for {court, prefix} <- [
            {SemanticEnvelope, "sa2a.env"},
            {ExtensionNegotiation, "sa2a.neg"},
            {TransportIndependence, "sa2a.transport"}
          ] do
        activities = Enum.map(court.ocel_mappings(), & &1.activity)
        assert (prefix <> ".decision") in activities
        assert Enum.all?(court.ocel_mappings(), &(&1.source == court))
      end
    end
  end

  describe "SemanticBoundary.outcome_id/1" do
    test "is equal for equal decisions and differs when any semantic field differs" do
      base = %{envelope_id: "urn:uuid:1", standing: :admitted, code: nil, graph_digest: "abc"}

      assert SemanticBoundary.outcome_id(base) ==
               SemanticBoundary.outcome_id(Map.put(base, :peer, "other-peer"))

      for {k, v} <- [envelope_id: "urn:uuid:2", standing: :refused, code: :x, graph_digest: "d"] do
        refute SemanticBoundary.outcome_id(base) ==
                 SemanticBoundary.outcome_id(Map.put(base, k, v))
      end
    end

    test "the decision mapping relates the outcome object computed from real peer metadata" do
      [_, _, decision] = SemanticBoundary.peer_mappings("sa2a.test", __MODULE__)
      meta = %{peer: "p", envelope_id: "urn:uuid:1", standing: :admitted, graph_digest: "abc"}
      {objects, nil} = Mapping.objects(decision, %{}, meta)

      assert {"sa2a_outcome", SemanticBoundary.outcome_id(meta), "outcome"} in objects
      assert {"sa2a_envelope", "urn:uuid:1", "envelope"} in objects
    end
  end

  describe "Query {:distinct_objects, ...}" do
    test "counts distinct related objects of one type over one activity", %{tmp_dir: dir} do
      path = Path.join(dir, "ocel.json")

      doc = %{
        "objectTypes" => [],
        "eventTypes" => [],
        "objects" => [
          %{"id" => "o:1", "type" => "out"},
          %{"id" => "o:2", "type" => "out"},
          %{"id" => "p:1", "type" => "peer"},
          %{"id" => "falsifier:F-001", "type" => "falsifier"}
        ],
        "events" =>
          for {id, out, seq} <- [{"e1", "o:1", 1}, {"e2", "o:1", 2}, {"e3", "o:2", 3}] do
            %{
              "id" => id,
              "type" => "decision",
              "time" => "2026-09-16T00:00:00Z",
              "attributes" => [%{"name" => "chicago_seq", "value" => seq}],
              "relationships" => [
                %{"objectId" => out, "qualifier" => "outcome"},
                %{"objectId" => "p:1", "qualifier" => "peer"},
                %{"objectId" => "falsifier:F-001", "qualifier" => "under_stimulus"}
              ]
            }
          end
      }

      File.write!(path, JSON.encode!(doc))
      {:ok, index} = Query.load(path)

      assert {true, _} =
               Query.eval(index, "F-001", {:distinct_objects, "decision", "out", :eq, 2})

      assert {true, _} =
               Query.eval(index, "F-001", {:distinct_objects, "decision", "peer", :eq, 1})

      assert {false, _} =
               Query.eval(index, "F-001", {:distinct_objects, "decision", "out", :gte, 3})

      assert {true, _} = Query.eval(index, "F-001", {:distinct_objects, "absent", "out", :lte, 0})

      assert :ok = Query.validate_predicate({:distinct_objects, "decision", "out", :eq, 1})

      assert {:error, _} =
               Query.validate_predicate({:distinct_objects, "decision", "out", :gt, 1})
    end
  end

  describe "permanent guards for the defects the courts found" do
    alias AshA2A.Chicago.Fixtures.EnvelopeNegotiationTransport.{Ordering, OrderingAgent}
    alias AshA2A.Semantic.Envelope

    defp card(interfaces) do
      %A2A.AgentCard{
        name: "c",
        description: "c",
        url: "http://127.0.0.1:1",
        version: "1",
        skills: [],
        supported_interfaces: interfaces
      }
    end

    test "SA2A-NEG-002: a binding at another protocolVersion is not an advertisement" do
      binding = Extension.profile_id()

      assert Extension.advertisement(
               card([%{protocol_binding: binding, protocol_version: "v26.9.20"}])
             ) == :compatible

      assert Extension.advertisement(
               card([%{protocol_binding: binding, protocol_version: "v25.1.0"}])
             ) == {:incompatible, ["v25.1.0"]}

      assert Extension.advertisement(card([%{protocol_binding: binding}])) ==
               {:incompatible, [nil]}

      assert Extension.advertisement(nil) == :absent
      refute Extension.advertised?(nil)

      compatible = card([%{protocol_binding: binding, protocol_version: "v26.9.20"}])
      old = card([%{protocol_binding: binding, protocol_version: "v25.1.0"}])

      assert {:error, %{code: :profile_version_incompatible}} =
               Extension.negotiate(compatible, old)

      assert {:ok, ^binding} = Extension.negotiate(compatible, compatible)
    end

    test "SA2A-ENV-004/006/010/011: admission pre-checks refuse before the engine is asked" do
      peer = Peer.new(name: "guard-peer")

      base = [
        envelope_id: "urn:uuid:guard",
        kind: "sa2a:Request",
        semantic_basis: ["urn:sa2a:basis:x"],
        provenance: %{"agent" => "urn:agent:a"},
        graph: %{media_type: "text/turtle", digest: "d", content: "<urn:a> <urn:b> <urn:c> ."}
      ]

      for {overrides, code} <- [
            {[semantic_basis: []], :semantic_basis_missing},
            {[semantic_basis: [""]], :semantic_basis_missing},
            {[provenance: %{}], :provenance_missing},
            {[provenance: %{"agent" => ""}], :provenance_missing},
            {[consequence_class: "change"], :consequence_without_authority_requirement},
            {[receipts: [%{"receiptId" => "runtime:x"}]], :receipt_reference_unverified},
            {[graph: nil], :semantic_graph_missing}
          ] do
        envelope = Envelope.new!(Keyword.merge(base, overrides))
        outcome = Peer.admit(peer, envelope)
        assert {outcome.standing, outcome.code} == {:refused, code}
      end
    end

    test "SA2A-NEG-005: activated traffic to a peer with no advertised card is UNSUPPORTED" do
      message =
        "x"
        |> A2A.Message.new_user()
        |> Extension.activate(%{"envelopeId" => "urn:uuid:y", "kind" => "sa2a:Request"})

      outcome = Peer.receive_message(Peer.new(name: "no-card"), message)
      assert {outcome.standing, outcome.code} == {:unsupported, :profile_not_advertised}
    end

    test "SA2A-TRANSPORT-004: a string-keyed a2a.auth (the only shape JSON can carry) confers no identity" do
      principal = "guard-granted-#{System.unique_integer([:positive])}"
      subject = AshA2A.Identity.principal(principal)
      # SA2A-AUTH-017 (RFC-SA2A-002 S66): the real dispatch path
      # (`AshA2A.Agent.build_command/4`) resolves the dispatched skill's
      # canonical capability id before calling `Grant.authorize/3`, so this
      # grant must be issued under `Ordering`'s canonical id, not the bare
      # wire selector "place_order".
      {:ok, %{id: place_order_id}} = AshA2A.Info.skill(Ordering, "place_order")
      _ = AshA2A.Authority.Grant.grant(subject, place_order_id)
      assert AshA2A.Authority.Grant.granted?(subject, place_order_id)

      agent = :"guard_ordering_#{System.unique_integer([:positive])}"
      {:ok, pid} = OrderingAgent.start_link(name: agent)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      order = fn item ->
        %{
          A2A.Message.new_user([A2A.Part.Data.new(%{"item" => item, "quantity" => 1})])
          | metadata: %{"skill" => "place_order"}
        }
      end

      forged = "guard-forged-#{System.unique_integer([:positive])}"
      verified = "guard-verified-#{System.unique_integer([:positive])}"

      {:ok, _} =
        A2A.call(agent, order.(forged), metadata: %{"a2a.auth" => %{"identity" => principal}})

      {:ok, _} =
        A2A.call(agent, order.(verified), metadata: %{"a2a.auth" => %{identity: principal}})

      items = Ordering |> Ash.read!() |> Enum.map(& &1.item)
      refute forged in items
      assert verified in items
    end
  end

  describe "refusal codes introduced at the semantic boundary are classified" do
    test "Peer and Extension codes map to S42 classes" do
      mapping = Refusal.mapping()

      for {code, class} <-
            Map.merge(Peer.__sa2a_refusal_codes__(), Extension.__sa2a_refusal_codes__()) do
        assert Refusal.class?(class)
        assert Map.fetch!(mapping, code) in Refusal.classes()
      end
    end
  end
end
