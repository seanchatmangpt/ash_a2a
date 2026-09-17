defmodule AshA2A.Semantic.PeerCapabilityReconciliationTest do
  @moduledoc """
  Chicago-school tests proving the PRD §14 / ARD §14 gap is closed:
  `AshA2A.Semantic.Peer.admit/2`'s own admission decision now reconciles an
  envelope's claimed capability label against this peer's own capability
  identity through the real, already-tested
  `AshA2A.Semantic.MappingRegistry.reconcile/3` (RFC-SA2A-001 S47), instead of
  the two mechanisms sitting side by side, real and tested, but unwired.

  Real collaborators throughout: the real compiled `Ash.Domain`/`Ash.Resource`
  pair `AshA2A.Test.SemanticPeerFixture.{Domain, Ordering}` (already used by
  the cross-peer and agent-card suites), the real
  `AshA2A.Semantic.AgentCard.from_skill/2` derivation, a real
  `AshA2A.Semantic.MappingRegistry`, a real `AshA2A.ReceiptStore.Memory`
  process for the admitted-mapping case (via the real
  `AshA2A.Chicago.Fixtures.CanonicalIdentity` fixture helpers), and real
  `AshA2A.Semantic.Peer`/`Envelope` structs. Nothing here is mocked, stubbed
  or patched -- there is no collaborator infeasible to run for real.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Chicago.Fixtures.CanonicalIdentity
  alias AshA2A.Semantic.{AgentCard, Envelope, MappingRegistry, Peer, PeerCapabilityReconciliation}
  alias AshA2A.Test.SemanticPeerFixture.Domain

  # The real IRI `AshA2A.Semantic.AgentCard.from_skill/2` derives for
  # `Domain`'s named `place_order` skill (`skill :place_order, :create`),
  # resolved through the same real `AshA2A.Info.skill/2` selector lookup
  # `PeerCapabilityReconciliation.reconcile/2` itself uses -- computed once,
  # asserted as real state in the first test below, never hand-typed.
  defp own_place_order_iri do
    {:ok, skill} = AshA2A.Info.skill(Domain, "place_order")
    AgentCard.from_skill(skill).capability_iri
  end

  defp envelope(provenance) do
    Envelope.new!(
      envelope_id: "urn:uuid:pcr-" <> Ash.UUIDv7.generate(),
      kind: "sa2a:Request",
      semantic_basis: ["urn:sa2a:basis:pcr-test:v1"],
      provenance: provenance,
      graph: %{
        media_type: "text/turtle",
        digest: "blake3:pcr-test",
        content: "@prefix ex: <http://example.org/> .\nex:a ex:p ex:o .\n"
      }
    )
  end

  describe "claimed_capability/1" do
    test "nil when provenance names no capability claim at all" do
      refute PeerCapabilityReconciliation.claimed_capability(envelope(%{"agent" => "peer-a"}))
    end

    test "nil when only one half of the claim is present" do
      refute PeerCapabilityReconciliation.claimed_capability(
               envelope(%{"capability_label" => "place_order"})
             )

      refute PeerCapabilityReconciliation.claimed_capability(
               envelope(%{"capability_iri" => "urn:example:x"})
             )
    end

    test "the real {label, iri} claim, string-keyed exactly as the wire carries it" do
      claim =
        PeerCapabilityReconciliation.claimed_capability(
          envelope(%{
            "agent" => "peer-a",
            "capability_label" => "place_order",
            "capability_iri" => "http://example.org/acme#PlaceOrder"
          })
        )

      assert claim == %{label: "place_order", iri: "http://example.org/acme#PlaceOrder"}
    end
  end

  describe "this peer's own capability identity is real, derived state" do
    test "the named place_order skill resolves through the real AshA2A.Info.skill/2 selector, by name" do
      assert {:ok, skill} = AshA2A.Info.skill(Domain, "place_order")
      assert skill.name == :place_order
      assert skill.resource == AshA2A.Test.SemanticPeerFixture.Ordering
      # A real, derived IRI (from the real compiled {resource, action} id) --
      # not asserted as a hand-typed constant anywhere in this test module.
      assert AgentCard.from_skill(skill).capability_iri =~ "urn:sa2a:capability:"
    end

    test "Domain compiles three real skills (read/destroy default, place_order named)" do
      names = Domain |> AshA2A.Info.capability_index() |> Enum.map(& &1.name) |> Enum.sort()
      assert names == [:destroy, :place_order, :read]
    end
  end

  describe "reconcile/2" do
    test "no-op: envelope names no capability claim at all" do
      peer = Peer.new(name: "peer-b", capabilities: Domain)
      env = envelope(%{"agent" => "peer-a"})

      assert PeerCapabilityReconciliation.reconcile(peer, env) == :ok
    end

    test "no-op: this peer has no :capabilities configured" do
      peer = Peer.new(name: "peer-b")

      env =
        envelope(%{
          "capability_label" => "place_order",
          "capability_iri" => "http://example.org/acme#PlaceOrder"
        })

      assert PeerCapabilityReconciliation.reconcile(peer, env) == :ok
    end

    test "no-op: this peer exposes no capability under the claimed label" do
      peer = Peer.new(name: "peer-b", capabilities: Domain)

      env =
        envelope(%{
          "capability_label" => "cancel_order",
          "capability_iri" => "http://example.org/acme#CancelOrder"
        })

      assert PeerCapabilityReconciliation.reconcile(peer, env) == :ok
    end

    test "same label, SAME identity -- reconciles with no refusal" do
      peer = Peer.new(name: "peer-b", capabilities: Domain)

      env =
        envelope(%{
          "capability_label" => "place_order",
          "capability_iri" => own_place_order_iri()
        })

      assert PeerCapabilityReconciliation.reconcile(peer, env) == :ok
    end

    test "the real S47 case: same label, DIFFERENT identity, no admitted mapping -- refused" do
      peer = Peer.new(name: "peer-b", capabilities: Domain)

      env =
        envelope(%{
          "capability_label" => "place_order",
          "capability_iri" => "http://example.org/acme#PlaceOrder"
        })

      assert {:error, refusal} = PeerCapabilityReconciliation.reconcile(peer, env)
      assert refusal.code == :semantic_label_collision_unmapped
      assert refusal.detail =~ "place_order"
      assert refusal.detail =~ own_place_order_iri()
    end

    test "an admitted mapping between the two identities resolves the same collision" do
      CanonicalIdentity.with_store(fn store ->
        remote_iri = "http://example.org/acme#PlaceOrder"

        receipt =
          CanonicalIdentity.held_mapping_receipt(
            store,
            own_place_order_iri(),
            remote_iri,
            :exact_match
          )

        {:ok, registry} =
          MappingRegistry.new(receipt_store: {AshA2A.ReceiptStore.Memory, name: store})
          |> MappingRegistry.register(%{
            source: own_place_order_iri(),
            target: remote_iri,
            kind: :exact_match,
            admission_receipt: receipt
          })

        peer = Peer.new(name: "peer-b", capabilities: Domain, mapping_registry: registry)

        env =
          envelope(%{
            "capability_label" => "place_order",
            "capability_iri" => remote_iri
          })

        assert PeerCapabilityReconciliation.reconcile(peer, env) == :ok
      end)
    end
  end

  describe "wired into Peer.admit/2's real admission pipeline" do
    test "a colliding capability claim refuses the whole envelope before GraphLaw ever runs" do
      peer = Peer.new(name: "peer-b", capabilities: Domain)

      env =
        envelope(%{
          "agent" => "peer-a",
          "capability_label" => "place_order",
          "capability_iri" => "http://example.org/acme#PlaceOrder"
        })

      outcome = Peer.admit(peer, env)

      assert outcome.standing == :refused
      assert outcome.code == :semantic_label_collision_unmapped
      # Refused before the digest step ever ran -- there is no graph_digest
      # in a refusal this early, unlike a GraphLaw-stage refusal.
      refute Map.has_key?(outcome, :graph_digest)
    end

    test "the same envelope with no capability claim is never refused by this check" do
      peer = Peer.new(name: "peer-b", capabilities: Domain)
      env = envelope(%{"agent" => "peer-a"})

      outcome = Peer.admit(peer, env)

      refute outcome.code == :semantic_label_collision_unmapped
    end
  end
end
