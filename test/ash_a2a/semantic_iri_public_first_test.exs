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
      assert {:ok, registry} =
               MappingRegistry.register(MappingRegistry.new(), %{
                 source: "https://a.test/vocab#Settlement",
                 target: "https://b.test/vocab#Settlement",
                 kind: :close_match,
                 admission_receipt: %{receipt_id: "rcpt-map-1", fingerprint: "fp-map-1"}
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
      assert {:ok, registry} =
               MappingRegistry.register(MappingRegistry.new(), %{
                 source: "https://a.test/vocab#Vessel",
                 target: "https://b.test/vocab#Ship",
                 kind: :broad_match,
                 admission_receipt: %{receipt_id: "rcpt-map-2", fingerprint: "fp-map-2"}
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

    test "a real %AshA2A.Receipt{} admits a mapping" do
      assert {:ok, _registry} =
               MappingRegistry.register(MappingRegistry.new(), %{
                 source: "https://a.test/vocab#Settlement",
                 target: "https://b.test/vocab#Settlement",
                 kind: :exact_match,
                 admission_receipt: real_receipt()
               })
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

    test "prefix backing is reported honestly: 4 real documents, 6 prefix-only" do
      report = OntologyCache.prefix_backing_report()
      assert length(report) == map_size(Vocabulary.prefixes())

      backed = for %{prefix: p, backing: :local_document} <- report, do: p
      unbacked = for %{prefix: p, backing: :prefix_only} <- report, do: p

      assert Enum.sort(backed) == ["owl", "rdf", "rdfs", "skos"]
      assert Enum.sort(unbacked) == ["oa", "odrl", "prov", "schema", "sosa", "time"]
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
      assert map_size(Vocabulary.prefixes()) == 10
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
