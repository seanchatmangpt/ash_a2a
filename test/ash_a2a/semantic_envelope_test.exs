defmodule AshA2A.SemanticEnvelopeTest do
  @moduledoc """
  Chicago-school tests for `AshA2A.Semantic.Envelope` (RFC-SA2A-001 S11).

  Real structs, real `Jason` encode/decode, real `AshA2A.Semantic.Standing`
  transitions to raise standing when a raised-standing envelope is needed.
  No mocking: every collaborator here (Jason, Standing, Refusal, Vocabulary)
  is real and runnable in-process, so there is nothing a double would buy.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Semantic.{Envelope, Refusal, Standing, Vocabulary}

  defp minimal(overrides) do
    Map.merge(%{envelope_id: "urn:uuid:test-1", kind: "sa2a:Request"}, overrides)
  end

  defp new!, do: new!(%{})

  defp new!(overrides) do
    {:ok, envelope} = Envelope.new(minimal(overrides))
    envelope
  end

  describe "S11 shape" do
    test "carries every RFC S11 field with the documented defaults" do
      envelope = new!()

      assert envelope.profile == Envelope.default_profile()
      assert envelope.kind == "sa2a:Request"
      assert envelope.envelope_id == "urn:uuid:test-1"
      assert envelope.subjects == []
      assert envelope.standing == :candidate
      assert envelope.semantic_basis == []
      assert envelope.graph == nil
      assert envelope.provenance == %{}
      assert envelope.consequence_class == "none"
      assert envelope.authority_requirement == "none"
      assert envelope.bounds == %{}
      assert envelope.receipts == []
      assert envelope.standing_history == []
    end

    test "consequenceClass and authorityRequirement default to \"none\"" do
      assert new!().consequence_class == "none"
      assert new!().authority_requirement == "none"
    end

    test "accepts a full graph triple of mediaType/digest/content" do
      graph = %{
        media_type: "text/turtle",
        digest: "blake3:9b8180962a93910d17c51d029626f393",
        content: "@prefix ex: <https://example.org/> . ex:a ex:b ex:c ."
      }

      envelope = new!(%{graph: graph})
      assert envelope.graph == graph
    end

    test "accepts camelCase string keys as well as atom keys" do
      {:ok, envelope} =
        Envelope.new(%{
          "envelopeId" => "urn:uuid:string-keys",
          "kind" => "sa2a:Response",
          "consequenceClass" => "observe",
          "authorityRequirement" => "delegated",
          "semanticBasis" => ["urn:sa2a:basis:1"],
          "graph" => %{"mediaType" => "text/turtle", "digest" => "d", "content" => "c"}
        })

      assert envelope.envelope_id == "urn:uuid:string-keys"
      assert envelope.consequence_class == "observe"
      assert envelope.authority_requirement == "delegated"
      assert envelope.semantic_basis == ["urn:sa2a:basis:1"]
      assert envelope.graph == %{media_type: "text/turtle", digest: "d", content: "c"}
    end
  end

  describe "candidate-only construction (the structural invariant)" do
    test "new/1 forces :candidate even when the caller passes standing: :candidate" do
      assert new!(%{standing: :candidate}).standing == :candidate
    end

    test "new/1 refuses a claimed standing above candidate" do
      assert {:error, %Refusal{} = refusal} = Envelope.new(minimal(%{standing: :admitted}))

      assert refusal.class == :refused_meta_rigor
      assert refusal.code == :standing_self_declared
      assert refusal.detail == :admitted
      assert refusal.lawful? == true
    end

    test "from_json/1 refuses every standing an inbound payload could claim" do
      for claimed <- Standing.states() ++ Standing.terminal_states(),
          claimed != :candidate do
        wire = Atom.to_string(claimed)

        json =
          Jason.encode!(%{
            "envelopeId" => "urn:uuid:claim",
            "kind" => "sa2a:Request",
            "standing" => wire
          })

        # The refused detail is the raw wire *string*, never an atomized
        # version of it -- wire input is never fed to String.to_atom/1.
        assert {:error, %Refusal{code: :standing_self_declared, detail: ^wire}} =
                 Envelope.from_json(json),
               "inbound payload claiming #{claimed} was not refused"
      end
    end

    test "from_json/1 refuses a fabricated standingHistory" do
      json =
        Jason.encode!(%{
          "envelopeId" => "urn:uuid:hist",
          "kind" => "sa2a:Request",
          "standingHistory" => [%{"from" => "candidate", "to" => "admitted"}]
        })

      assert {:error, %Refusal{} = refusal} = Envelope.from_json(json)
      assert refusal.class == :refused_meta_rigor
      assert refusal.code == :standing_history_declared
    end

    test "there is no exported constructor that yields a standing above :candidate" do
      # Every public 1-arity/2-arity constructor on the module, driven for
      # real with an admitted-claiming payload.
      claim = minimal(%{standing: :admitted})

      assert {:error, %Refusal{}} = Envelope.new(claim)
      assert {:error, %Refusal{}} = Envelope.from_map(%{claim | standing: :admitted})

      assert {:error, %Refusal{}} =
               Envelope.from_json(
                 Jason.encode!(%{
                   "envelopeId" => "urn:uuid:x",
                   "kind" => "sa2a:Request",
                   "standing" => "admitted"
                 })
               )

      # And the only lawful raise is a real evidenced transition.
      assert {:ok, raised} =
               Standing.transition(new!(), :received, %{
                 transport: "a2a/https",
                 received_at: "2026-09-16T00:00:00Z"
               })

      assert raised.standing == :received
    end
  end

  describe "to_json/1 <-> from_json/1 round trip" do
    test "a minimal candidate envelope round-trips byte-identically through JSON" do
      original = new!()

      assert {:ok, restored} = original |> Envelope.to_json() |> Envelope.from_json()
      assert restored == original
      assert Envelope.to_json(restored) == Envelope.to_json(original)
    end

    test "a fully-populated candidate envelope round-trips" do
      # String-keyed provenance/bounds because that is the real wire shape:
      # JSON has no atom keys, so an atom-keyed map would not survive any
      # honest round trip and the test would be lying about the wire.
      original =
        new!(%{
          profile: "urn:sa2a:profile:conformance:v26.9.16",
          kind: "sa2a:Task",
          subjects: ["urn:example:subject:1", "urn:example:subject:2"],
          semantic_basis: ["urn:sa2a:basis:shapes:v1"],
          graph: %{
            media_type: "text/turtle",
            digest: "blake3:610ccbcd4ed4b23cf4179fde360625da",
            content: "@prefix ex: <https://example.org/> .\nex:s ex:p ex:o ."
          },
          provenance: %{"agent" => "urn:example:agent:a", "wasDerivedFrom" => "urn:example:x"},
          consequence_class: "change",
          authority_requirement: "principal",
          bounds: %{"maxTriples" => 10_000},
          receipts: [%{"receiptId" => "urn:receipt:1"}]
        })

      json = Envelope.to_json(original)
      assert {:ok, restored} = Envelope.from_json(json)
      assert restored == original
    end

    test "to_map/1 emits exactly the RFC camelCase key set" do
      map = Envelope.to_map(new!())

      assert Enum.sort(Map.keys(map)) ==
               Enum.sort(~w(
                 profile kind envelopeId subjects standing semanticBasis graph
                 provenance consequenceClass authorityRequirement bounds
                 receipts standingHistory
               ))
    end

    test "a raised envelope serializes for audit but is NOT re-ingestible" do
      {:ok, received} =
        Standing.transition(new!(), :received, %{
          transport: "a2a/https",
          received_at: "2026-09-16T00:00:00Z"
        })

      json = Envelope.to_json(received)
      assert %{"standing" => "received"} = Jason.decode!(json)

      assert [%{"from" => "candidate", "to" => "received"}] =
               Jason.decode!(json)["standingHistory"]

      # Re-ingesting serialized standing would be exactly the
      # self-declaration S6 forbids. It is refused, not silently downgraded.
      assert {:error, %Refusal{code: :standing_self_declared}} = Envelope.from_json(json)
    end
  end

  describe "fail-closed validation (S43)" do
    test "a missing envelopeId is REFUSED_IDENTITY" do
      assert {:error, %Refusal{class: :refused_identity, code: :envelope_id_missing}} =
               Envelope.new(%{kind: "sa2a:Request"})

      assert {:error, %Refusal{code: :envelope_id_missing}} =
               Envelope.new(%{envelope_id: "", kind: "sa2a:Request"})
    end

    test "a missing kind is REFUSED_STRUCTURE" do
      assert {:error, %Refusal{class: :refused_structure, code: :kind_missing}} =
               Envelope.new(%{envelope_id: "urn:uuid:k"})
    end

    test "an unregistered kind prefix is REFUSED_NAMESPACE" do
      assert {:error, %Refusal{class: :refused_namespace, code: :kind_namespace_unregistered}} =
               Envelope.new(minimal(%{kind: "madeup:Request"}))

      assert {:error, %Refusal{code: :kind_namespace_unregistered}} =
               Envelope.new(minimal(%{kind: "NoPrefixAtAll"}))
    end

    test "every prefix the existing Vocabulary registry knows is admitted as a kind prefix" do
      for prefix <- Map.keys(Vocabulary.prefixes()) do
        assert {:ok, envelope} = Envelope.new(minimal(%{kind: "#{prefix}:Thing"}))
        assert envelope.kind == "#{prefix}:Thing"
      end
    end

    test "an unimplemented profile is UNSUPPORTED_PROFILE, not REFUSED_PROFILE" do
      assert {:error, %Refusal{} = refusal} =
               Envelope.new(minimal(%{profile: "urn:sa2a:profile:from-the-future:v99"}))

      assert refusal.class == :unsupported_profile
      assert refusal.code == :unknown_profile
      assert Refusal.terminal_standing(refusal) == :unsupported
    end

    test "a malformed profile is REFUSED_PROFILE" do
      assert {:error, %Refusal{class: :refused_profile, code: :profile_invalid}} =
               Envelope.new(minimal(%{profile: 42}))
    end

    test "a partial graph is REFUSED_STRUCTURE" do
      assert {:error, %Refusal{class: :refused_structure, code: :graph_shape_invalid}} =
               Envelope.new(minimal(%{graph: %{media_type: "text/turtle"}}))

      assert {:error, %Refusal{code: :graph_shape_invalid}} =
               Envelope.new(minimal(%{graph: %{"mediaType" => "text/turtle", "digest" => "d"}}))
    end

    test "an unknown consequenceClass is REFUSED_CONSEQUENCE" do
      assert {:error, %Refusal{class: :refused_consequence, code: :consequence_class_unknown}} =
               Envelope.new(minimal(%{consequence_class: "unknown"}))
    end

    test "every admissible consequenceClass is accepted" do
      for value <- Envelope.consequence_classes() do
        assert {:ok, envelope} = Envelope.new(minimal(%{consequence_class: value}))
        assert envelope.consequence_class == value
      end
    end

    test "an unknown authorityRequirement is REFUSED_AUTHORITY" do
      assert {:error, %Refusal{class: :refused_authority, code: :authority_requirement_unknown}} =
               Envelope.new(minimal(%{authority_requirement: "root"}))
    end

    test "non-list and non-map fields are REFUSED_STRUCTURE" do
      assert {:error, %Refusal{code: :envelope_field_invalid}} =
               Envelope.new(minimal(%{subjects: "not-a-list"}))

      assert {:error, %Refusal{code: :envelope_field_invalid}} =
               Envelope.new(minimal(%{provenance: "not-a-map"}))

      assert {:error, %Refusal{code: :envelope_field_invalid}} =
               Envelope.new(minimal(%{bounds: []}))
    end

    test "malformed JSON is REFUSED_STRUCTURE, never a raise" do
      assert {:error, %Refusal{class: :refused_structure, code: :envelope_json_invalid}} =
               Envelope.from_json("{not json")

      assert {:error, %Refusal{code: :envelope_json_invalid}} = Envelope.from_json("[1,2,3]")
    end

    test "a non-map payload is REFUSED_STRUCTURE" do
      assert {:error, %Refusal{code: :envelope_payload_invalid}} = Envelope.from_json(:nope)
      assert {:error, %Refusal{code: :envelope_payload_invalid}} = Envelope.new(:nope)
    end
  end

  describe "decode_standing/1" do
    test "decodes every real state without String.to_atom on wire input" do
      for state <- Standing.states() ++ Standing.terminal_states() do
        assert {:ok, ^state} = Envelope.decode_standing(Atom.to_string(state))
      end
    end

    test "an unrecognized standing string is refused, not coerced into a new atom" do
      assert {:error, %Refusal{class: :refused_structure, code: :standing_state_unknown}} =
               Envelope.decode_standing("sovereign")

      assert {:error, %Refusal{code: :standing_state_unknown}} = Envelope.decode_standing(:atom)
    end
  end

  describe "evidence_digest/1" do
    test "is order-independent over map keys" do
      assert Envelope.evidence_digest(%{a: 1, b: 2, c: 3}) ==
               Envelope.evidence_digest(%{c: 3, b: 2, a: 1})
    end

    test "changes when any value changes" do
      refute Envelope.evidence_digest(%{a: 1}) == Envelope.evidence_digest(%{a: 2})
      refute Envelope.evidence_digest(%{a: 1}) == Envelope.evidence_digest(%{b: 1})
    end

    test "is a real sha256 in the SemanticSubject digest format" do
      "sha256:" <> hex = Envelope.evidence_digest(%{a: 1})
      assert String.match?(hex, ~r/\A[0-9a-f]{64}\z/)
    end
  end

  describe "history_entry/3 and the ledger the real transition path writes" do
    test "an entry carries keys and a digest, never the raw evidence" do
      evidence = %{transport: "a2a/https", received_at: "2026-09-16T00:00:00Z", secret: "hunter2"}

      entry = Envelope.history_entry(:candidate, :received, evidence)

      assert entry.from == :candidate
      assert entry.to == :received
      assert entry.evidence_keys == ["received_at", "secret", "transport"]
      assert entry.evidence_digest == Envelope.evidence_digest(evidence)
      refute inspect(entry) =~ "hunter2"
    end

    test "history_entry/3 does not seal anything: only Standing.transition/3 mints a ledger" do
      # The entry constructor is pure -- it returns a map and never touches an
      # envelope, so it cannot be used to forge standing. Stapling a
      # hand-built entry onto an envelope produces an unsealed ledger, which
      # the real transition path refuses.
      forged = %{
        new!()
        | standing: :received,
          standing_history: [Envelope.history_entry(:candidate, :received, %{transport: "x"})]
      }

      assert forged.standing_seal == nil

      assert {:error, %Refusal{code: :standing_ledger_unsealed}} =
               Standing.transition(forged, :parsed, %{media_type: "text/turtle", triple_count: 1})
    end

    test "the real transition path appends an ordered, sealed, raw-evidence-free history" do
      {:ok, received} =
        Standing.transition(new!(), :received, %{
          transport: "a2a/https",
          received_at: "2026-09-16T00:00:00Z",
          secret: "hunter2"
        })

      {:ok, parsed} =
        Standing.transition(received, :parsed, %{media_type: "text/turtle", triple_count: 2})

      assert Enum.map(parsed.standing_history, & &1.to) == [:received, :parsed]
      assert Enum.map(parsed.standing_history, & &1.from) == [:candidate, :received]
      assert is_binary(parsed.standing_seal)

      # Raw evidence values never enter the envelope or its serialization.
      refute Envelope.to_json(parsed) =~ "hunter2"
    end

    test "the ledger seal is never serialized: standing stays audit evidence, not a credential" do
      {:ok, received} =
        Standing.transition(new!(), :received, %{transport: "a2a/https", received_at: "now"})

      map = Envelope.to_map(received)

      refute Map.has_key?(map, "standingSeal")
      refute Envelope.to_json(received) =~ received.standing_seal
    end
  end
end
