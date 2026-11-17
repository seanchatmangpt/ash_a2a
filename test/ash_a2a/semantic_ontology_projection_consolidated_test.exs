# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
# SPDX-License-Identifier: MIT

# ==============================================================================
# Consolidated Test Suite: Direct ash_a2a Suite: Semantic Ontology Projection
# Target File 2 of Worker 09
# Consolidated from 14 source files:
#   - test/ash_a2a/semantic_iri_admitted_index_test.exs
#   - test/ash_a2a/semantic_iri_public_first_test.exs
#   - test/ash_a2a/semantic_law_document_test.exs
#   - test/ash_a2a/semantic_nonllm_hddl_test.exs
#   - test/ash_a2a/semantic_ontology_canonical_digest_test.exs
#   - test/ash_a2a/semantic_ontology_test.exs
#   - test/ash_a2a/semantic_peer_consequence_source_test.exs
#   - test/ash_a2a/semantic_plan_package_test.exs
#   - test/ash_a2a/semantic_plan_pipeline_test.exs
#   - test/ash_a2a/semantic_plan_projection_test.exs
#   - test/ash_a2a/semantic_planning_ir_test.exs
#   - test/ash_a2a/semantic_projection_r2rml_real_test.exs
#   - test/ash_a2a/semantic_projection_test.exs
#   - test/ash_a2a/semantic_refusal_test.exs
# ==============================================================================

# --- SECTION 1: Original test/ash_a2a/semantic_iri_admitted_index_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SemanticIriAdmittedIndexTest do
  @moduledoc """
  Regression cover for `AshA2A.Semantic.Iri.classify/2` laundering an invented
  term into `:public` on the strength of its namespace prefix.

  The defect, as reproduced before the fix, against the real pinned ontology
  cache:

      TermRegistry.member?(index, "…skos/core#totallyInventedTermThatDoesNotExist")
        -> false
      Iri.classify("…skos/core#totallyInventedTermThatDoesNotExist", index)
        -> :public

  `classify/2` fell back to `TermRegistry.in_admitted_namespace?/2`, a bare
  `String.starts_with?/2` prefix test, so anyone who spelled a minted term
  under an admitted namespace got it classified public -- which is the S7.3
  mint-and-use evasion in one string operation.

  The index here is the real one, built from the real digest-pinned
  `priv/semantic/ontology_cache` documents through
  `TermRegistry.from_cache/1`. Nothing is stubbed.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Semantic.{Iri, TermRegistry}

  setup_all do
    assert {:ok, index} = TermRegistry.from_cache()
    %{index: index}
  end

  @real_term "http://www.w3.org/2004/02/skos/core#prefLabel"
  @invented_term "http://www.w3.org/2004/02/skos/core#totallyInventedTermThatDoesNotExist"

  describe "the verifier's minimal reproducing input" do
    test "the invented term really is absent from the real admitted index", %{index: index} do
      assert TermRegistry.member?(index, @real_term)
      refute TermRegistry.member?(index, @invented_term)
    end

    test "it sits under an admitted namespace, which is what fooled the old check", %{
      index: index
    } do
      assert TermRegistry.in_admitted_namespace?(index, @invented_term)
    end

    test "and it no longer classifies as :public", %{index: index} do
      assert Iri.classify(@invented_term, index) == :unknown
    end

    test "a real admitted term still classifies as :public", %{index: index} do
      assert Iri.classify(@real_term, index) == :public
    end
  end

  describe "the case is named rather than merely refused" do
    test "admitted_namespace_but_unknown_term?/2 identifies the mint-and-use shape", %{
      index: index
    } do
      assert Iri.admitted_namespace_but_unknown_term?(@invented_term, index)
      refute Iri.admitted_namespace_but_unknown_term?(@real_term, index)
      refute Iri.admitted_namespace_but_unknown_term?("http://elsewhere.example/x", index)
      refute Iri.admitted_namespace_but_unknown_term?(@invented_term, nil)
    end
  end

  describe "membership is the only route to :public, across every admitted namespace" do
    test "no minted sibling of a real term classifies public", %{index: index} do
      minted =
        index
        |> TermRegistry.iris()
        |> Enum.take(25)
        |> Enum.map(&(&1 <> "MintedByThisTestAndNotInAnyPinnedDocument"))

      assert minted != []

      for iri <- minted do
        assert TermRegistry.in_admitted_namespace?(index, iri)
        refute TermRegistry.member?(index, iri)

        assert Iri.classify(iri, index) == :unknown,
               "#{iri} classified #{inspect(Iri.classify(iri, index))}"
      end
    end

    test "every term really in the index does classify public", %{index: index} do
      iris = TermRegistry.iris(index)
      assert length(iris) > 0

      for iri <- iris do
        assert Iri.classify(iri, index) == :public, "#{iri} did not classify public"
      end
    end
  end

  describe "the rest of the classification is unchanged" do
    test "private namespaces are still private", %{index: index} do
      assert Iri.classify("urn:ash-a2a:semantic:node:e2", index) == :private
      assert Iri.classify("urn:example:thing", index) == :private
    end

    test "an unknown IRI with no index at all is :unknown, not :public" do
      assert Iri.classify(@real_term, nil) == :unknown
      assert Iri.classify("http://elsewhere.example/x", nil) == :unknown
    end
  end
end

# --- SECTION 2: Original test/ash_a2a/semantic_iri_public_first_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SemanticIriPublicFirstTest do
  @moduledoc """
  Real tests for RFC-SA2A-001 S7 / S45 / S46 / S47.

  Chicago school throughout: no mocks, no stubbed collaborators. Every
  assertion runs against real bytes and real behaviour --

    * the real pinned ontology cache in `priv/semantic/ontology_cache`, holding
      the four real W3C vocabulary documents (rdf, rdfs, owl, skos) that ship
      offline inside the `rdf` hex package;
    * the real `RDF.Turtle` reader parsing those real documents;
    * real SHA-256 digests over real file contents;
    * real files on disk in a real `tmp_dir` for the drift/fail-closed test,
      including a real byte-level corruption of a real cached object;
    * a real `%AshA2A.Receipt{}` built by `AshA2A.Receipt.pending/3` from a real
      `%AshA2A.Command{}` for the admission-receipt requirement.

  No network is contacted anywhere in this file -- that is itself the S46 rule
  under test.
  """

  use ExUnit.Case, async: true

  alias AshA2A.{Command, Identity, Receipt}
  alias AshA2A.Semantic.{Iri, MappingRegistry, OntologyCache, Revision, TermRegistry, Vocabulary}
  alias AshA2A.Semantic.Iri.PrivateTerm

  @skos_concept "http://www.w3.org/2004/02/skos/core#Concept"
  @skos_ns "http://www.w3.org/2004/02/skos/core#"
  @owl_ns "http://www.w3.org/2002/07/owl#"

  setup_all do
    {:ok, index} = TermRegistry.from_cache()
    %{index: index}
  end

  # A real admission receipt for exactly `source -> target` of `kind`: claimed,
  # executed, committed to and fetched back from a real receipt store, plus a
  # registry bound to that store (RFC-SA2A-001 S6: a named receipt is not a
  # receipt).
  defp admitted_mapping(source, target, kind) do
    name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    start_supervised!({AshA2A.ReceiptStore.Memory, name: name}, id: name)

    command =
      Command.new("AshA2A.Test.Fixture.Echo.admit_mapping",
        command_id: "mapping-admission-#{System.unique_integer([:positive])}",
        agent_id: "agent-iri-test",
        principal_id: "principal-iri-test",
        input: MappingRegistry.admission_input(source, target, kind)
      )

    {:execute, execution_id} = AshA2A.ReceiptStore.Memory.claim(command, name: name)

    receipt =
      command
      |> Receipt.pending(execution_id, :none)
      |> Receipt.finalize({:reply, %{admitted: true}})

    :ok = AshA2A.ReceiptStore.Memory.commit(receipt, name: name)
    {:ok, held} = AshA2A.ReceiptStore.Memory.fetch(command.command_id, name: name)

    {MappingRegistry.new(receipt_store: {AshA2A.ReceiptStore.Memory, name: name}), held}
  end

  defp real_receipt do
    command =
      Command.new("AshA2A.Test.Fixture.Echo.read",
        command_id: "iri-admission-#{System.unique_integer([:positive])}",
        agent_id: "agent-iri-test",
        principal_id: "principal-iri-test",
        input: %{term: "BerthWindowClearance"}
      )

    Receipt.pending(command, Identity.new(:execution, "exec-iri-test"), :none)
  end

  defp private_term_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        iri: "urn:ash-a2a:semantic:BerthWindowClearance",
        label: "Berth Window Clearance",
        definition:
          "Clearance granted to a vessel to occupy a specific berth during a specific window.",
        scope: :organization_private,
        owning_namespace: "urn:ash-a2a:semantic:",
        version: "2026.09.16",
        provenance: %{
          searched_sources: [@skos_ns, @owl_ns],
          public_absence_reason:
            "No admitted public source declares berth-window clearance; the closest public " <>
              "terms are generic concept/annotation classes with no berth or window semantics."
        },
        mappings: [%{target: @skos_concept, kind: :broad_match}],
        admission_receipt: %{receipt_id: "rcpt-iri-1", fingerprint: "fp-iri-1"}
      },
      overrides
    )
  end

  # ---------------------------------------------------------------- S7.1 IRI --

  describe "S7.1 IRI validation" do
    test "accepts real absolute IRIs" do
      for iri <- [@skos_concept, "https://schema.org/Action", "urn:ash-a2a:semantic:Widget"] do
        assert {:ok, ^iri} = Iri.validate(iri)
      end
    end

    test "refuses relative, empty, whitespace-bearing and excluded-character IRIs" do
      assert {:error, %{code: :iri_not_absolute}} = Iri.validate("skos/Concept")
      assert {:error, %{code: :iri_empty}} = Iri.validate("")
      assert {:error, %{code: :iri_invalid_characters}} = Iri.validate("http://x.test/a b")
      assert {:error, %{code: :iri_invalid_characters}} = Iri.validate("http://x.test/<a>")
      assert {:error, %{code: :iri_invalid_characters}} = Iri.validate(" http://x.test/a")
      assert {:error, %{code: :iri_invalid_scheme}} = Iri.validate("1http://x.test/a")
      assert {:error, %{code: :iri_not_a_string}} = Iri.validate(:skos_concept)
    end

    test "classify separates public, private and unknown against the real index", %{index: index} do
      assert Iri.classify(@skos_concept, index) == :public
      assert Iri.classify("urn:ash-a2a:semantic:Widget", index) == :private
      assert Iri.classify("https://example.test/vocab#Widget", index) == :unknown
    end
  end

  # ------------------------------------------------- S7.2 five-step sequence --

  describe "S7.2 public-ontology-first resolution" do
    test "the index is built from the real pinned documents, not a fixture list", %{index: index} do
      assert TermRegistry.size(index) > 100

      assert index.namespaces == [
               "http://www.w3.org/1999/02/22-rdf-syntax-ns#",
               "http://www.w3.org/2000/01/rdf-schema#",
               @owl_ns,
               @skos_ns
             ]

      # Real terms actually declared by the real W3C documents.
      assert @skos_concept in TermRegistry.iris(index)
      assert "#{@skos_ns}prefLabel" in TermRegistry.iris(index)
      assert "#{@owl_ns}Class" in TermRegistry.iris(index)

      # Every source carries the digest it was verified against.
      assert Enum.all?(index.sources, &(byte_size(&1.digest) == 64))
    end

    test "steps 1+2 reuse a real existing public IRI", %{index: index} do
      assert {:ok, resolution} = Iri.resolve("Concept", index: index)
      assert resolution.step == 2
      assert resolution.outcome == :reused_public_iri
      assert resolution.iri == @skos_concept
      assert resolution.steps_attempted == [1, 2]
      assert resolution.exact_matches == [@skos_concept]
    end

    test "step 1 matches a real rdfs:label, not only the local name", %{index: index} do
      assert {:ok, %{iri: "#{@skos_ns}prefLabel"} = resolution} =
               Iri.resolve("preferred label", index: index)

      assert resolution.step == 2
    end

    test "step 3 reuses an equivalent public representation only through an admitted mapping", %{
      index: index
    } do
      # Textual similarity alone is a candidate, never identity (RFC-SA2A-002
      # SA2A-NS-003): without an admitted mapping step 3 refuses.
      assert {:error, %{code: :equivalent_requires_admitted_mapping}} =
               Iri.resolve("Concept", index: index, sufficient?: false)

      target = index |> TermRegistry.search_equivalent("Concept") |> List.last()

      assert {:ok, resolution} =
               Iri.resolve("Concept",
                 index: index,
                 sufficient?: false,
                 mappings: [
                   %{
                     target: target,
                     kind: :close_match,
                     admission_receipt: %{receipt_id: "rcpt-eq", fingerprint: "fp-eq"}
                   }
                 ]
               )

      assert resolution.step == 3
      assert resolution.outcome == :reused_equivalent_public_iri
      assert resolution.steps_attempted == [1, 2, 3]
      assert resolution.iri == target
      assert String.starts_with?(resolution.iri, @skos_ns)
      refute resolution.iri == @skos_concept
    end

    test "step 4 composes multiple public models only with explicit mappings", %{index: index} do
      composition = [@skos_concept, "#{@owl_ns}Class"]

      assert {:error, %{code: :composition_mappings_required, detail: detail}} =
               Iri.resolve("Concept",
                 index: index,
                 sufficient?: false,
                 accept_equivalent?: false,
                 composition: composition
               )

      assert detail =~ @owl_ns

      assert {:ok, resolution} =
               Iri.resolve("Concept",
                 index: index,
                 sufficient?: false,
                 accept_equivalent?: false,
                 composition: composition,
                 mappings: [
                   %{
                     target: @skos_concept,
                     kind: :exact_match,
                     admission_receipt: %{receipt_id: "rcpt-c1", fingerprint: "fp-c1"}
                   },
                   %{
                     target: "#{@owl_ns}Class",
                     kind: :close_match,
                     admission_receipt: %{receipt_id: "rcpt-c2", fingerprint: "fp-c2"}
                   }
                 ]
               )

      assert resolution.step == 4
      assert resolution.outcome == :composed_public_models
      assert resolution.iris == composition
      assert resolution.steps_attempted == [1, 2, 3, 4]
    end

    test "step 4 refuses to compose IRIs that are not in the admitted index", %{index: index} do
      assert {:error, %{code: :composition_requires_admitted_models}} =
               Iri.resolve("Concept",
                 index: index,
                 sufficient?: false,
                 accept_equivalent?: false,
                 composition: [@skos_concept, "https://example.test/vocab#Invented"],
                 mappings: [
                   %{target: @skos_concept, kind: :exact_match},
                   %{target: "https://example.test/vocab#Invented", kind: :close_match}
                 ]
               )
    end

    test "step 5 is REFUSED while a real public term is available", %{index: index} do
      assert {:error, %{code: :private_mint_refused_public_available, detail: detail}} =
               Iri.resolve("Concept",
                 index: index,
                 sufficient?: false,
                 accept_equivalent?: false,
                 private_term: private_term_attrs()
               )

      assert detail =~ @skos_concept
      assert detail =~ "public"
    end

    test "step 5 mints only when the concept is genuinely absent from public sources", %{
      index: index
    } do
      assert {:ok, resolution} =
               Iri.resolve("BerthWindowClearance",
                 index: index,
                 private_term: private_term_attrs()
               )

      assert resolution.step == 5
      assert resolution.outcome == :minted_private_iri
      assert resolution.steps_attempted == [1, 2, 3, 5]
      assert resolution.exact_matches == []
      assert resolution.equivalent_matches == []

      assert %PrivateTerm{iri: "urn:ash-a2a:semantic:BerthWindowClearance"} =
               resolution.private_term
    end

    test "resolve refuses to run at all without a public index" do
      assert {:error, %{code: :public_index_required}} = Iri.resolve("Concept", [])
    end
  end

  # ----------------------------------------- S7.2 private term required fields --

  describe "S7.2 a private term is not mintable without its required fields" do
    test "every required field is enforced by the struct itself" do
      assert_raise ArgumentError, fn ->
        struct!(PrivateTerm, iri: "urn:ash-a2a:semantic:X", label: "X")
      end
    end

    test "a map missing required fields is refused by name, not by raising" do
      attrs = private_term_attrs() |> Map.drop([:provenance, :version, :admission_receipt])

      assert {:error, %{code: :private_term_incomplete, detail: detail}} = Iri.mint_private(attrs)
      assert detail =~ ":admission_receipt"
      assert detail =~ ":provenance"
      assert detail =~ ":version"
    end

    test "a complete private term mints" do
      assert {:ok, %PrivateTerm{} = term} = Iri.mint_private(private_term_attrs())
      assert term.scope == :organization_private
      assert term.version == "2026.09.16"
    end

    test "a real %AshA2A.Receipt{} satisfies the admission-receipt requirement" do
      receipt = real_receipt()
      assert %Receipt{status: :pending} = receipt

      assert {:ok, %PrivateTerm{admission_receipt: %Receipt{}}} =
               Iri.mint_private(private_term_attrs(%{admission_receipt: receipt}))
    end

    test "an unpinned version is refused" do
      for version <- ["latest", "main", ""] do
        assert {:error, %{code: :private_term_version_unpinned}} =
                 Iri.mint_private(private_term_attrs(%{version: version}))
      end
    end

    test "minting without a recorded public search is refused" do
      assert {:error, %{code: :private_mint_search_unrecorded}} =
               Iri.mint_private(
                 private_term_attrs(%{
                   provenance: %{searched_sources: [], public_absence_reason: "none found"}
                 })
               )

      assert {:error, %{code: :private_mint_search_unrecorded}} =
               Iri.mint_private(
                 private_term_attrs(%{
                   provenance: %{searched_sources: [@skos_ns], public_absence_reason: "  "}
                 })
               )
    end

    test "a public scope is not mintable and an out-of-namespace IRI is refused" do
      assert {:error, %{code: :private_term_scope_invalid}} =
               Iri.mint_private(private_term_attrs(%{scope: :public}))

      assert {:error, %{code: :private_term_namespace_mismatch}} =
               Iri.mint_private(
                 private_term_attrs(%{owning_namespace: "urn:some-other-org:semantic:"})
               )
    end

    test "an unadmitted receipt and an invalid mapping are refused" do
      assert {:error, %{code: :private_term_receipt_missing}} =
               Iri.mint_private(private_term_attrs(%{admission_receipt: %{receipt_id: "r"}}))

      assert {:error, %{code: :private_term_mapping_invalid}} =
               Iri.mint_private(
                 private_term_attrs(%{mappings: [%{target: @skos_concept, kind: :same_as}]})
               )
    end
  end

  # ------------------------- S7.3 no runtime semantic individualism (Strict) --

  describe "S7.3 no runtime semantic individualism" do
    test "an admitted term may be used as operational semantics", %{index: index} do
      assert {:ok, {:admitted, @skos_concept}} =
               TermRegistry.admit_operational_use(index, @skos_concept, consequential?: true)

      assert TermRegistry.operational?(index, @skos_concept)
    end

    test "a term invented at runtime is REFUSED during consequential operation", %{index: index} do
      invented = "urn:ash-a2a:semantic:JustInventedRightNow"

      assert {:error, refusal} =
               TermRegistry.admit_operational_use(index, invented, consequential?: true)

      assert refusal.code == :runtime_semantic_individualism_refused
      assert refusal.return_to == :admission
      assert refusal.candidate == invented
      assert refusal.profile == :strict
      refute TermRegistry.operational?(index, invented)
    end

    test "a novel term outside consequential operation is a candidate, never operational", %{
      index: index
    } do
      invented = "urn:ash-a2a:semantic:JustInventedRightNow"

      assert {:ok, {:candidate, ^invented}} =
               TermRegistry.admit_operational_use(index, invented, consequential?: false)

      refute TermRegistry.operational?(index, invented, consequential?: false)
    end

    test "the Permissive profile still never makes a novel term operational", %{index: index} do
      invented = "urn:ash-a2a:semantic:JustInventedRightNow"

      assert {:ok, {:candidate, ^invented}} =
               TermRegistry.admit_operational_use(index, invented,
                 profile: :permissive,
                 consequential?: true
               )

      refute TermRegistry.operational?(index, invented, profile: :permissive)
    end

    test "an unknown profile is refused rather than silently defaulted", %{index: index} do
      assert {:error, %{code: :semantic_profile_unknown}} =
               TermRegistry.admit_operational_use(index, @skos_concept, profile: :relaxed)
    end
  end

  # ------------------------------------------ S47 no silent semantic drift --

  describe "S47 cross-peer semantic identity" do
    test "identical semantic identity reconciles" do
      registry = MappingRegistry.new()

      assert {:ok, %{outcome: :same_semantic_identity, kind: :exact_match}} =
               MappingRegistry.reconcile(
                 registry,
                 %{peer_id: "peer-a", label: "Concept", iri: @skos_concept},
                 %{peer_id: "peer-b", label: "concept", iri: @skos_concept}
               )
    end

    test "matching labels with different identities and no mapping are REFUSED" do
      registry = MappingRegistry.new()

      assert {:error, refusal} =
               MappingRegistry.reconcile(
                 registry,
                 %{
                   peer_id: "peer-a",
                   label: "Settlement",
                   iri: "https://a.test/vocab#Settlement"
                 },
                 %{peer_id: "peer-b", label: "Settlement", iri: "https://b.test/vocab#Settlement"}
               )

      assert refusal.code == :semantic_label_collision_unmapped
      assert refusal.detail =~ "does not imply"
      assert refusal.detail =~ "https://a.test/vocab#Settlement"
      assert refusal.detail =~ "https://b.test/vocab#Settlement"
    end

    test "an explicitly admitted mapping reconciles the same pair" do
      {registry, receipt} =
        admitted_mapping(
          "https://a.test/vocab#Settlement",
          "https://b.test/vocab#Settlement",
          :close_match
        )

      assert {:ok, registry} =
               MappingRegistry.register(registry, %{
                 source: "https://a.test/vocab#Settlement",
                 target: "https://b.test/vocab#Settlement",
                 kind: :close_match,
                 admission_receipt: receipt
               })

      assert {:ok, %{outcome: :admitted_mapping, kind: :close_match}} =
               MappingRegistry.reconcile(
                 registry,
                 %{
                   peer_id: "peer-a",
                   label: "Settlement",
                   iri: "https://a.test/vocab#Settlement"
                 },
                 %{peer_id: "peer-b", label: "Settlement", iri: "https://b.test/vocab#Settlement"}
               )
    end

    test "a mapping is directional-aware: broad one way is narrow the other" do
      {registry, receipt} =
        admitted_mapping("https://a.test/vocab#Vessel", "https://b.test/vocab#Ship", :broad_match)

      assert {:ok, registry} =
               MappingRegistry.register(registry, %{
                 source: "https://a.test/vocab#Vessel",
                 target: "https://b.test/vocab#Ship",
                 kind: :broad_match,
                 admission_receipt: receipt
               })

      assert {:ok, %{kind: :broad_match}} =
               MappingRegistry.lookup(
                 registry,
                 "https://a.test/vocab#Vessel",
                 "https://b.test/vocab#Ship"
               )

      assert {:ok, %{kind: :narrow_match}} =
               MappingRegistry.lookup(
                 registry,
                 "https://b.test/vocab#Ship",
                 "https://a.test/vocab#Vessel"
               )

      assert length(MappingRegistry.mappings(registry)) == 1
    end

    test "a mapping cannot be asserted into existence without admission" do
      assert {:error, %{code: :semantic_mapping_unadmitted}} =
               MappingRegistry.register(MappingRegistry.new(), %{
                 source: "https://a.test/vocab#Settlement",
                 target: "https://b.test/vocab#Settlement",
                 kind: :exact_match
               })

      assert {:error, %{code: :semantic_mapping_kind_invalid}} =
               MappingRegistry.register(MappingRegistry.new(), %{
                 source: "https://a.test/vocab#Settlement",
                 target: "https://b.test/vocab#Settlement",
                 kind: :same_as,
                 admission_receipt: %{receipt_id: "r", fingerprint: "f"}
               })

      assert {:error, %{code: :semantic_mapping_degenerate}} =
               MappingRegistry.register(MappingRegistry.new(), %{
                 source: @skos_concept,
                 target: @skos_concept,
                 kind: :exact_match,
                 admission_receipt: %{receipt_id: "r", fingerprint: "f"}
               })
    end

    test "a real %AshA2A.Receipt{} held by a receipt store admits a mapping" do
      {registry, receipt} =
        admitted_mapping(
          "https://a.test/vocab#Settlement",
          "https://b.test/vocab#Settlement",
          :exact_match
        )

      assert {:ok, _registry} =
               MappingRegistry.register(registry, %{
                 source: "https://a.test/vocab#Settlement",
                 target: "https://b.test/vocab#Settlement",
                 kind: :exact_match,
                 admission_receipt: receipt
               })
    end

    test "a named, unheld, or unbound receipt admits nothing (RFC-SA2A-001 S6)" do
      mapping = %{
        source: "https://a.test/vocab#Settlement",
        target: "https://b.test/vocab#Settlement",
        kind: :exact_match
      }

      {registry, receipt} = admitted_mapping(mapping.source, mapping.target, :exact_match)

      named = Map.put(mapping, :admission_receipt, %{receipt_id: "r", fingerprint: "f"})

      assert {:error, %{code: :semantic_mapping_receipt_not_held}} =
               MappingRegistry.register(registry, named)

      # A real receipt that was never committed to the registry's store.
      assert {:error, %{code: :semantic_mapping_receipt_not_held}} =
               MappingRegistry.register(
                 registry,
                 Map.put(mapping, :admission_receipt, real_receipt())
               )

      # The held receipt, but for a different mapping kind.
      assert {:error, %{code: :semantic_mapping_receipt_unbound}} =
               MappingRegistry.register(
                 registry,
                 %{mapping | kind: :close_match} |> Map.put(:admission_receipt, receipt)
               )

      assert AshA2A.Semantic.Refusal.classify(:semantic_mapping_receipt_not_held) ==
               :refused_receipt

      assert AshA2A.Semantic.Refusal.classify(:semantic_mapping_receipt_unbound) ==
               :refused_receipt
    end

    test "a capability claimed with a label but no semantic identity is refused" do
      assert {:error, %{code: :semantic_identity_absent, detail: detail}} =
               MappingRegistry.reconcile(
                 MappingRegistry.new(),
                 %{peer_id: "peer-a", label: "Settlement"},
                 %{peer_id: "peer-b", label: "Settlement", iri: "https://b.test/vocab#Settlement"}
               )

      assert detail =~ "a label alone is not a semantic identity"
    end

    test "unrelated identities with unrelated labels are refused distinctly" do
      assert {:error, %{code: :semantic_identity_unmapped}} =
               MappingRegistry.reconcile(
                 MappingRegistry.new(),
                 %{
                   peer_id: "peer-a",
                   label: "Settlement",
                   iri: "https://a.test/vocab#Settlement"
                 },
                 %{peer_id: "peer-b", label: "Berth", iri: "https://b.test/vocab#Berth"}
               )
    end
  end

  # -------------------------------------- S46 ontology import discipline ----

  describe "S46 pinned, content-addressed local ontology cache" do
    test "the shipped manifest is explicit, version-pinned and content-addressed" do
      assert {:ok, entries} = OntologyCache.manifest()
      assert length(entries) == 4

      for entry <- entries do
        assert {:ok, _} = Iri.validate(entry.iri)
        assert entry.version not in ["", "latest", "main"]
        assert byte_size(entry.content_digest) == 64
        assert String.starts_with?(entry.object, "objects/")
      end
    end

    test "loading re-verifies the pinned digest against the real bytes on disk" do
      assert {:ok, %{body: body, digest: digest, entry: entry}} = OntologyCache.load(@skos_ns)

      assert digest == entry.content_digest
      assert digest == OntologyCache.digest(body)
      assert byte_size(body) == entry.byte_size
      # Real SKOS content, not a placeholder.
      assert body =~ "skos:prefLabel"
    end

    @tag :tmp_dir
    test "a drifted cached document fails CLOSED", %{tmp_dir: tmp_dir} do
      root = Path.join(tmp_dir, "ontology_cache")
      File.mkdir_p!(root)
      File.cp_r!(OntologyCache.default_root(), root)

      assert {:ok, entry} = OntologyCache.entry(@skos_ns, root: root)
      object_path = Path.join(root, entry.object)
      original = File.read!(object_path)

      # Same byte length, different bytes: this exercises the digest check, not
      # the cheaper size check.
      drifted = String.replace(original, "skos:prefLabel", "skos:prefLabeX", global: false)
      assert byte_size(drifted) == byte_size(original)
      assert drifted != original
      File.write!(object_path, drifted)

      assert {:error, refusal} = OntologyCache.load(@skos_ns, root: root)
      assert refusal.code == :ontology_digest_drift
      assert refusal.detail =~ entry.content_digest
      assert refusal.detail =~ "failing closed"

      # Building the term index over a drifted cache fails closed too -- drifted
      # terms never enter the admitted set.
      assert {:error, %{code: :ontology_digest_drift}} = TermRegistry.from_cache(root: root)
    end

    @tag :tmp_dir
    test "a missing pinned object fails closed", %{tmp_dir: tmp_dir} do
      root = Path.join(tmp_dir, "ontology_cache")
      File.mkdir_p!(root)
      File.cp_r!(OntologyCache.default_root(), root)

      assert {:ok, entry} = OntologyCache.entry(@owl_ns, root: root)
      File.rm!(Path.join(root, entry.object))

      assert {:error, %{code: :ontology_object_missing}} = OntologyCache.load(@owl_ns, root: root)
    end

    test "an unpinned import declaration is refused" do
      for version <- ["latest", "main", nil, ""] do
        assert {:error, %{code: :ontology_import_unpinned}} =
                 OntologyCache.admit_import(%{iri: @skos_ns, version: version})
      end
    end

    test "a correctly pinned import is admitted and its digest verified end to end" do
      assert {:ok, entry} =
               OntologyCache.admit_import(%{
                 iri: @skos_ns,
                 version: "hex:rdf@3.0.1",
                 content_digest:
                   "1d7b360c673f95d8d4e2a5b981e1d02dcb06217b715dc72bd8ec868d0389719b"
               })

      assert entry.iri == @skos_ns
    end

    test "an import declaring the wrong digest or wrong version is refused" do
      assert {:error, %{code: :ontology_digest_drift}} =
               OntologyCache.admit_import(%{
                 iri: @skos_ns,
                 version: "hex:rdf@3.0.1",
                 content_digest: String.duplicate("0", 64)
               })

      assert {:error, %{code: :ontology_version_mismatch}} =
               OntologyCache.admit_import(%{iri: @skos_ns, version: "hex:rdf@9.9.9"})
    end

    test "an unpinned IRI is a cache miss, never a fetch" do
      assert {:error, %{code: :ontology_cache_miss, detail: detail}} =
               OntologyCache.load("http://www.w3.org/ns/prov#")

      assert detail =~ "remote dereference is refused"
    end

    test "remote dereference at admission time is an executable refusal" do
      assert {:error, %{code: :ontology_remote_dereference_refused, detail: detail}} =
               OntologyCache.dereference("http://www.w3.org/ns/prov#")

      assert detail =~ "never fetched at execution time"
    end

    test "canonicalization is never computed locally -- it is pinned or refused" do
      assert {:error, %{code: :canonicalization_not_local, detail: detail}} =
               OntologyCache.canonical_digest(@skos_ns)

      assert detail =~ "praxis-graphlaw"
      assert detail =~ "graph_hash"
    end

    test "prefix backing is reported honestly: only locally-cached documents count as backed" do
      report = OntologyCache.prefix_backing_report()
      assert length(report) == map_size(Vocabulary.prefixes())

      backed = for %{prefix: p, backing: :local_document} <- report, do: p
      unbacked = for %{prefix: p, backing: :prefix_only} <- report, do: p

      assert Enum.sort(backed) == ["owl", "rdf", "rdfs", "skos"]

      # Current truth: the vocabulary registry grew the in-repo `a2a` and
      # `sa2a-*` (FND/CAP/BP/EVI) namespaces; none of them ships a locally
      # cached document yet, so they are honestly reported :prefix_only.
      assert Enum.sort(unbacked) == [
               "a2a",
               "oa",
               "odrl",
               "prov",
               "qudt",
               "sa2a-bp",
               "sa2a-cap",
               "sa2a-evi",
               "sa2a-fnd",
               "saref",
               "schema",
               "sosa",
               "ssn",
               "time"
             ]
    end
  end

  # ------------------------------- S45 immutability + declared compatibility --

  describe "S45 admitted artifacts are immutable by semantic identity" do
    test "the same identity and version with different content is REFUSED" do
      {:ok, v1} = Revision.new("urn:ash-a2a:semantic:BerthPolicy", "2026.09.01", "policy: A")
      {:ok, mutated} = Revision.new("urn:ash-a2a:semantic:BerthPolicy", "2026.09.01", "policy: B")

      assert {:error, refusal} = Revision.check_immutable(v1, mutated)
      assert refusal.code == :admitted_artifact_mutation_refused
      assert refusal.detail =~ "immutable by semantic identity"
    end

    test "re-admitting byte-identical content under the same version is not a mutation" do
      {:ok, v1} = Revision.new("urn:ash-a2a:semantic:BerthPolicy", "2026.09.01", "policy: A")
      {:ok, again} = Revision.new("urn:ash-a2a:semantic:BerthPolicy", "2026.09.01", "policy: A")

      assert v1.content_digest == again.content_digest
      assert :ok = Revision.check_immutable(v1, again)
    end

    test "a change creates a NEW revision that supersedes the old digest" do
      {:ok, v1} = Revision.new("urn:ash-a2a:semantic:BerthPolicy", "2026.09.01", "policy: A")
      assert {:ok, v2} = Revision.revise(v1, "2026.09.16", "policy: B")

      assert v2.calver == "2026.09.16"
      assert v2.supersedes == v1.content_digest
      assert v2.content_digest != v1.content_digest
      assert v2.compatible_with == []
    end

    test "revising without changing the version is refused" do
      {:ok, v1} = Revision.new("urn:ash-a2a:semantic:BerthPolicy", "2026.09.01", "policy: A")

      assert {:error, %{code: :admitted_artifact_mutation_refused}} =
               Revision.revise(v1, "2026.09.01", "policy: B")
    end
  end

  describe "S45 compatibility is declared separately from version numbering" do
    setup do
      {:ok, old} = Revision.new("urn:ash-a2a:semantic:BerthPolicy", "2026.08.01", "policy: A")
      {:ok, new} = Revision.revise(old, "2026.09.16", "policy: B")
      %{old: old, new: new}
    end

    test "a strictly NEWER CalVer is NOT assumed compatible", %{old: old, new: new} do
      assert Revision.compare_calver(old.calver, new.calver) == :lt

      assert {:error, refusal} = Revision.compatible?(old, new)
      assert refusal.code == :compatibility_undeclared
      assert refusal.ordering == :lt
      assert refusal.detail =~ "a newer CalVer MUST NOT be assumed compatible"
    end

    test "an explicit declaration -- and only that -- establishes compatibility", %{
      old: old,
      new: new
    } do
      declared = %{new | compatible_with: [old.content_digest]}

      assert {:ok, %{compatible: true, basis: :declared, from: "2026.08.01", to: "2026.09.16"}} =
               Revision.compatible?(old, declared)

      # Still directional: the reverse direction was never declared.
      assert {:error, %{code: :compatibility_undeclared}} = Revision.compatible?(declared, old)

      assert {:ok, %{basis: :declared}} =
               Revision.compatible?(declared, old, bidirectional: true)
    end

    test "compatibility across different semantic identities is a category error" do
      {:ok, a} = Revision.new("urn:ash-a2a:semantic:A", "2026.09.01", "a")
      {:ok, b} = Revision.new("urn:ash-a2a:semantic:B", "2026.09.02", "b")

      assert {:error, %{code: :compatibility_cross_identity, detail: detail}} =
               Revision.compatible?(a, b)

      assert detail =~ "MappingRegistry"
    end

    test "CalVer parsing and ordering are real" do
      assert Revision.compare_calver("2026.9", "2026.10") == :lt
      assert Revision.compare_calver("2026.09.16", "2026.09.16") == :eq
      assert Revision.compare_calver("2027.01", "2026.12.31") == :gt

      assert {:error, %{code: :calver_invalid}} = Revision.compare_calver("v1.2.3", "2026.09")

      assert {:error, %{code: :calver_invalid}} =
               Revision.new("urn:ash-a2a:semantic:X", "1.2.3", "x")
    end
  end

  # ------------------------------------------- Vocabulary is extended, not broken --

  describe "AshA2A.Semantic.Vocabulary behavior is preserved" do
    test "the existing prefix registry and expand/1 are unchanged" do
      assert Vocabulary.expand("skos:Concept") == @skos_concept
      assert Vocabulary.expand("rdf:type") == "http://www.w3.org/1999/02/22-rdf-syntax-ns#type"
      assert Vocabulary.expand("prov:Activity") == "http://www.w3.org/ns/prov#Activity"
    end

    test "Vocabulary.local/1 still mints, and Iri classifies what it mints as private" do
      minted = Vocabulary.local("berth window clearance")
      assert minted == "urn:ash-a2a:semantic:berth_window_clearance"

      # The gap this module closes: local/1's output carries no provenance,
      # version or admission -- it is a private IRI, and under Strict profile it
      # is not usable as operational semantics until admitted.
      assert Iri.classify(minted) == :private
    end

    test "an IRI minted by Vocabulary.local/1 is refused as operational semantics", %{
      index: index
    } do
      minted = Vocabulary.local("berth window clearance")

      assert {:error, %{code: :runtime_semantic_individualism_refused}} =
               TermRegistry.admit_operational_use(index, minted, consequential?: true)
    end
  end
end

# --- SECTION 3: Original test/ash_a2a/semantic_law_document_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SemanticLawDocumentTest do
  @moduledoc """
  Chicago-school tests for `AshA2A.Semantic.LawDocument`.

  Real RDF.ex parsing of real Turtle, real `Jason` decoding of real ShExJ, and
  a real character scan over real N3 -- every collaborator here is runnable
  in-process, so nothing is mocked and nothing is stubbed. Assertions are on
  the real returned counts and the real returned failure maps.
  """

  use ExUnit.Case, async: true

  doctest AshA2A.Semantic.LawDocument

  alias AshA2A.Semantic.LawDocument
  alias AshA2A.Test.SA2AAdmissionFixtures, as: Fixtures

  describe "turtle_graph/1 fails closed where the wasm export does not" do
    test "garbage is an error, not an empty graph" do
      assert {:error, failure} = LawDocument.turtle_graph("@@@ not turtle at all ;;; <<<")
      assert failure.code == :turtle_not_parseable
      assert failure.reason =~ "Turtle scanner error"
    end

    test "real Turtle parses to a real graph" do
      assert {:ok, graph} = LawDocument.turtle_graph(Fixtures.conforming_graph())
      assert RDF.Graph.triple_count(graph) == 3
    end
  end

  describe "shacl_shape_count/1" do
    test "the real shapes fixture declares a real shape" do
      assert {:ok, count} = LawDocument.shacl_shape_count(Fixtures.shacl_shapes())
      assert count >= 1
    end

    test "a document that parses but declares no shape counts zero" do
      for vacuous <- ["#", "", "@prefix sh: <http://www.w3.org/ns/shacl#> .", "   "] do
        assert {:ok, 0} = LawDocument.shacl_shape_count(vacuous)
      end
    end

    test "a subject carrying only sh:targetClass still counts as a shape" do
      doc = """
      @prefix sh: <http://www.w3.org/ns/shacl#> .
      @prefix ex: <http://example.org/> .
      ex:S sh:targetClass ex:Goal .
      """

      assert {:ok, 1} = LawDocument.shacl_shape_count(doc)
    end

    test "unparseable shapes are a typed failure, never a zero count" do
      assert {:error, %{code: :turtle_not_parseable}} = LawDocument.shacl_shape_count("@@@")
    end
  end

  describe "owl_axiom_count/1" do
    test "the real profile fixture declares a real axiom" do
      assert {:ok, 1} = LawDocument.owl_axiom_count(Fixtures.profile())
    end

    test "Turtle carrying no OWL/RDFS vocabulary constrains nothing" do
      assert {:ok, 0} =
               LawDocument.owl_axiom_count("<http://a/s> <http://a/p> <http://a/o> .")
    end

    test "rdfs vocabulary counts as a profile axiom" do
      assert {:ok, 1} =
               LawDocument.owl_axiom_count(
                 "<http://a/A> <http://www.w3.org/2000/01/rdf-schema#subClassOf> <http://a/B> ."
               )
    end
  end

  describe "shex_shape_count/1 and shex_shape_map_count/1" do
    test "the real ShExJ fixture declares one shape and the shape map one binding" do
      assert {:ok, 1} = LawDocument.shex_shape_count(Fixtures.shex_schema())
      assert {:ok, 1} = LawDocument.shex_shape_map_count(Fixtures.shex_shape_map())
    end

    test "an empty schema and an empty shape map both count zero" do
      assert {:ok, 0} = LawDocument.shex_shape_count(~s({"shapes":[]}))
      assert {:ok, 0} = LawDocument.shex_shape_map_count("[]")
    end

    test "non-JSON law is a typed failure, never a zero count" do
      assert {:error, %{code: :shex_schema_not_json}} = LawDocument.shex_shape_count("#")
      assert {:error, %{code: :shex_shape_map_not_json}} = LawDocument.shex_shape_map_count("#")
      assert {:error, %{code: :shex_schema_not_an_object}} = LawDocument.shex_shape_count("[]")

      assert {:error, %{code: :shex_shape_map_not_a_list}} =
               LawDocument.shex_shape_map_count("{}")

      assert {:error, %{code: :shex_schema_has_no_shapes_key}} =
               LawDocument.shex_shape_count(~s({"other":1}))
    end
  end

  describe "n3_rule_count/1 recognises statements, never evaluates them" do
    test "the real falsifier fixture declares one rule" do
      assert LawDocument.n3_rule_count(Fixtures.falsifiers()) == 1
    end

    test "the verifier's minimal repro -- a lone comment declares zero rules" do
      assert LawDocument.n3_rule_count("#") == 0
      assert LawDocument.n3_rule_count("") == 0
      assert LawDocument.n3_rule_count("@prefix ex: <http://example.org/> .") == 0
    end

    test "a commented-out rule is not a rule" do
      assert LawDocument.n3_rule_count("# { ?s a ex:Forbidden } => false .") == 0
    end

    test "an implication arrow inside a string literal is not a rule" do
      assert LawDocument.n3_rule_count(~s(<a:s> <a:p> "a => b" .)) == 0
      assert LawDocument.n3_rule_count(~s(<a:s> <a:p> 'a => b' .)) == 0
      assert LawDocument.n3_rule_count(~s(<a:s> <a:p> """a => b""" .)) == 0
    end

    test "an implication arrow inside an IRI is not a rule" do
      assert LawDocument.n3_rule_count("<http://a/x=>y> <a:p> <a:o> .") == 0
    end

    test "several real rules are all counted" do
      doc = """
      @prefix ex: <http://example.org/> .
      { ?s a ex:Forbidden } => false .
      { ?s a ex:AlsoForbidden } => false .
      """

      assert LawDocument.n3_rule_count(doc) == 2
    end
  end
end

# --- SECTION 4: Original test/ash_a2a/semantic_nonllm_hddl_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Semantic.NonllmHddlTest do
  @moduledoc """
  Task 4 + 5 of the deterministic (non-LLM) HDDL planning path: real,
  end-to-end coverage of the full non-LLM path -- a caller submitting typed
  goal facts (never free text) all the way through
  `AshA2A.Planning.HddlDeterministicSynthesis.synthesize/3` to a real,
  candidate-only `AshA2A.Semantic.ExecutionPackage`, and back out through
  `ExecutionPackage.to_reply/1` -- with zero LLM/network calls anywhere in
  the trace, proven by inspection of the real collaborators this path calls
  (`AshA2A.Planning.GoalFacts`, `AshA2A.Planning.HddlRenderer`,
  `AshA2A.Planning.HddlSolver`, `AshA2A.Planning.from_envelope/3`,
  `AshA2A.Semantic.ExecutionPackage.new/6`), none of which import or call
  `Req`/`Finch`/`HTTPoison`/`ReqLLM` or any other HTTP client -- confirmed by
  a real `mix xref` / grep pass reported alongside this file's own test
  output, not asserted here as a runtime check (there is no HTTP client
  dependency anywhere in this call graph to intercept).

  Chicago-style throughout: real fixture resource
  (`AshA2A.Test.Fixture.HddlDeterministicFixture`,
  `test/support/fixture.ex`), real compiled capability index, a real OS
  subprocess invocation of the real, CI-built `native/hddl_cli` binary
  (`AshA2A.Planning.HddlSolver.solve/3`), and assertions against the real
  returned/decoded state -- never a call-count or "was this called"
  interaction assertion. This file declares and uses no test double of any
  kind, per this workspace's testing-discipline rule; the real repo-wide
  banned-pattern sweep (expect zero matches over this file) is part of this
  task's own reported verification evidence, not asserted here.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Planning.HddlDeterministicSynthesis
  alias AshA2A.Planning.HddlRenderer
  alias AshA2A.Semantic.ExecutionPackage
  alias AshA2A.Test.Fixture.HddlDeterministicFixture

  @advance_id "AshA2A.Test.Fixture.HddlDeterministicFixture.advance"
  @unlock_id "AshA2A.Test.Fixture.HddlDeterministicFixture.unlock"

  defp base_envelope(overrides \\ %{}) do
    Map.merge(
      %{
        "request_id" => "nonllm-hddl-e2e-#{System.unique_integer([:positive])}",
        "domain_name" => "nonllm-e2e-domain",
        "problem_name" => "nonllm-e2e-problem",
        "objects" => ["on", "off"],
        "init" => [%{"predicate" => "current_phase", "args" => ["on"]}],
        "goal" => [
          %{"predicate" => "current_phase", "args" => ["off"]},
          %{"predicate" => "has_key", "args" => ["off"]}
        ],
        "task_sequence" => [
          %{"capability_id" => @advance_id, "args" => ["on", "off"]},
          %{"capability_id" => @unlock_id, "args" => ["off"]}
        ]
      },
      overrides
    )
  end

  describe "full non-LLM path end to end (positive)" do
    test "a real typed goal-facts envelope synthesizes into a real, solver-verified candidate-only ExecutionPackage" do
      envelope = base_envelope()

      assert {:ok, %ExecutionPackage{} = package} =
               HddlDeterministicSynthesis.synthesize(HddlDeterministicFixture, envelope)

      # Real candidate-only authority ceiling, on every layer of the package
      # -- never an execution/DO standing.
      assert package.standing == :candidate
      assert package.authority == :none
      assert package.semantic_ir.standing == :admitted
      assert package.semantic_ir.authority == :none
      assert package.ontology.authority == :none
      assert package.planning_ir.authority == :none
      assert package.plan_candidate.standing == :candidate
      assert package.plan_candidate.authority == :none

      # The already-admitted capability_ids came from GoalFacts.admit/2 (this
      # test's own submitted task_sequence order), never re-derived from a
      # model's free-text claim -- the direct pass-through the design plan's
      # Task 4 note describes.
      assert package.plan_candidate.capability_ids == [@advance_id, @unlock_id]

      # A real, content-addressed fingerprint (sha256/hex), not a placeholder.
      assert package.fingerprint =~ ~r/^[0-9a-f]{64}$/

      # The package's source is the real HDDL text this path itself rendered
      # and solved -- genuine machine-rendered domain+problem text, not a
      # natural-language string an LLM would have had to interpret.
      assert package.source.media_type == "application/hddl"
      assert package.source.text =~ "(define (domain nonllm-e2e-domain)"
      assert package.source.text =~ "(define (problem nonllm-e2e-problem)"

      synthesis = package.plan_candidate.plan["synthesis"]
      assert synthesis["role"] == "hddl_solver"
      assert synthesis["rationale"] =~ "No LLM call occurred."

      # The embedded "fond" field is the real hddl_cli binary's own stdout
      # JSON -- decode it for real and assert on the real solved-plan shape,
      # not a hand-built stand-in for what a solver "would" return.
      assert {:ok, decoded_plan} = JSON.decode(synthesis["fond"])
      assert decoded_plan["solved"] == true
      refute Map.has_key?(decoded_plan, "error")

      real_actions =
        decoded_plan["policy"]
        |> Enum.map(& &1["action"])
        |> Enum.reject(&String.starts_with?(&1, "htn:decompose:"))

      advance_action_name = HddlRenderer.safe_name(@advance_id)
      unlock_action_name = HddlRenderer.safe_name(@unlock_id)

      assert Enum.any?(real_actions, &(&1 =~ "#{advance_action_name}(on,off)"))
      assert Enum.any?(real_actions, &(&1 =~ "#{unlock_action_name}(off)"))

      # ExecutionPackage.to_reply/1 produces the real A2A reply shape, with
      # the real submitted capability_ids and the real solved hddl/fond text
      # -- the same contract the LLM-driven semantic path returns, satisfied
      # here by a genuinely different, non-LLM producer.
      assert {:reply, [%AshA2A.Protocol.Part.Data{} = part]} = ExecutionPackage.to_reply(package)
      assert part.data["standing"] == "candidate"
      assert part.data["authority"] == "none"
      assert part.data["capability_ids"] == [@advance_id, @unlock_id]
      assert part.data["execution_package_fingerprint"] == package.fingerprint
      assert part.data["hddl"] == package.source.text
      assert {:ok, ^decoded_plan} = JSON.decode(part.data["fond"])
    end

    test "additivity regression guard: a real skill declaring no hddl_operator still carries hddl_operators: []" do
      # Proves the additive `hddl_operators` field (Task 1) does not disturb
      # any pre-existing capability that never opted into the deterministic
      # HDDL path -- a real compiled skill from `AshA2A.Test.Fixture.Echo`
      # (no `hddl_operator` block anywhere in its `a2a do ... end`).
      assert {:ok, skill} = AshA2A.Info.skill(AshA2A.Test.Fixture.Echo, "echo")
      assert skill.hddl_operators == []
    end
  end

  describe "negative control: closed capability-id set (proves the grounding check is real, not a no-op)" do
    test "a task_sequence entry naming a capability_id outside the compiled index is refused before any solver subprocess runs" do
      envelope =
        base_envelope(%{
          "task_sequence" => [
            %{"capability_id" => @advance_id, "args" => ["on", "off"]},
            %{
              "capability_id" => "AshA2A.Test.Fixture.HddlDeterministicFixture.teleport",
              "args" => ["off"]
            }
          ]
        })

      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "ash_a2a_nonllm_hddl_negctrl_capability_#{System.unique_integer([:positive])}"
        )

      refute File.exists?(tmp_dir)

      assert {:error,
              %{
                code: :noncanonical_capability,
                detail: "AshA2A.Test.Fixture.HddlDeterministicFixture.teleport"
              }} =
               HddlDeterministicSynthesis.synthesize(HddlDeterministicFixture, envelope,
                 solver_opts: [tmp_dir: tmp_dir]
               )

      # Real proof (not a call-count/interaction assertion) that the real
      # `hddl_cli` subprocess was never invoked for this refused envelope:
      # `HddlSolver.solve/3` always writes its two real temp files under
      # `solver_opts[:tmp_dir]` before shelling out, so a directory that was
      # never even created is real, structural evidence no solver
      # subprocess ran -- the admission fence refused before the pipeline
      # reached `HddlSolver.solve/3` at all.
      refute File.exists?(tmp_dir)
    end

    test "an unrelated resource's real capability id is refused as noncanonical against this fixture's own compiled index" do
      envelope =
        base_envelope(%{
          "task_sequence" => [%{"capability_id" => "AshA2A.Test.Fixture.Echo.echo", "args" => []}]
        })

      assert {:error, %{code: :noncanonical_capability, detail: "AshA2A.Test.Fixture.Echo.echo"}} =
               HddlDeterministicSynthesis.synthesize(HddlDeterministicFixture, envelope)
    end
  end

  describe "negative control: request_id cannot smuggle an unverified capability id (real adversarial finding, closed)" do
    test "a non-string request_id is refused before any admission check runs" do
      envelope = base_envelope(%{"request_id" => %{"capability_id" => @unlock_id}})

      assert {:error, %{code: :invalid_request_id}} =
               HddlDeterministicSynthesis.synthesize(HddlDeterministicFixture, envelope)
    end

    test "the exact adversarial envelope constructed against this fixture during review no longer smuggles unlock into capability_ids" do
      # This session's own adversarial verification pass constructed exactly
      # this envelope by hand (task_sequence names only :advance; :unlock is
      # named nowhere except a nested "capability_id" key inside request_id)
      # and confirmed, via a real run, that AshA2A.Planning.collect/2's
      # whole-envelope deep-walk harvested the unlock id into the final
      # package's capability_ids even though it was never admitted or
      # solver-verified for this request. validate_request_id/1 closes this
      # at the source: request_id may only be nil or a plain string now.
      envelope =
        base_envelope(%{
          "request_id" => %{"capability_id" => @unlock_id},
          "task_sequence" => [%{"capability_id" => @advance_id, "args" => ["on", "off"]}],
          "goal" => [%{"predicate" => "current_phase", "args" => ["off"]}]
        })

      assert {:error, %{code: :invalid_request_id}} =
               HddlDeterministicSynthesis.synthesize(HddlDeterministicFixture, envelope)
    end
  end

  describe "negative control: referential and predicate closure" do
    test "a goal fact referencing an undeclared object id is refused" do
      envelope =
        base_envelope(%{
          "goal" => [%{"predicate" => "current_phase", "args" => ["nonexistent-object"]}]
        })

      assert {:error, %{code: :undeclared_object, detail: "nonexistent-object"}} =
               HddlDeterministicSynthesis.synthesize(HddlDeterministicFixture, envelope)
    end

    test "a goal fact using a predicate the domain never declares is refused" do
      envelope =
        base_envelope(%{
          "goal" => [%{"predicate" => "current_phase", "args" => ["off"]}],
          "init" => [
            %{"predicate" => "current_phase", "args" => ["on"]},
            %{"predicate" => "unmodeled_predicate", "args" => ["on"]}
          ]
        })

      assert {:error, %{code: :undeclared_predicate, detail: "unmodeled_predicate"}} =
               HddlDeterministicSynthesis.synthesize(HddlDeterministicFixture, envelope)
    end

    test "an empty task_sequence is refused before any admission logic runs" do
      envelope = base_envelope(%{"task_sequence" => []})

      assert {:error, %{code: :empty_task_sequence}} =
               HddlDeterministicSynthesis.synthesize(HddlDeterministicFixture, envelope)
    end
  end

  describe "negative control: a genuinely unreachable goal (real solver refusal, not a fabricated result)" do
    test "a real unsatisfiable goal is admitted (closed-set checks pass) but the real solver reports it cannot be reached" do
      envelope =
        base_envelope(%{
          # Only :advance is proposed; the real domain's :unlock operator
          # never fires, so has_key(off) is never asserted -- a genuinely
          # unreachable goal from the real solver's point of view, not an
          # admission-fence refusal (every capability id, object, and
          # predicate here is real and declared).
          "task_sequence" => [%{"capability_id" => @advance_id, "args" => ["on", "off"]}]
        })

      assert {:error, %{code: :hddl_solve_error} = decoded} =
               HddlDeterministicSynthesis.synthesize(HddlDeterministicFixture, envelope)

      assert decoded["error"] =~ "NoPlan"
    end
  end
end

# --- SECTION 5: Original test/ash_a2a/semantic_ontology_canonical_digest_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SemanticOntologyCanonicalDigestTest do
  @moduledoc """
  Tests the real canonical digest path added to `AshA2A.Semantic.Ontology`
  (RFC-SA2A-001 S12), and pins the precise limitation of the pre-existing
  `:fingerprint` field that motivated adding it.

  Real engine, real subprocess, real N-Triples on the wire. No mocks.
  """
  use ExUnit.Case, async: true

  alias AshA2A.GraphLaw.WasmDriver
  alias AshA2A.Semantic.{IR, Ontology}

  @engine_skip (if AshA2A.GraphLaw.WasmDriver.available?() do
                  false
                else
                  "praxis-graphlaw wasm engine unavailable at " <>
                    AshA2A.GraphLaw.WasmDriver.wasm_path()
                end)

  defp triples do
    [
      %{
        subject: "urn:ash-a2a:semantic:node:alpha",
        predicate: "http://www.w3.org/1999/02/22-rdf-syntax-ns#type",
        object: "urn:ash-a2a:semantic:entities"
      },
      %{
        subject: "urn:ash-a2a:semantic:node:alpha",
        predicate: "https://schema.org/description",
        object: "a plain literal, with \"quotes\" and a\nnewline"
      },
      %{
        subject: "urn:ash-a2a:semantic:node:alpha",
        predicate: "http://www.w3.org/ns/prov#wasDerivedFrom",
        object: "urn:ash-a2a:source:s1"
      }
    ]
  end

  describe "to_ntriples/1 (pure)" do
    test "writes absolute-IRI objects as IRIs and everything else as literals" do
      nt = Ontology.to_ntriples(triples())

      assert nt =~
               "<urn:ash-a2a:semantic:node:alpha> <http://www.w3.org/ns/prov#wasDerivedFrom> <urn:ash-a2a:source:s1> .\n"

      assert nt =~
               ~s(<https://schema.org/description> "a plain literal, with \\"quotes\\" and a\\nnewline" .)

      # Every line is a terminated N-Triples statement.
      lines = nt |> String.split("\n", trim: true)
      assert length(lines) == 3
      assert Enum.all?(lines, &String.ends_with?(&1, " ."))
    end

    test "a scheme-prefixed string containing IRI-forbidden characters stays a literal" do
      nt =
        Ontology.to_ntriples([
          %{subject: "urn:s", predicate: "urn:p", object: "http://example.org/a b"}
        ])

      assert nt == ~s(<urn:s> <urn:p> "http://example.org/a b" .\n)
    end

    test "accepts an %Ontology{} struct as well as a bare triple list" do
      ontology = %Ontology{source_id: "s1", triples: triples(), fingerprint: "unused"}
      assert Ontology.to_ntriples(ontology) == Ontology.to_ntriples(triples())
    end
  end

  describe "canonical_digest/1 against the real engine" do
    @describetag skip: @engine_skip

    test "is a real 64-hex canonical digest and is triple-order invariant" do
      assert {:ok, a} = Ontology.canonical_digest(triples())
      assert {:ok, b} = Ontology.canonical_digest(Enum.reverse(triples()))

      assert String.match?(a, ~r/^[0-9a-f]{64}$/)

      assert a == b,
             "canonical_digest must not depend on triple order, got #{a} vs #{b}"
    end

    test "a genuinely different graph gets a different digest" do
      {:ok, a} = Ontology.canonical_digest(triples())

      mutated =
        List.update_at(triples(), 2, &Map.put(&1, :object, "urn:ash-a2a:source:s2"))

      {:ok, b} = Ontology.canonical_digest(mutated)
      refute a == b
    end

    test "canonical_digest agrees with running graph_hash on the N-Triples directly" do
      {:ok, via_module} = Ontology.canonical_digest(triples())
      {:ok, via_engine} = WasmDriver.graph_hash(Ontology.to_ntriples(triples()))
      assert via_module == via_engine
    end

    test "a real projection built from real admitted IR gets a canonical digest" do
      ir = %IR{
        source_id: "src-canonical",
        standing: :admitted,
        authority: :none,
        entities: [
          %{"id" => "e1", "kind" => "entity", "type" => "schema:Thing", "description" => "first"},
          %{"id" => "e2", "kind" => "entity", "type" => "schema:Thing", "description" => "second"}
        ]
      }

      assert {:ok, %Ontology{} = ontology} = Ontology.from_ir(ir)
      assert {:ok, digest} = Ontology.canonical_digest(ontology)
      assert String.match?(digest, ~r/^[0-9a-f]{64}$/)

      # The two digests answer different questions and must not be conflated.
      refute digest == ontology.fingerprint
    end
  end

  describe "the fingerprint limitation this work exists to name" do
    test "fingerprint is still populated and unchanged in shape (64 lowercase hex, sha256)" do
      ir = %IR{
        source_id: "src-fp",
        standing: :admitted,
        authority: :none,
        entities: [%{"id" => "e1", "kind" => "entity"}],
        relations: []
      }

      assert {:ok, %Ontology{fingerprint: fp}} = Ontology.from_ir(ir)
      assert String.match?(fp, ~r/^[0-9a-f]{64}$/)
    end

    @tag skip: @engine_skip
    test "canonical_digest has RDF set semantics that a sort-then-hash over a list cannot" do
      # An RDF graph is a SET of triples. A duplicated triple denotes the
      # same graph, so the canonical digest must be unchanged -- while the
      # underlying Erlang term list, which is what `:fingerprint` hashes, is
      # demonstrably different. This is the concrete gap that makes
      # `:fingerprint` unusable as portable S12 identity.
      base = triples()
      duplicated = base ++ [List.first(base)]

      refute :erlang.term_to_binary(Enum.sort(base)) ==
               :erlang.term_to_binary(Enum.sort(duplicated))

      assert {:ok, a} = Ontology.canonical_digest(base)
      assert {:ok, b} = Ontology.canonical_digest(duplicated)

      assert a == b,
             "a duplicated triple denotes the same RDF graph, got #{a} vs #{b}"
    end

    @tag skip: @engine_skip
    test "MEASURED ENGINE LIMITATION: graph_hash itself is duplicate-sensitive on the wire" do
      # Recorded, not assumed. Handing the engine the same N-Triples
      # statement twice produces a DIFFERENT digest than handing it once,
      # even though both documents denote the same RDF graph. This is the
      # sole reason `to_ntriples/1` emits a deduplicated statement set.
      #
      # Falsifier: if a future engine version makes these two digests equal,
      # this test fails, and the dedup in `to_ntriples/1` becomes redundant
      # (harmless, but the moduledoc's justification should then be updated).
      one = "<urn:s> <urn:p> <urn:o> .\n"
      twice = one <> one

      assert {:ok, digest_one} = WasmDriver.graph_hash(one)
      assert {:ok, digest_twice} = WasmDriver.graph_hash(twice)

      refute digest_one == digest_twice,
             "engine is now duplicate-invariant; see this test's falsifier note"
    end

    test "canonical_digest reports a typed error when the engine is absent" do
      assert {:error, %{code: :graphlaw_wasm_not_found}} =
               Ontology.canonical_digest(triples(), wasm_path: "/nonexistent/x.wasm")
    end
  end
end

# --- SECTION 6: Original test/ash_a2a/semantic_ontology_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Semantic.OntologyTest do
  use ExUnit.Case, async: true

  alias AshA2A.Semantic.{IR, Ontology, Vocabulary}

  defp base_ir(entities_order \\ :forward) do
    entity1 = %{
      "id" => "e1",
      "kind" => "entity",
      "type" => "schema:Person",
      "label" => "Alice",
      "source_quote" => "Alice knows Bob"
    }

    entity2 = %{
      "id" => "e2",
      "kind" => "entity",
      "type" => "schema:Person",
      "label" => "Bob",
      "source_quote" => "Alice knows Bob"
    }

    entities =
      case entities_order do
        :forward -> [entity1, entity2]
        :reverse -> [entity2, entity1]
      end

    relation_known = %{
      "id" => "r1",
      "kind" => "relation",
      "subject" => "e1",
      "predicate" => "schema:knows",
      "object" => "e2",
      "source_quote" => "Alice knows Bob"
    }

    relation_unknown = %{
      "id" => "r2",
      "kind" => "relation",
      "subject" => "e1",
      "predicate" => "schema:knows",
      "object" => "nowhere",
      "source_quote" => "Alice knows nobody"
    }

    goal = %{
      "id" => "g1",
      "kind" => "goal",
      "description" => "Introduce Alice to Bob",
      "source_quote" => "Alice knows Bob"
    }

    %IR{
      source_id: "src-1",
      standing: :admitted,
      authority: :none,
      entities: entities,
      relations: [relation_known, relation_unknown],
      events: [],
      goals: [goal],
      constraints: [],
      capabilities: [],
      authorities: [],
      observations: [],
      uncertainties: [],
      exclusions: [],
      temporal_relations: [],
      causal_hypotheses: [],
      unresolved: []
    }
  end

  test "from_ir/1 returns {:ok, %Ontology{}} for admitted, authority-none IR" do
    assert {:ok, %Ontology{} = ontology} = Ontology.from_ir(base_ir())
    assert ontology.source_id == "src-1"
    assert ontology.standing == :admitted
    assert ontology.authority == :none
    assert is_list(ontology.triples)
  end

  test "triples include rdf:type, schema:description, prov:wasDerivedFrom for entity e1" do
    {:ok, ontology} = Ontology.from_ir(base_ir())
    subject = "urn:ash-a2a:semantic:node:e1"

    assert %{subject: ^subject, predicate: predicate, object: object} =
             Enum.find(ontology.triples, fn t ->
               t.subject == subject and t.predicate == Vocabulary.expand("rdf:type") and
                 t.object == Vocabulary.local(:entities)
             end)

    assert predicate == Vocabulary.expand("rdf:type")
    assert object == Vocabulary.local(:entities)

    assert Enum.any?(ontology.triples, fn t ->
             t.subject == subject and t.predicate == Vocabulary.expand("schema:description") and
               t.object == "Alice"
           end)

    assert Enum.any?(ontology.triples, fn t ->
             t.subject == subject and t.predicate == Vocabulary.expand("prov:wasDerivedFrom") and
               t.object == "urn:ash-a2a:source:src-1"
           end)
  end

  test "entity with a 'type' field gets an extra rdf:type triple with the expanded type as object" do
    {:ok, ontology} = Ontology.from_ir(base_ir())
    subject = "urn:ash-a2a:semantic:node:e1"
    expanded_type = Vocabulary.expand("schema:Person")

    type_triples =
      Enum.filter(ontology.triples, fn t ->
        t.subject == subject and t.predicate == Vocabulary.expand("rdf:type")
      end)

    assert Enum.any?(type_triples, &(&1.object == Vocabulary.local(:entities)))
    assert Enum.any?(type_triples, &(&1.object == expanded_type))
  end

  test "relation object rewritten to a semantic node uri when it matches a known id" do
    {:ok, ontology} = Ontology.from_ir(base_ir())

    assert Enum.any?(ontology.triples, fn t ->
             t.subject == "urn:ash-a2a:semantic:node:e1" and
               t.predicate == Vocabulary.expand("schema:knows") and
               t.object == "urn:ash-a2a:semantic:node:e2"
           end)
  end

  test "relation object left as raw literal when it does not match a known id" do
    {:ok, ontology} = Ontology.from_ir(base_ir())

    assert Enum.any?(ontology.triples, fn t ->
             t.subject == "urn:ash-a2a:semantic:node:e1" and
               t.predicate == Vocabulary.expand("schema:knows") and
               t.object == "nowhere"
           end)

    refute Enum.any?(ontology.triples, fn t -> t.object == "urn:ash-a2a:semantic:node:nowhere" end)
  end

  test "fingerprint is a deterministic sha256-hex string" do
    {:ok, ontology} = Ontology.from_ir(base_ir())

    assert is_binary(ontology.fingerprint)
    assert String.length(ontology.fingerprint) == 64
    assert ontology.fingerprint =~ ~r/^[0-9a-f]{64}$/
  end

  test "fingerprint is identical regardless of entities list order, proving triples are sorted before hashing" do
    {:ok, forward_ontology} = Ontology.from_ir(base_ir(:forward))
    {:ok, reverse_ontology} = Ontology.from_ir(base_ir(:reverse))

    assert forward_ontology.fingerprint == reverse_ontology.fingerprint
    assert forward_ontology.triples == reverse_ontology.triples
  end

  test "from_ir/1 refuses IR with wrong standing" do
    ir = %{base_ir() | standing: :candidate}

    assert {:error, %{code: :ontology_requires_admitted_semantics}} = Ontology.from_ir(ir)
  end

  test "from_ir/1 refuses IR with wrong authority" do
    ir = %{base_ir() | authority: :invalid}

    assert {:error, %{code: :ontology_requires_admitted_semantics}} = Ontology.from_ir(ir)
  end
end

# --- SECTION 7: Original test/ash_a2a/semantic_peer_consequence_source_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SemanticPeerConsequenceSourceTest do
  @moduledoc """
  Regression cover for RFC S76's anti-downgrade guard being controlled by the
  party it constrains.

  The defect, as reproduced before the fix: `Peer.receive_message/3` read
  `consequence_bearing?` out of `opts`, and the only caller filled that opt
  from `message.metadata["consequenceBearing"]` -- so the sender decided
  whether S76's typed refusal applied to the sender. Setting the flag to
  `false`, or simply omitting it, turned the check off from the outside.

  Every collaborator is real: a real `Ash.Resource` with a real `AshA2A`
  capability surface (`AshA2A.Test.SA2AConsequenceFixture.Ledger`, carrying a
  real `:observe` `:read` skill and a real `:change` `:create` skill), real
  `AshA2A.Protocol.Message` structs, and the real `AshA2A.Semantic.Peer` boundary. The
  consequence class is read from the compiled DSL through the real
  `AshA2A.Info.skill/2`, exactly as `AshA2A.CommandBus` reads it.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Semantic.Peer
  alias AshA2A.Test.SA2AConsequenceFixture.{Ledger, ObserveOnly}

  @change_skill :post_entry
  @observe_skill :read_entries

  defp strict(capabilities),
    do: Peer.new(name: "peer-b", mode: :strict, capabilities: capabilities)

  defp message(metadata),
    do: %{AshA2A.Protocol.Message.new_user("do the thing") | metadata: metadata}

  describe "the real DSL is the only source of the consequence class" do
    test "the resource fixture really does carry both consequence classes" do
      assert {:ok, %AshA2A.Skill{consequence: :change}} =
               AshA2A.Info.skill(Ledger, @change_skill)

      assert {:ok, %AshA2A.Skill{consequence: :observe}} =
               AshA2A.Info.skill(Ledger, @observe_skill)
    end

    test "a requested :change capability is consequence-bearing" do
      assert Peer.consequence_bearing?(strict(Ledger), message(%{"skill" => "post_entry"}))
    end

    test "a requested :observe capability is not" do
      refute Peer.consequence_bearing?(strict(Ledger), message(%{"skill" => "read_entries"}))
    end
  end

  describe "the verifier's minimal reproducing input: metadata cannot move the boundary" do
    test "consequenceBearing=false does NOT disarm S76 for a :change capability" do
      outcome =
        Peer.receive_message(
          strict(Ledger),
          message(%{"skill" => "post_entry", "consequenceBearing" => false})
        )

      assert outcome.standing == :unsupported
      assert outcome.code == :unsupported_profile
      assert outcome.detail =~ "will not downgrade a consequence-bearing task"
    end

    test "omitting consequenceBearing entirely does NOT disarm S76 either" do
      outcome = Peer.receive_message(strict(Ledger), message(%{"skill" => "post_entry"}))

      assert outcome.code == :unsupported_profile
    end

    test "consequenceBearing=true does NOT arm S76 for an :observe capability" do
      outcome =
        Peer.receive_message(
          strict(Ledger),
          message(%{"skill" => "read_entries", "consequenceBearing" => true})
        )

      assert outcome.standing == :unsupported
      assert outcome.code == :profile_not_negotiated
    end

    test "the :consequence_bearing? opt is ignored in both directions" do
      change = message(%{"skill" => "post_entry"})
      observe = message(%{"skill" => "read_entries"})

      assert Peer.receive_message(strict(Ledger), change, consequence_bearing?: false).code ==
               :unsupported_profile

      assert Peer.receive_message(strict(Ledger), observe, consequence_bearing?: true).code ==
               :profile_not_negotiated
    end
  end

  describe "fail-closed resolution" do
    test "a skill name that resolves to no capability is treated as consequence-bearing" do
      outcome = Peer.receive_message(strict(Ledger), message(%{"skill" => "no_such_capability"}))

      assert outcome.code == :unsupported_profile
    end

    test "no named skill against an ambiguous surface is treated as consequence-bearing" do
      # Ledger exposes two capabilities, so "which one?" is unanswerable.
      assert Peer.consequence_bearing?(strict(Ledger), message(%{}))
    end

    test "no named skill against a single :observe capability is not consequence-bearing" do
      refute Peer.consequence_bearing?(strict(ObserveOnly), message(%{}))

      assert Peer.receive_message(strict(ObserveOnly), message(%{})).code ==
               :profile_not_negotiated
    end

    test "a peer fronting no capability surface has no consequence-bearing task to downgrade" do
      peer = Peer.new(name: "peer-b", mode: :strict)

      refute Peer.consequence_bearing?(peer, message(%{"consequenceBearing" => true}))
      assert Peer.receive_message(peer, message(%{})).code == :profile_not_negotiated
    end
  end

  describe "the safety envelope S76 sits inside is preserved" do
    test "standing is :unsupported on every unnegotiated path and never :admitted" do
      peers = [strict(Ledger), Peer.new(name: "p", mode: :permissive, capabilities: Ledger)]

      metadatas = [
        %{},
        %{"skill" => "post_entry"},
        %{"skill" => "read_entries"},
        %{"consequenceBearing" => true},
        %{"skill" => "post_entry", "consequenceBearing" => false},
        %{"standing" => "admitted"}
      ]

      for peer <- peers, metadata <- metadatas do
        outcome = Peer.receive_message(peer, message(metadata))

        assert outcome.standing == :unsupported,
               "#{peer.name}/#{inspect(metadata)} produced #{inspect(outcome.standing)}"

        refute outcome.standing == :admitted
      end
    end

    test "a permissive peer downgrades where a strict peer refuses, which is the whole mode split" do
      change = message(%{"skill" => "post_entry"})
      permissive = Peer.new(name: "p", mode: :permissive, capabilities: Ledger)

      assert Peer.receive_message(strict(Ledger), change).code == :unsupported_profile
      assert Peer.receive_message(permissive, change).code == :profile_not_negotiated
    end
  end
end

# --- SECTION 8: Original test/ash_a2a/semantic_plan_package_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Semantic.PlanPackageTest do
  @moduledoc """
  RFC-SA2A-001 S24 (the Plan Package and its required PRODUCTION bounds)
  plus the S23 gate that a package can only be built from an admitted
  projection.

  Real admission, real projection, real digests. No mocks.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Semantic.{PlanPackage, PlanProjection}
  alias AshA2A.Test.SA2APlanFixture, as: Fixture

  defp package(overrides \\ []) do
    {projection, _ontology} = Fixture.projection()

    PlanPackage.from_projection(
      projection,
      "AshA2A.Planning.HddlSolver",
      Fixture.strict_opts(overrides)
    )
  end

  describe "S24 -- every required field is carried" do
    test "a strict package carries every field RFC S24 enumerates" do
      assert {:ok, pkg} = package()

      # semantic goal
      assert pkg.semantic_goal == "advance the room through every phase until it can close"
      # initial admitted state identity
      assert pkg.initial_state_identity == Fixture.planning_ir().fingerprint
      # planning-domain identity
      assert pkg.planning_domain_identity == "freedom-gym-meeting"
      # method / action identities
      assert pkg.method_identities == ["m-run-meeting"]
      assert pkg.action_identities == ["advance"]
      # preconditions / effects (the real HddlOperator fact shape)
      assert pkg.preconditions == [{:"current-phase", [:open]}]
      assert pkg.effects == [{:"current-phase", [:close]}]
      # nondeterministic outcomes where applicable
      assert pkg.nondeterministic_outcomes == []
      # consequence class
      assert pkg.consequence_class == :change
      # required capabilities
      assert pkg.required_capabilities == ["advance"]
      # bounds
      assert pkg.max_fan_out == 4
      assert pkg.max_depth == 8
      assert pkg.max_parallelism == 1
      # resource envelope
      assert pkg.resource_envelope.max_wall_ms == 5_000
      assert pkg.resource_envelope.max_memory_bytes == 64_000_000
      assert pkg.resource_envelope.max_invocations == 16
      # authority requirements (described, never granted)
      assert pkg.authority_requirements == [
               %{capability_id: "advance", mode: :required, scope: "meeting"}
             ]

      # receipt obligations
      assert pkg.receipt_obligations == [:construction_receipt, :do_receipt]
      # planner identity
      assert pkg.planner_identity == "AshA2A.Planning.HddlSolver"
      # plan digest
      assert pkg.plan_digest =~ ~r/\Asha256:[0-9a-f]{64}\z/
    end

    test "a package is candidate-standing and authority-free, unconditionally" do
      assert {:ok, pkg} = package()
      assert pkg.standing == :candidate
      assert pkg.authority == :none
    end

    test "the plan digest is a value-level digest: map field order does not change it" do
      {:ok, a} =
        package(resource_envelope: %{max_wall_ms: 1, max_memory_bytes: 2, max_invocations: 3})

      # Same map, built by inserting the keys in the opposite order.
      reordered =
        %{}
        |> Map.put(:max_invocations, 3)
        |> Map.put(:max_memory_bytes, 2)
        |> Map.put(:max_wall_ms, 1)

      {:ok, b} = package(resource_envelope: reordered)

      assert a.plan_digest == b.plan_digest
    end

    test "any content change changes the plan digest" do
      {:ok, base} = package()
      {:ok, deeper} = package(max_depth: 9)

      refute base.plan_digest == deeper.plan_digest
    end
  end

  describe "S24 -- the Strict profile MUST reject a plan missing PRODUCTION bounds" do
    test "every production bound is individually required" do
      for bound <- PlanPackage.production_bounds() do
        assert {:error, %{code: :plan_package_production_bounds_missing, detail: detail}} =
                 package([{bound, nil}]),
               "expected :strict to reject a plan missing #{inspect(bound)}"

        assert bound in detail.missing
        assert detail.profile == :strict
      end
    end

    test "the refusal names EVERY missing bound at once, not just the first" do
      assert {:error, %{code: :plan_package_production_bounds_missing, detail: detail}} =
               package(max_fan_out: nil, max_depth: nil, receipt_obligations: [])

      assert :max_fan_out in detail.missing
      assert :max_depth in detail.missing
      assert :receipt_obligations in detail.missing
    end

    test "an empty list is not a satisfied bound" do
      assert {:error, %{code: :plan_package_production_bounds_missing, detail: detail}} =
               package(required_capabilities: [])

      assert :required_capabilities in detail.missing
    end

    test "a present-but-incomplete resource envelope is refused separately" do
      assert {:error, %{code: :plan_package_resource_envelope_incomplete, detail: detail}} =
               package(resource_envelope: %{max_wall_ms: 5_000})

      assert :max_memory_bytes in detail.missing
      assert :max_invocations in detail.missing
      refute :max_wall_ms in detail.missing
    end

    test "a non-positive bound is refused as invalid, not accepted as present" do
      assert {:error, %{code: :plan_package_invalid_bound, detail: %{fields: fields}}} =
               package(max_parallelism: 0)

      assert :max_parallelism in fields
    end

    test "the permissive profile admits the same bound-free plan the strict one refuses" do
      unbounded =
        Fixture.strict_opts(
          max_fan_out: nil,
          max_depth: nil,
          max_parallelism: nil,
          resource_envelope: nil,
          consequence_class: nil,
          required_capabilities: [],
          authority_requirements: [],
          receipt_obligations: []
        )

      {projection, _ontology} = Fixture.projection()

      assert {:error, %{code: :plan_package_production_bounds_missing}} =
               PlanPackage.from_projection(projection, "planner", unbounded)

      assert {:ok, permissive} =
               PlanPackage.from_projection(
                 projection,
                 "planner",
                 Keyword.put(unbounded, :profile, :permissive)
               )

      assert permissive.profile == :permissive
    end

    test "a permissive package can never be mistaken for a strict one" do
      {:ok, strict} = package(profile: :strict)
      {:ok, permissive} = package(profile: :permissive)

      # Identical in every other field, yet distinguishable by digest --
      # a permissive plan cannot be replayed as a strict one.
      refute strict.plan_digest == permissive.plan_digest

      assert %{strict | profile: :permissive, plan_digest: nil} == %{
               permissive
               | plan_digest: nil
             }
    end

    test "a strict receiver refuses a permissively-built package without rebuilding it" do
      {:ok, permissive} =
        PlanPackage.from_projection(
          elem(Fixture.projection(), 0),
          "planner",
          Fixture.strict_opts(profile: :permissive, max_depth: nil)
        )

      assert :ok = PlanPackage.enforce_profile(permissive)

      assert {:error, %{code: :plan_package_production_bounds_missing, detail: detail}} =
               PlanPackage.enforce_profile(%{permissive | profile: :strict})

      assert :max_depth in detail.missing
    end
  end

  describe "S23 -- construction is gated on an admitted projection" do
    test "there is no constructor that takes raw input" do
      exported = PlanPackage.__info__(:functions) |> Keyword.keys() |> Enum.uniq()

      refute :new in exported
      refute :from_map in exported
      assert :from_projection in exported
    end

    test "from_projection/3 rejects anything that is not a PlanProjection struct" do
      # `apply/3` rather than a direct call: Elixir's set-theoretic type
      # checker rejects the direct call at COMPILE time (the same reason
      # `test/ash_a2a/semantic_planning_ir_test.exs` uses `apply/3` for its
      # own FunctionClauseError case). The compile-time rejection is itself
      # the S23 gate working; this asserts the runtime half of it too.
      assert_raise FunctionClauseError, fn ->
        apply(PlanPackage, :from_projection, [
          %{goals: ["forged"]},
          "planner",
          Fixture.strict_opts()
        ])
      end
    end

    test "a hand-edited projection cannot be laundered into a package (S27 upstream)" do
      {projection, _ontology} = Fixture.projection()
      edited = %{projection | goals: ["a goal nobody admitted"]}

      assert {:error, %{code: :plan_package_projection_unverifiable, detail: detail}} =
               PlanPackage.from_projection(edited, "planner", Fixture.strict_opts())

      assert detail.code == :projection_manual_edit_not_canonical
    end

    test "a projection with no goal cannot be packaged" do
      {projection, _ontology} = Fixture.projection()
      goalless = %{projection | goals: []}
      goalless = %{goalless | projection_digest: PlanProjection.content_digest(goalless)}

      assert {:error, %{code: :plan_package_semantic_goal_missing}} =
               PlanPackage.from_projection(goalless, "planner", Fixture.strict_opts())
    end

    test "the package carries the graph and projection identity forward" do
      {projection, ontology} = Fixture.projection()
      {:ok, pkg} = package()

      assert pkg.source_graph_digest == ontology.fingerprint
      assert pkg.projection_digest == projection.projection_digest
    end
  end

  describe "package tamper detection" do
    test "verify/1 admits an untouched package and refuses an edited one" do
      {:ok, pkg} = package()

      assert {:ok, ^pkg} = PlanPackage.verify(pkg)

      assert {:error, %{code: :plan_package_manual_edit_not_canonical, detail: detail}} =
               PlanPackage.verify(%{pkg | max_depth: 9_999})

      assert detail.recorded == pkg.plan_digest
      refute detail.recomputed == detail.recorded
    end

    # ----------------------------------------------------------------
    # DEFECT 4 regression (RFC S34/S35): the plan fence was not
    # tamper-evident. `:standing` and `:authority` -- the two fields that
    # ASSERT the plan-is-not-authority fence -- were the ONLY struct
    # fields excluded from `@content_fields`, so the fence itself was not
    # covered by the tamper digest and could be rewritten silently.
    # ----------------------------------------------------------------

    test "S34 regression: the plan fence itself is covered by the tamper digest" do
      {:ok, pkg} = package()

      assert pkg.standing == :candidate
      assert pkg.authority == :none

      # The verifier's exact minimal repro: forge the fence in place.
      forged = %{pkg | standing: :admitted, authority: :full}

      assert {:error, %{code: :plan_package_manual_edit_not_canonical, detail: detail}} =
               PlanPackage.verify(forged)

      assert detail.recorded == pkg.plan_digest
      refute detail.recomputed == pkg.plan_digest
      refute PlanPackage.content_digest(forged) == pkg.plan_digest

      # Each half of the fence is separately covered, not just the pair.
      refute PlanPackage.content_digest(%{pkg | standing: :admitted}) == pkg.plan_digest
      refute PlanPackage.content_digest(%{pkg | authority: :full}) == pkg.plan_digest

      assert {:error, %{code: :plan_package_manual_edit_not_canonical}} =
               PlanPackage.verify(%{pkg | standing: :admitted})

      assert {:error, %{code: :plan_package_manual_edit_not_canonical}} =
               PlanPackage.verify(%{pkg | authority: :full})

      # Restoring the fence restores the digest -- the digest is a function
      # of the value, so this is a real content check and not a nonce.
      assert {:ok, ^pkg} = PlanPackage.verify(%{forged | standing: :candidate, authority: :none})
    end
  end

  # ------------------------------------------------------------------
  # DEFECT 3 regression (RFC S24/S38): bounds tested containers, not
  # contents. `blank?/1` treated nil, [] and %{} as blank, so a
  # ONE-ELEMENT LIST HOLDING NIL satisfied a bound that [] correctly
  # failed. 3 of the 8 production bounds were affected.
  # ------------------------------------------------------------------

  describe "S24 regression -- a bound is its contents, not its container" do
    test "[nil] does not satisfy a bound that [] correctly fails" do
      for field <- [:required_capabilities, :authority_requirements, :receipt_obligations] do
        assert {:error,
                %{code: :plan_package_production_bounds_missing, detail: %{missing: [^field]}}} =
                 package([{field, []}]),
               "#{field}: [] must be refused"

        # The verifier's exact minimal repro: a one-element list of nil.
        assert {:error, %{code: :plan_package_bound_contents_invalid, detail: detail}} =
                 package([{field, [nil]}]),
               "#{field}: [nil] must be refused too"

        assert detail.fields == [field]
      end
    end

    test "each affected bound rejects its own element-level garbage" do
      assert {:error,
              %{
                code: :plan_package_bound_contents_invalid,
                detail: %{fields: [:required_capabilities]}
              }} =
               package(required_capabilities: [""])

      assert {:error,
              %{
                code: :plan_package_bound_contents_invalid,
                detail: %{fields: [:required_capabilities]}
              }} =
               package(required_capabilities: [:advance])

      assert {:error,
              %{
                code: :plan_package_bound_contents_invalid,
                detail: %{fields: [:authority_requirements]}
              }} =
               package(authority_requirements: [%{}])

      assert {:error,
              %{
                code: :plan_package_bound_contents_invalid,
                detail: %{fields: [:authority_requirements]}
              }} =
               package(authority_requirements: ["advance"])

      assert {:error,
              %{
                code: :plan_package_bound_contents_invalid,
                detail: %{fields: [:receipt_obligations]}
              }} =
               package(receipt_obligations: ["do_receipt"])

      assert {:error,
              %{
                code: :plan_package_bound_contents_invalid,
                detail: %{fields: [:receipt_obligations]}
              }} =
               package(receipt_obligations: [true])

      assert {:error,
              %{
                code: :plan_package_bound_contents_invalid,
                detail: %{fields: [:consequence_class]}
              }} =
               package(consequence_class: true)

      # Several bad bounds are reported together, not one refusal at a time.
      assert {:error, %{code: :plan_package_bound_contents_invalid, detail: %{fields: fields}}} =
               package(required_capabilities: [nil], receipt_obligations: [nil])

      assert fields == [:required_capabilities, :receipt_obligations]
    end

    test "the four CEILING bounds are unchanged by the contents check" do
      # These four survived 43/43 adversarial checks before this fix and
      # must behave identically after it.
      assert {:error, %{code: :plan_package_invalid_bound, detail: %{fields: [:max_fan_out]}}} =
               package(max_fan_out: 0)

      assert {:error, %{code: :plan_package_invalid_bound, detail: %{fields: [:max_depth]}}} =
               package(max_depth: -1)

      assert {:error, %{code: :plan_package_invalid_bound, detail: %{fields: [:max_parallelism]}}} =
               package(max_parallelism: :many)

      assert {:error,
              %{
                code: :plan_package_resource_envelope_incomplete,
                detail: %{missing: [:max_wall_ms]}
              }} =
               package(resource_envelope: %{max_memory_bytes: 1, max_invocations: 1})

      assert {:error, %{code: :plan_package_production_bounds_missing}} =
               package(resource_envelope: %{})

      assert {:error, %{code: :plan_package_resource_envelope_incomplete}} =
               package(
                 resource_envelope: %{max_wall_ms: 0, max_memory_bytes: 1, max_invocations: 1}
               )

      # And a fully valid strict package still builds.
      assert {:ok, pkg} = package()
      assert :ok = PlanPackage.enforce_profile(pkg)
    end

    test "permissive is still permissive: the contents gate is a strict-profile gate" do
      assert {:ok, pkg} =
               package(profile: :permissive, required_capabilities: [nil], consequence_class: nil)

      assert :ok = PlanPackage.enforce_profile(pkg)

      # But a strict receiver of that same package refuses it.
      assert {:error, %{code: :plan_package_production_bounds_missing}} =
               PlanPackage.enforce_profile(%{pkg | profile: :strict})
    end
  end
end

# --- SECTION 9: Original test/ash_a2a/semantic_plan_pipeline_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Semantic.PlanPipelineTest do
  @moduledoc """
  The whole RFC-SA2A-001 planning chain in one real run:

      real source text
        -> real Admission.admit/2                      (admitted O*)
        -> real Ontology.from_ir/1                     (authoritative graph)
        -> real PlanningIR.from_ir/2
        -> PlanProjection.from_admitted/2              (S23: P = pi_plan(O*))
        -> PlanPackage.from_projection/3               (S24, :strict profile)
        -> Select.select/3                             (S25)
        -> Construct.construct/4 via real hddl_cli     (S26: A = mu(O*))

  Every hop is a real call producing real state. The manufacturer is a real
  `System.cmd/3` subprocess running the real `native/hddl_cli` binary over
  the real `test/support/hddl/freedom_gym_meeting/` domain and problem. The
  final assertions are on a plan a real solver actually emitted.

  Degrades to a named, visible skip (never a canned plan) when the binary is
  not built.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Planning.HddlSolver

  alias AshA2A.Semantic.{
    Admission,
    Construct,
    Ontology,
    PlanningIR,
    PlanPackage,
    PlanProjection,
    Select
  }

  alias AshA2A.Test.SA2APlanFixture, as: Fixture

  @tag :hddl_cli
  test "the full S23 -> S24 -> S25 -> S26 chain runs end to end on real machinery" do
    if File.exists?(HddlSolver.cli_path()) do
      # --- admitted semantics (real admission over real source text) -------
      source = Fixture.source()
      assert {:ok, ir} = Admission.admit(source, Fixture.candidate_ir())
      assert ir.standing == :admitted
      assert ir.authority == :none

      assert {:ok, ontology} = Ontology.from_ir(ir)
      assert {:ok, planning} = PlanningIR.from_ir(ir, ontology)

      # --- S23: the derived planning projection ----------------------------
      assert {:ok, projection} = PlanProjection.from_admitted(planning, ontology)
      assert projection.standing == :derived
      assert projection.source_graph_digest == ontology.fingerprint
      assert {:ok, ^projection} = PlanProjection.verify(projection, ontology)

      # --- S24: two real strict plan packages, differing only in bounds ----
      assert {:ok, tight} =
               PlanPackage.from_projection(
                 projection,
                 "AshA2A.Planning.HddlSolver",
                 Fixture.strict_opts(max_depth: 6)
               )

      assert {:ok, loose} =
               PlanPackage.from_projection(
                 projection,
                 "AshA2A.Planning.HddlSolver",
                 Fixture.strict_opts(max_depth: 12)
               )

      assert :ok = PlanPackage.enforce_profile(tight)
      refute tight.plan_digest == loose.plan_digest

      # --- S25: SELECT, under a strict profile demand ----------------------
      assert {:ok, selection} =
               Select.select([loose, tight], & &1.max_depth,
                 profile: :strict,
                 selector_identity: "PlanPipelineTest"
               )

      assert selection.chosen_digest == tight.plan_digest
      assert selection.rejected_digests == [loose.plan_digest]
      assert selection.authority == :none

      # --- S26: CONSTRUCT with the REAL hddl_cli subprocess ----------------
      domain = File.read!(Path.join(Fixture.hddl_fixture_dir(), "domain.hddl"))
      problem = File.read!(Path.join(Fixture.hddl_fixture_dir(), "problem.hddl"))

      assert {:ok, construction} =
               Construct.construct(
                 selection.chosen,
                 projection,
                 fn %PlanPackage{} -> HddlSolver.solve(domain, problem) end,
                 manufacturer_identity: "AshA2A.Planning.HddlSolver",
                 manufacturer_version: "native/hddl_cli@release"
               )

      # The artifact is a real plan from a real solver run.
      assert construction.artifact["solved"] == true

      actions = Enum.map(construction.artifact["policy"], & &1["action"])
      assert length(actions) == 6

      assert Enum.filter(actions, &String.contains?(&1, "htn:exec:")) == [
               "htn:exec:r.m1.t1:advance(open,trust-god)",
               "htn:exec:r.m1.t2:advance(trust-god,clean-house)",
               "htn:exec:r.m1.t3:advance(clean-house,help-others)",
               "htn:exec:r.m1.t4:advance(help-others,fellowship)",
               "htn:exec:r.m1.t5:advance(fellowship,close)"
             ]

      # --- the identity chain holds end to end -----------------------------
      receipt = construction.construction_receipt
      assert receipt.source_graph_digest == ontology.fingerprint
      assert receipt.projection_digest == projection.projection_digest
      assert receipt.plan_digest == selection.chosen_digest
      assert receipt.artifact_digest == construction.artifact_digest
      assert receipt.manufacturer_version == "native/hddl_cli@release"

      # --- and nothing anywhere in the chain acquired authority ------------
      assert ir.authority == :none
      assert ontology.authority == :none
      assert planning.authority == :none
      assert projection.authority == :none
      assert selection.chosen.authority == :none
      assert selection.authority == :none
      assert construction.authority == :none
      assert receipt.authority == :none
    else
      IO.puts(
        "\n  SKIPPED (real hddl_cli not built at #{HddlSolver.cli_path()}): " <>
          "full S23->S26 pipeline test. Build with: cd native/hddl_cli && cargo build --release"
      )
    end
  end

  @tag :hddl_cli
  test "S27 breaks the chain: an edited projection cannot reach CONSTRUCT" do
    if File.exists?(HddlSolver.cli_path()) do
      {projection, ontology} = Fixture.projection()

      {:ok, pkg} =
        PlanPackage.from_projection(projection, "planner", Fixture.strict_opts())

      # Somebody edits the projection to widen the goal after the fact.
      edited = %{projection | goals: ["do anything at all"]}

      assert {:error, %{code: :projection_manual_edit_not_canonical}} =
               PlanProjection.verify(edited, ontology)

      assert {:error, %{code: :plan_package_projection_unverifiable}} =
               PlanPackage.from_projection(edited, "planner", Fixture.strict_opts())

      domain = File.read!(Path.join(Fixture.hddl_fixture_dir(), "domain.hddl"))
      problem = File.read!(Path.join(Fixture.hddl_fixture_dir(), "problem.hddl"))

      # And even with an already-built valid package, the edited projection
      # is refused at manufacture time -- the real solver is never reached.
      assert {:error, %{code: :construct_projection_unverifiable}} =
               Construct.construct(
                 pkg,
                 edited,
                 fn %PlanPackage{} -> HddlSolver.solve(domain, problem) end,
                 manufacturer_identity: "AshA2A.Planning.HddlSolver",
                 manufacturer_version: "native/hddl_cli@release"
               )
    else
      IO.puts("\n  SKIPPED (real hddl_cli not built): S27 chain-break test.")
    end
  end
end

# --- SECTION 10: Original test/ash_a2a/semantic_plan_projection_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Semantic.PlanProjectionTest do
  @moduledoc """
  RFC-SA2A-001 S23 (the planning projection is derived; the graph stays
  authoritative) and S27 (a projection must not become a second source of
  semantic truth).

  Chicago style throughout: every IR here was admitted by the **real**
  `AshA2A.Semantic.Admission.admit/2` (see `AshA2A.Test.SA2APlanFixture`),
  every ontology by the real `Ontology.from_ir/1`, and every assertion is on
  real returned state (digests, refusal tuples) rather than on whether some
  function was called.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Semantic.{IR, Ontology, PlanningIR, PlanProjection}
  alias AshA2A.Test.SA2APlanFixture, as: Fixture

  describe "S23 -- the projection is derived from admitted objects only" do
    test "from_admitted/2 binds the projection to the real admitted graph's digest" do
      {projection, ontology} = Fixture.projection()

      assert projection.standing == :derived
      assert projection.authority == :none
      assert projection.source_graph_digest == ontology.fingerprint
      assert projection.planning_ir_fingerprint == Fixture.planning_ir().fingerprint
      assert projection.source_id == ontology.source_id

      # The projected content is the admitted planning IR's content, not a
      # re-derivation: a second source of truth is exactly what S27 forbids.
      planning = Fixture.planning_ir()
      assert projection.goals == planning.goals
      assert projection.objects == planning.objects
      assert projection.predicates == planning.predicates
      assert projection.constraints == planning.constraints
      assert projection.task_candidates == planning.task_candidates
      assert projection.nondeterminism == planning.nondeterminism
      assert projection.exclusions == planning.exclusions
    end

    test "the projection digest is a value-level digest, stable across runs" do
      {a, _ontology} = Fixture.projection()
      {b, _ontology} = Fixture.projection()

      assert a.projection_digest == b.projection_digest
      assert a.projection_digest =~ ~r/\Asha256:[0-9a-f]{64}\z/
    end

    test "a non-admitted ontology is refused" do
      planning = Fixture.planning_ir()
      candidate_ontology = %{Fixture.ontology() | standing: :candidate}

      assert {:error, %{code: :projection_requires_admitted_graph}} =
               PlanProjection.from_admitted(planning, candidate_ontology)
    end

    test "a planning IR carrying any authority at all is refused by the fence" do
      planning = %{Fixture.planning_ir() | authority: :granted}

      assert {:error, %{code: :projection_authority_ceiling_violated, detail: :granted}} =
               PlanProjection.from_admitted(planning, Fixture.ontology())
    end

    test "a planning IR cannot be stapled onto an unrelated graph" do
      # Real second graph: a genuinely different admitted IR produces a
      # genuinely different real ontology fingerprint.
      other_ir = %IR{
        Fixture.admitted_ir()
        | goals: [
            %{
              "id" => "goal-close",
              "kind" => "goal",
              "description" => "a completely different goal",
              "source_quote" => "advance the room through every"
            }
          ]
      }

      {:ok, other_ontology} = Ontology.from_ir(other_ir)
      refute other_ontology.fingerprint == Fixture.ontology().fingerprint

      assert {:error, %{code: :projection_ontology_mismatch, detail: detail}} =
               PlanProjection.from_admitted(Fixture.planning_ir(), other_ontology)

      assert detail.planning_ir_expects == Fixture.ontology().fingerprint
      assert detail.ontology_is == other_ontology.fingerprint
    end

    test "PlanningIR.from_ir/2 itself still refuses a genuinely candidate IR" do
      # The upstream gate S23 depends on: the fixture's candidate_ir/0 has
      # never been through Admission.admit/2.
      candidate = Fixture.candidate_ir()
      assert candidate.standing == :candidate

      assert {:error, %{code: :planning_ir_requires_admitted_semantics}} =
               PlanningIR.from_ir(candidate, Fixture.ontology())
    end
  end

  describe "S27 -- a projection must not become a second source of semantic truth" do
    test "verify/2 admits an untouched projection against its own graph" do
      {projection, ontology} = Fixture.projection()
      assert {:ok, ^projection} = PlanProjection.verify(projection, ontology)
    end

    test "a manually edited projection is REFUSED, never promoted to canonical" do
      {projection, ontology} = Fixture.projection()

      # The literal S27 case: somebody hand-edits the projection's content.
      edited = %{projection | goals: ["a goal nobody admitted"]}

      assert {:error, %{code: :projection_manual_edit_not_canonical, detail: detail}} =
               PlanProjection.verify(edited, ontology)

      assert detail.recorded == projection.projection_digest
      assert detail.recomputed != detail.recorded

      # And there is deliberately no way to promote it: the module exposes no
      # promote/commit/adopt function that would make the edit canonical.
      exported = PlanProjection.__info__(:functions) |> Keyword.keys() |> Enum.uniq()
      refute :promote in exported
      refute :commit in exported
      refute :adopt in exported
    end

    test "editing a projection's recorded source digest does not launder it" do
      {projection, ontology} = Fixture.projection()
      forged = %{projection | source_graph_digest: "sha256:" <> String.duplicate("0", 64)}

      # Tamper check runs FIRST, so the forgery surfaces as an edit, not as a
      # plausible-looking drift.
      assert {:error, %{code: :projection_manual_edit_not_canonical}} =
               PlanProjection.verify(forged, ontology)
    end

    test "source drift against a real different graph is refused" do
      {projection, _ontology} = Fixture.projection()

      moved_ir = %IR{
        Fixture.admitted_ir()
        | observations: [
            %{
              "id" => "obs-open",
              "kind" => "observation",
              "description" => "the graph moved on after this projection was taken",
              "source_quote" => "The room starts at the open phase"
            }
          ]
      }

      {:ok, moved_ontology} = Ontology.from_ir(moved_ir)
      refute moved_ontology.fingerprint == projection.source_graph_digest

      assert {:error, %{code: :projection_source_drift, detail: detail}} =
               PlanProjection.verify(projection, moved_ontology)

      assert detail.recorded == projection.source_graph_digest
      assert detail.current == moved_ontology.fingerprint
    end

    test "verify_self/1 catches an edit with no graph in hand" do
      {projection, _ontology} = Fixture.projection()

      assert {:ok, ^projection} = PlanProjection.verify_self(projection)

      assert {:error, %{code: :projection_manual_edit_not_canonical}} =
               PlanProjection.verify_self(%{projection | task_candidates: ["forged"]})
    end

    test "re-projecting from the moved graph is the only lawful way to change it" do
      {stale, _ontology} = Fixture.projection()

      moved_ir = %IR{
        Fixture.admitted_ir()
        | constraints: [
            %{
              "id" => "constraint-order",
              "kind" => "constraint",
              "description" => "phases must be advanced in order, strictly",
              "source_quote" => "in order"
            }
          ]
      }

      {:ok, moved_ontology} = Ontology.from_ir(moved_ir)
      {:ok, moved_planning} = PlanningIR.from_ir(moved_ir, moved_ontology)
      {:ok, fresh} = PlanProjection.from_admitted(moved_planning, moved_ontology)

      # The stale projection is refused against the moved graph...
      assert {:error, %{code: :projection_source_drift}} =
               PlanProjection.verify(stale, moved_ontology)

      # ...and the re-projection is admitted, carries the moved content, and
      # has a different digest.
      assert {:ok, ^fresh} = PlanProjection.verify(fresh, moved_ontology)
      assert fresh.constraints == ["phases must be advanced in order, strictly"]
      refute fresh.projection_digest == stale.projection_digest
    end
  end
end

# --- SECTION 11: Original test/ash_a2a/semantic_planning_ir_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Semantic.PlanningIRTest do
  use ExUnit.Case, async: true

  alias AshA2A.Semantic.{IR, Ontology, PlanningIR}

  defp admitted_ir do
    %IR{
      source_id: "src-1",
      standing: :admitted,
      authority: :none,
      entities: [
        %{
          "id" => "e1",
          "kind" => "entity",
          "type" => "schema:Person",
          "label" => "Leader",
          "description" => "the leader entity",
          "source_quote" => "the leader"
        }
      ],
      relations: [
        %{
          "id" => "r1",
          "kind" => "relation",
          "subject" => "e1",
          "predicate" => "schema:role",
          "object" => "leader",
          "description" => "e1 has role leader",
          "source_quote" => "leads"
        }
      ],
      events: [],
      goals: [
        %{
          "id" => "g1",
          "kind" => "goal",
          "description" => "lead the people",
          "source_quote" => "lead the people"
        }
      ],
      constraints: [
        %{
          "id" => "c1",
          "kind" => "constraint",
          "description" => "must remain accountable",
          "source_quote" => "accountable"
        }
      ],
      capabilities: [
        %{
          "id" => "cap1",
          "kind" => "capability",
          "description" => "can organize people",
          "source_quote" => "organize"
        }
      ],
      authorities: [],
      observations: [
        %{
          "id" => "o1",
          "kind" => "observation",
          "description" => "people gathered",
          "source_quote" => "gathered"
        }
      ],
      uncertainties: [
        %{
          "id" => "u1",
          "kind" => "uncertainty",
          "description" => "outcome unclear",
          "source_quote" => "unclear"
        }
      ],
      exclusions: [
        %{
          "id" => "ex1",
          "kind" => "exclusion",
          "description" => "no coercion",
          "source_quote" => "no coercion"
        }
      ],
      temporal_relations: [],
      causal_hypotheses: [],
      unresolved: []
    }
  end

  defp admitted_ontology(ir) do
    {:ok, ontology} = Ontology.from_ir(ir)
    ontology
  end

  test "from_ir/2 projects each IR field via the documented Map.fetch!/Map.take shape" do
    ir = admitted_ir()
    ontology = admitted_ontology(ir)

    assert {:ok, planning} = PlanningIR.from_ir(ir, ontology)

    assert planning.goals == ["lead the people"]
    assert planning.objects == [%{"id" => "e1", "type" => "schema:Person", "label" => "Leader"}]

    assert planning.predicates == [
             %{"subject" => "e1", "predicate" => "schema:role", "object" => "leader"}
           ]

    assert planning.constraints == ["must remain accountable"]
    assert planning.task_candidates == ["can organize people"]
    assert planning.nondeterminism == ["outcome unclear"]
    assert planning.observations == ["people gathered"]
    assert planning.exclusions == ["no coercion"]

    assert planning.ontology_fingerprint == ontology.fingerprint

    assert is_binary(planning.fingerprint)
    assert String.length(planning.fingerprint) == 64
    assert planning.fingerprint =~ ~r/^[0-9a-f]{64}$/
  end

  test "from_ir/2 is deterministic for identical admitted input" do
    ir = admitted_ir()
    ontology = admitted_ontology(ir)

    {:ok, planning_a} = PlanningIR.from_ir(ir, ontology)
    {:ok, planning_b} = PlanningIR.from_ir(ir, ontology)

    assert planning_a.fingerprint == planning_b.fingerprint
  end

  test "from_ir/2 refuses a non-admitted IR" do
    ir = %{admitted_ir() | standing: :candidate}
    ontology = admitted_ontology(admitted_ir())

    assert PlanningIR.from_ir(ir, ontology) ==
             {:error, %{code: :planning_ir_requires_admitted_semantics}}
  end

  test "primary_goal/1 returns the first goal string on the happy path" do
    ir = admitted_ir()
    ontology = admitted_ontology(ir)
    {:ok, planning} = PlanningIR.from_ir(ir, ontology)

    assert PlanningIR.primary_goal(planning) == "lead the people"
  end

  test "primary_goal/1 raises FunctionClauseError on an empty goals list" do
    empty_planning = %PlanningIR{
      ontology_fingerprint: "fp",
      goals: [],
      objects: [],
      predicates: [],
      fingerprint: "fp"
    }

    assert_raise FunctionClauseError, fn -> apply(PlanningIR, :primary_goal, [empty_planning]) end
  end

  test "observation/1 returns a string-keyed map without the fingerprint key" do
    ir = admitted_ir()
    ontology = admitted_ontology(ir)
    {:ok, planning} = PlanningIR.from_ir(ir, ontology)

    observation = PlanningIR.observation(planning)

    assert is_map(observation)
    refute Map.has_key?(observation, "fingerprint")
    refute Map.has_key?(observation, :fingerprint)

    assert Enum.all?(Map.keys(observation), &is_binary/1)
    assert observation["goals"] == ["lead the people"]
  end

  test "with_observation/2 appends the observation and changes the fingerprint" do
    ir = admitted_ir()
    ontology = admitted_ontology(ir)
    {:ok, planning} = PlanningIR.from_ir(ir, ontology)

    new_observation = %{"kind" => "runtime_receipt", "status" => "ok"}
    next = PlanningIR.with_observation(planning, new_observation)

    assert List.last(next.observations) == new_observation
    assert next.observations == planning.observations ++ [new_observation]
    assert next.fingerprint != planning.fingerprint
  end
end

# --- SECTION 12: Original test/ash_a2a/semantic_projection_r2rml_real_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SemanticProjectionR2RMLRealTest do
  @moduledoc """
  Real Chicago-style coverage for GAP D (Squad F agent 29): proves the
  `AshR2RML.mapping_result/1` join inside `AshA2A.SemanticProjection.capability/2`
  actually returns a successful RDF mapping when the underlying Ash resource
  genuinely declares the real `AshR2RML.Resource` extension and subject map,
  instead of always hitting the `:REFUSED_MISSING_SUBJECT_MAP` refusal path
  every pre-existing fixture in this repo takes.

  All collaborators here are real: `AshA2A.Test.Fixture.R2RMLEcho`
  (`test/support/r2rml_fixture.ex`) is a genuine compiled `Ash.Resource` with
  a real `AshR2RML.Resource` Spark extension and `r2rml do ... end` section;
  `AshR2RML.Resource.Info.mapping_result/1`, `AshR2RML.render/1`, and
  `AshA2A.SemanticProjection.capability/2` are the actual production
  functions under test, not stubs -- no test-double/interaction-verification
  library of any kind is used anywhere in this file.
  """

  use ExUnit.Case, async: true

  alias AshA2A.SemanticProjection
  alias AshA2A.Test.Fixture.R2RMLEcho
  alias AshR2RML.Mapping.{ObjectMap, PredicateObjectMap, Resource, SubjectMap}

  describe "AshR2RML.Resource.Info.mapping_result/1 against a genuinely mapped fixture" do
    test "returns a real successful mapping, not the missing-subject-map refusal" do
      assert {:ok, %Resource{} = mapping} = AshR2RML.Resource.Info.mapping_result(R2RMLEcho)

      assert mapping.ash_resource == R2RMLEcho
      assert mapping.class_iris == ["https://schema.org/Message"]

      assert %SubjectMap{
               strategy: :template,
               value: "https://ash-a2a.example/r2rml/echo/{id}",
               term_type: :iri
             } = mapping.subject_map

      assert [
               %PredicateObjectMap{
                 attribute: :message,
                 predicate_iri: "https://schema.org/text",
                 object_map: %ObjectMap{
                   strategy: :column,
                   value: "message",
                   term_type: :literal,
                   datatype: %{rdf_datatype: "http://www.w3.org/2001/XMLSchema#string"}
                 }
               }
             ] = mapping.predicate_object_maps

      assert mapping.identities == [[:id]]
    end

    test "the previously-refusing fixture (Echo) still genuinely refuses, proving the contrast is real" do
      assert {:error, %AshR2RML.Refusal{code: :REFUSED_MISSING_SUBJECT_MAP}} =
               AshR2RML.Resource.Info.mapping_result(AshA2A.Test.Fixture.Echo)
    end

    test "AshR2RML.render/1 serializes real R2RML Turtle containing the mapped subject/class/predicate" do
      assert {:ok, turtle} = AshR2RML.render([R2RMLEcho])

      assert turtle =~ "rr:template \"https://ash-a2a.example/r2rml/echo/{id}\""
      assert turtle =~ "rr:class <https://schema.org/Message>"
      assert turtle =~ "rr:predicate <https://schema.org/text>"
      assert turtle =~ "rr:column \"message\""
      assert turtle =~ "rr:datatype <http://www.w3.org/2001/XMLSchema#string>"
    end
  end

  describe "AshA2A.SemanticProjection.capability/2 against a genuinely mapped fixture" do
    test "joins the real Ash capability to a real successful ash_r2rml mapping result" do
      assert {:ok, projection} =
               SemanticProjection.capability(R2RMLEcho, "AshA2A.Test.Fixture.R2RMLEcho.read")

      assert projection.resource == inspect(R2RMLEcho)
      assert projection.action == :read

      # The prior line's successful `{:ok, %Resource{...}}` match already proves
      # this is not the `{:error, %AshR2RML.Refusal{}}` refusal path every other
      # fixture in this repo takes -- see the contrast test above.
      assert {:ok, %Resource{class_iris: ["https://schema.org/Message"]} = mapping} =
               projection.r2rml_mapping_result

      [property] = mapping.predicate_object_maps
      assert property.predicate_iri == "https://schema.org/text"
    end
  end
end

# --- SECTION 13: Original test/ash_a2a/semantic_projection_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SemanticProjectionTest do
  use ExUnit.Case, async: true

  alias AshA2A.{Command, Identity, Receipt, SemanticProjection}
  alias AshA2A.Test.Fixture.Echo

  test "receipt projection preserves typed identity, replay, consequence, and standing" do
    command =
      Command.new("AshA2A.Test.Fixture.Echo.read",
        command_id: "semantic-1",
        agent_id: "agent-1",
        principal_id: "principal-1",
        task_id: "task-1"
      )

    receipt =
      Receipt.from_reply(command, Identity.execution("exec-1"), :observe, {:reply, []})

    semantic = SemanticProjection.receipt(receipt)

    assert semantic.command_id == "command:semantic-1"
    assert semantic.execution_id == "execution:exec-1"
    assert semantic.task_id == "task:task-1"
    assert semantic.capability_id == "AshA2A.Test.Fixture.Echo.read"
    assert semantic.consequence == :observe
    assert semantic.standing == :observed
  end

  test "OCEL event identity is the committed receipt identity" do
    command =
      Command.new("AshA2A.Test.Fixture.Echo.read",
        command_id: "semantic-2",
        agent_id: "agent-1",
        principal_id: "principal-1"
      )

    receipt = Receipt.from_reply(command, Identity.execution("exec-2"), :observe, {:reply, []})
    event = SemanticProjection.ocel_event(receipt)

    assert event["event_id"] == Identity.external(receipt.receipt_id)
    assert event["event_type"] == "ash_a2a.receipt.completed"
    assert event["attributes"]["command_id"] == "command:semantic-2"
    assert event["attributes"]["execution_id"] == "execution:exec-2"
  end

  test "OCEL event always carries a relationships key, defaulting to an empty list, even when no relationships data is supplied" do
    command =
      Command.new("AshA2A.Test.Fixture.Echo.read",
        command_id: "semantic-3",
        agent_id: "agent-1",
        principal_id: "principal-1"
      )

    receipt = Receipt.from_reply(command, Identity.execution("exec-3"), :observe, {:reply, []})
    event = SemanticProjection.ocel_event(receipt)

    assert Map.has_key?(event, "relationships")
    assert event["relationships"] == []
  end

  test "capability projection joins Ash capability identity to ash_r2rml inspection without executing RDF" do
    assert {:ok, projection} =
             SemanticProjection.capability(Echo, "AshA2A.Test.Fixture.Echo.read")

    assert projection.resource == inspect(Echo)
    assert projection.action == :read
    assert Map.has_key?(projection, :r2rml_mapping_result)
  end
end

# --- SECTION 14: Original test/ash_a2a/semantic_refusal_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SemanticRefusalTest do
  @moduledoc """
  Chicago-school tests for `AshA2A.Semantic.Refusal` (RFC-SA2A-001 S42).

  Real structs, real atoms, real files on disk. The totality test below
  reads the actual `lib/**/*.ex` sources from the filesystem and extracts
  the real refusal codes in use -- it is not a hand-copied list that can
  drift from the code it claims to cover. No mocking of anything: there is
  nothing here to mock, and nothing is stubbed.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Semantic.Refusal

  describe "taxonomy" do
    test "all 18 S42 classes are present and partitioned" do
      assert length(Refusal.classes()) == 18
      assert length(Refusal.refused_classes()) == 15
      assert Refusal.blocked_classes() == [:blocked_unknown, :blocked_resource]
      assert Refusal.unsupported_classes() == [:unsupported_profile]

      assert Refusal.refused_classes() ++
               Refusal.blocked_classes() ++ Refusal.unsupported_classes() ==
               Refusal.classes()

      assert Enum.uniq(Refusal.classes()) == Refusal.classes()
    end

    test "every RFC S42 class name is a real atom in the taxonomy" do
      rfc_classes = [
        :refused_identity,
        :refused_namespace,
        :refused_structure,
        :refused_shacl,
        :refused_rule,
        :refused_falsifier,
        :refused_provenance,
        :refused_profile,
        :refused_plan,
        :refused_capability,
        :refused_authority,
        :refused_consequence,
        :refused_receipt,
        :refused_bounds,
        :refused_meta_rigor,
        :blocked_unknown,
        :blocked_resource,
        :unsupported_profile
      ]

      for class <- rfc_classes do
        assert Refusal.class?(class), "#{class} missing from taxonomy"
      end
    end

    test "class?/1 rejects a non-class" do
      refute Refusal.class?(:refused_vibes)
      refute Refusal.class?("refused_identity")
    end
  end

  describe "new/4" do
    test "builds a real struct carrying class, code, stage, detail and lawful?" do
      refusal = Refusal.new(:refused_authority, :authority_required, :authorize, %{scope: "w:r"})

      assert %Refusal{
               class: :refused_authority,
               code: :authority_required,
               stage: :authorize,
               detail: %{scope: "w:r"},
               lawful?: true
             } = refusal
    end

    test "a refusal is lawful, not an error -- the flag is always true" do
      for class <- Refusal.classes() do
        assert Refusal.new(class, :some_code, :some_stage).lawful? == true
      end
    end

    test "raises on an unknown class (programmer error, not a runtime refusal)" do
      assert_raise ArgumentError, ~r/invalid AshA2A.Semantic.Refusal/, fn ->
        Refusal.new(:refused_vibes, :whatever, :stage)
      end
    end
  end

  describe "classify/1 is total over the codes actually present in lib/" do
    test "every refusal code found on disk is explicitly mapped" do
      codes = codes_in_lib()

      # Guard the guard: if the extraction stops finding codes, this test
      # would vacuously pass. The measured count at the time this was
      # written was 70 distinct codes.
      assert length(codes) >= 60,
             "extracted only #{length(codes)} codes from lib/ -- extraction is probably broken"

      mapping = Refusal.mapping()

      unmapped =
        codes
        |> Enum.reject(&Map.has_key?(mapping, &1))
        |> Enum.reject(&(&1 in Refusal.non_refusal_codes()))

      assert unmapped == [],
             "these real refusal codes in lib/ have no explicit S42 class: #{inspect(unmapped)}"
    end

    test "every mapped class is a real taxonomy class" do
      for {code, class} <- Refusal.mapping() do
        assert Refusal.class?(class), "#{code} maps to non-class #{inspect(class)}"
      end
    end

    test "classify/1 never raises and always returns a class, mapped or not" do
      assert Refusal.classify(:authority_required) == :refused_authority
      assert Refusal.classify(:consequence_unclassified) == :refused_consequence
      assert Refusal.classify(:invalid_goal_facts) == :refused_structure
      assert Refusal.classify(:ambiguous_goal_facts_shape) == :refused_structure
      assert Refusal.classify(:ungrounded_assertion) == :refused_provenance
      assert Refusal.classify(:semantic_authority_ceiling_violated) == :refused_authority
      assert Refusal.classify(:hddl_cli_not_built) == :blocked_resource
      assert Refusal.classify(:unknown_profile) == :unsupported_profile

      # Unmapped: an honest "no classification exists", not a crash.
      assert Refusal.classify(:a_code_that_has_never_existed) == :blocked_unknown
      assert Refusal.class?(Refusal.classify(:another_unmapped_code))
    end

    defp codes_in_lib do
      patterns = [
        ~r/code:\s+:([a-z_0-9]+)/,
        ~r/error\(:([a-z_0-9]+)/,
        # \b keeps `commit_list_refusal(:refused_structure, ...)` (a helper
        # whose first arg is a CLASS atom) from being read as `refusal(:code)`.
        ~r/\brefusal\(:([a-z_0-9]+)/,
        ~r/\{:error,\s+:([a-z_0-9]+)\}/
      ]

      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        source = File.read!(path)

        Enum.flat_map(patterns, fn pattern ->
          pattern
          |> Regex.scan(source, capture: :all_but_first)
          |> Enum.map(fn [code] -> String.to_atom(code) end)
        end)
      end)
      |> Enum.uniq()
      |> Enum.sort()
    end
  end

  describe "from_error/2 maps existing codes without renaming them" do
    test "the AshA2A.CommandBus refusal shape keeps its original code" do
      # The real shape CommandBus.refusal/1 produces.
      commandbus_refusal = %{code: :authority_required, detail: "authority_required"}

      refusal = Refusal.from_error({:error, commandbus_refusal}, :authorize)

      assert refusal.code == :authority_required, "the load-bearing code must survive verbatim"
      assert refusal.class == :refused_authority
      assert refusal.stage == :authorize
      assert refusal.detail == "authority_required"
    end

    test "consequence_unclassified maps to REFUSED_CONSEQUENCE" do
      refusal = Refusal.from_error(%{code: :consequence_unclassified, detail: nil}, :construct)
      assert {refusal.class, refusal.code} == {:refused_consequence, :consequence_unclassified}
    end

    test "the AshA2A.Planning.GoalFacts codes map to REFUSED_STRUCTURE" do
      for code <- [:invalid_goal_facts, :ambiguous_goal_facts_shape, :invalid_request_id] do
        refusal = Refusal.from_error(%{code: code}, :parse)
        assert refusal.code == code
      end

      assert Refusal.from_error(%{code: :invalid_goal_facts}, :parse).class == :refused_structure

      assert Refusal.from_error(%{code: :ambiguous_goal_facts_shape}, :parse).class ==
               :refused_structure

      # request_id smuggling is an identity refusal, not a shape refusal.
      assert Refusal.from_error(%{code: :invalid_request_id}, :parse).class == :refused_identity
    end

    test "the AshA2A.Semantic.Admission codes map across four distinct classes" do
      expected = %{
        semantic_authority_ceiling_violated: :refused_authority,
        semantic_source_mismatch: :refused_identity,
        semantic_goal_missing: :refused_structure,
        semantic_identity_invalid: :refused_identity,
        semantic_fields_missing: :refused_structure,
        ungrounded_assertion: :refused_provenance,
        authority_grant_not_admissible: :refused_authority,
        real_named_entity_not_admissible: :refused_rule,
        semantic_item_invalid: :refused_structure
      }

      for {code, class} <- expected do
        refusal = Refusal.from_error(%{code: code, detail: "d"}, :admit)
        assert {refusal.code, refusal.class} == {code, class}
      end
    end

    test "the AshA2A.SemanticSubject refusal tuple maps to REFUSED_IDENTITY" do
      refusal =
        Refusal.from_error({:error, {:refused_semantic_subject, :graph_digest}}, :identify)

      assert refusal.class == :refused_identity
      assert refusal.code == :refused_semantic_subject
      assert refusal.detail == :graph_digest
    end

    test "a bare {:error, atom} store refusal is lifted" do
      assert Refusal.from_error({:error, :receipt_store_unavailable}, :prepare).class ==
               :blocked_resource

      assert Refusal.from_error({:error, :not_found}, :prepare).class == :blocked_unknown

      assert Refusal.from_error({:error, :command_conflict}, :construct).class ==
               :refused_identity
    end

    test "an already-built refusal passes through unchanged" do
      original = Refusal.new(:refused_plan, :no_hddl_operators, :plan, %{n: 0})
      assert Refusal.from_error(original, :some_other_stage) == original
    end

    test "an unrecognized term becomes BLOCKED_UNKNOWN carrying the original term" do
      refusal = Refusal.from_error({:weird, "shape", 3}, :parse)

      assert refusal.class == :blocked_unknown
      assert refusal.code == :unclassified_error
      assert refusal.detail == {:weird, "shape", 3}
    end
  end

  describe "terminal_standing/1" do
    test "each class family lands in its own terminal standing" do
      assert Refusal.terminal_standing(Refusal.new(:refused_shacl, :c, :s)) == :refused
      assert Refusal.terminal_standing(Refusal.new(:refused_bounds, :c, :s)) == :refused
      assert Refusal.terminal_standing(Refusal.new(:blocked_resource, :c, :s)) == :blocked
      assert Refusal.terminal_standing(Refusal.new(:blocked_unknown, :c, :s)) == :unknown
      assert Refusal.terminal_standing(Refusal.new(:unsupported_profile, :c, :s)) == :unsupported
    end

    test "terminal_standing/1 is total over every class" do
      for class <- Refusal.classes() do
        standing = Refusal.terminal_standing(Refusal.new(class, :c, :s))
        assert standing in [:refused, :blocked, :unknown, :unsupported]
      end
    end
  end

  describe "to_map/1" do
    test "serializes to a JSON-encodable map and survives a real Jason round trip" do
      refusal = Refusal.new(:refused_bounds, :standing_bounds_exceeded, :parsed, %{limit: 10})
      map = Refusal.to_map(refusal)

      assert map["class"] == "refused_bounds"
      assert map["code"] == "standing_bounds_exceeded"
      assert map["stage"] == "parsed"
      assert map["lawful"] == true

      assert {:ok, decoded} = map |> Jason.encode!() |> Jason.decode()
      assert decoded["class"] == "refused_bounds"
      assert decoded["lawful"] == true
    end

    test "a binary detail is preserved verbatim and a nil detail stays nil" do
      assert Refusal.to_map(Refusal.new(:refused_rule, :c, :s, "why"))["detail"] == "why"
      assert Refusal.to_map(Refusal.new(:refused_rule, :c, :s))["detail"] == nil

      assert Refusal.to_map(Refusal.new(:refused_rule, :c, :s, :atom_detail))["detail"] ==
               "atom_detail"
    end
  end
end
