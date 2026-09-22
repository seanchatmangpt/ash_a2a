defmodule AshA2A.Semantic.MetaAdmissionTest do
  @moduledoc """
  Real tests for RFC S20/S58 meta-admission -- admission applied recursively
  to the machinery.

  The two invariants under test:

      NOT Standing(v)  =>  NOT Validates(v, x)
      NOT Standing(r)  =>  NOT CanonicalDerivation(r)

  Chicago school: the real `praxis-graphlaw` wasm engine is really executed
  as a real subprocess over real corpus files, and every assertion is on a
  real returned value or a real digest. The unpinned "rogue" artifacts are
  real, well-formed files the engine really accepts -- not stubs.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Semantic.MetaAdmission
  alias AshA2A.Semantic.RootManifest
  alias AshA2A.Semantic.RootManifest.{ConformanceCorpus, EngineProbe}
  alias AshA2A.Test.Support.Sa2aCorpus

  @engine_available EngineProbe.available?()

  @pinned_machinery [
    profile: "conformance/profile/sa2a_profile.ttl",
    shapes: "conformance/shapes/command_envelope.shacl.ttl",
    schema: "conformance/schema/command_envelope.shexj",
    shape_map: "conformance/schema/command_envelope.shapemap"
  ]

  @valid_data "conformance/data/valid_command.ttl"
  @invalid_data "conformance/data/invalid_command.ttl"

  defp stage do
    staged = Sa2aCorpus.stage!()
    on_exit(fn -> Sa2aCorpus.cleanup(staged.root) end)
    staged
  end

  defp dialect(result, name) do
    Enum.find(result.dialects, &(Map.get(&1, "dialect") == name))
  end

  # Appends a real, spec-legal WebAssembly custom section (section id 0) to
  # an existing wasm module's raw bytes. A custom section is defined by the
  # WebAssembly binary format to be ignorable by any conforming engine and
  # is legal at the very end of a module, so the result really loads and
  # really executes identically to the original -- only its bytes (and
  # therefore its SHA-256) differ. This is a real, functional adversarial
  # artifact, not a mock: `node priv/graphlaw/graphlaw_host_probe.mjs version`
  # against the result reports the identical `graphlaw_version()` string.
  defp append_functional_custom_section(bytes) when is_binary(bytes) do
    name = "ash_a2a_regression_probe"
    payload = :crypto.strong_rand_bytes(32)
    content = leb128(byte_size(name)) <> name <> payload
    section = <<0>> <> leb128(byte_size(content)) <> content
    bytes <> section
  end

  # Unsigned LEB128, the integer encoding the WebAssembly binary format uses
  # for section/name lengths.
  defp leb128(n) when n < 0x80, do: <<n>>

  defp leb128(n) do
    low = rem(n, 0x80)
    rest = div(n, 0x80)
    <<low + 0x80>> <> leb128(rest)
  end

  describe "standing/3 -- what counts as an admitted judge" do
    setup do
      staged = stage()
      {:ok, manifest} = RootManifest.load(staged.path, require_engine: false)
      %{staged: staged, manifest: manifest}
    end

    @tag :graphlaw_engine
    test "a pinned artifact whose bytes match has standing", %{manifest: manifest} do
      assert {:ok, pin} =
               MetaAdmission.standing(
                 manifest,
                 "conformance/shapes/command_envelope.shacl.ttl",
                 "shacl_shapes"
               )

      assert Map.fetch!(pin, "kind") == "shacl_shapes"
      assert String.starts_with?(Map.fetch!(pin, "digest"), "sha256:")
    end

    @tag :graphlaw_engine
    test "a real, well-formed, UNPINNED artifact has no standing", %{manifest: manifest} do
      rogue = ConformanceCorpus.unpinned_falsifiers().shacl_shapes

      # It really exists and is really valid SHACL...
      assert File.exists?(RootManifest.resolve(manifest, rogue))

      # ...and being valid SHACL is not standing.
      assert {:error, %{code: :REFUSED_META_RIGOR, detail: detail}} =
               MetaAdmission.standing(manifest, rogue, "shacl_shapes")

      assert detail.reason == :not_pinned
      assert detail.artifact == rogue
      assert detail.invariant == "NOT Standing(v) => NOT Validates(v, x)"
    end

    @tag :graphlaw_engine
    test "a pinned artifact under the WRONG kind has no standing", %{manifest: manifest} do
      assert {:error, %{code: :REFUSED_META_RIGOR, detail: %{reason: :not_pinned}}} =
               MetaAdmission.standing(
                 manifest,
                 "conformance/shapes/command_envelope.shacl.ttl",
                 "n3_rules"
               )
    end

    @tag :graphlaw_engine
    test "standing is re-checked at USE time, catching a post-load swap", %{
      staged: staged,
      manifest: manifest
    } do
      shapes_relative = "conformance/shapes/command_envelope.shacl.ttl"
      assert {:ok, _} = MetaAdmission.standing(manifest, shapes_relative, "shacl_shapes")

      # Swap the judge AFTER the manifest was loaded and verified. Load-time
      # verification alone would have left this hole wide open.
      File.write!(
        Path.join(staged.root, shapes_relative),
        File.read!(Path.join(staged.root, ConformanceCorpus.unpinned_falsifiers().shacl_shapes))
      )

      assert {:error, %{code: :REFUSED_META_RIGOR, detail: detail}} =
               MetaAdmission.standing(manifest, shapes_relative, "shacl_shapes")

      assert detail.reason == :digest_drift
      refute detail.pinned == detail.actual
    end

    @tag :graphlaw_engine
    test "a pinned artifact that vanished has no standing", %{
      staged: staged,
      manifest: manifest
    } do
      File.rm!(Path.join(staged.root, "conformance/rules/derivation.n3"))

      assert {:error, %{code: :REFUSED_META_RIGOR, detail: %{reason: :artifact_missing}}} =
               MetaAdmission.standing(manifest, "conformance/rules/derivation.n3", "n3_rules")
    end

    @tag :graphlaw_engine
    test "every RFC S20 artifact kind is enumerated" do
      kinds = MetaAdmission.artifact_kinds()

      for required <- ~w(shex_schema shacl_shapes n3_rules datalog_program sparql_falsifier
                         planning_domain generator authority_policy receipt_schema
                         semantic_mapping) do
        assert required in kinds
      end
    end
  end

  describe "the engine is machinery too" do
    @tag :graphlaw_engine
    test "an unverified engine refuses every engine-backed operation" do
      staged = stage()
      {:ok, manifest} = RootManifest.load(staged.path, require_engine: false)
      refute manifest.engine_verified?

      assert {:error, %{code: :REFUSED_META_RIGOR, detail: %{reason: :engine_unverified}}} =
               MetaAdmission.validate(manifest, @valid_data, @pinned_machinery)

      assert {:error, %{code: :REFUSED_META_RIGOR, detail: %{reason: :engine_unverified}}} =
               MetaAdmission.canonical_derivation(
                 manifest,
                 @valid_data,
                 "conformance/rules/derivation.n3"
               )
    end
  end

  if @engine_available do
    describe "INVARIANT 1 -- NOT Standing(v) => NOT Validates(v, x)" do
      setup do
        staged = stage()
        {:ok, manifest} = RootManifest.load(staged.path)
        assert manifest.engine_verified?
        %{staged: staged, manifest: manifest}
      end

      test "admitted machinery over a valid graph really validates", %{manifest: manifest} do
        assert {:ok, result} = MetaAdmission.validate(manifest, @valid_data, @pinned_machinery)

        assert result.admitted?
        assert MetaAdmission.admitted?(result)
        assert dialect(result, "SHACL")["status"] == "ADMITTED"
        assert dialect(result, "SHEX")["status"] == "ADMITTED"
        assert result.graph_hash =~ ~r/\A[0-9a-f]{64}\z/
        assert result.manifest_digest == manifest.digest
        assert length(result.standing) == 4
      end

      test "admitted machinery REFUSES an invalid graph -- a data verdict, not a meta refusal", %{
        manifest: manifest
      } do
        machinery =
          Keyword.put(
            @pinned_machinery,
            :shape_map,
            "conformance/schema/invalid_command.shapemap"
          )

        assert {:ok, result} = MetaAdmission.validate(manifest, @invalid_data, machinery)

        # The machinery ran (hence {:ok, ...}); the DATA was refused.
        refute result.admitted?
        assert dialect(result, "SHACL")["status"] == "REFUSED"
        assert dialect(result, "SHACL")["detail"] =~ "1 violations"
        assert dialect(result, "SHEX")["status"] == "REFUSED"
      end

      test "FALSIFIER: unpinned shapes are refused even over a PERFECTLY VALID data graph", %{
        manifest: manifest
      } do
        rogue = ConformanceCorpus.unpinned_falsifiers().shacl_shapes
        machinery = Keyword.put(@pinned_machinery, :shapes, rogue)

        # Baseline: this exact data graph passes the admitted machinery.
        assert {:ok, baseline} = MetaAdmission.validate(manifest, @valid_data, @pinned_machinery)
        assert baseline.admitted?

        # Swap in an unpinned judge and the SAME valid data is refused --
        # not because the data is bad, but because the judge has no standing.
        assert {:error, %{code: :REFUSED_META_RIGOR, detail: detail}} =
                 MetaAdmission.validate(manifest, @valid_data, machinery)

        assert detail.reason == :not_pinned
        assert detail.artifact == rogue
        assert detail.kind == "shacl_shapes"
      end

      test "FALSIFIER (the attack this closes): unpinned shapes would LAUNDER an invalid graph",
           %{
             manifest: manifest
           } do
        rogue = ConformanceCorpus.unpinned_falsifiers().shacl_shapes
        machinery = Keyword.put(@pinned_machinery, :shapes, rogue)

        # 1. Meta-admission refuses to use the unpinned judge at all.
        assert {:error, %{code: :REFUSED_META_RIGOR}} =
                 MetaAdmission.validate(manifest, @invalid_data, machinery)

        # 2. Prove that refusal was load-bearing rather than merely cautious,
        #    by really running the engine directly with the same rogue shapes
        #    over the same invalid data, bypassing meta-admission.
        resolve = &RootManifest.resolve(manifest, &1)

        assert {:ok, laundered} =
                 EngineProbe.validate_all(
                   data: resolve.(@invalid_data),
                   profile: resolve.(@pinned_machinery[:profile]),
                   shapes: resolve.(rogue),
                   schema: resolve.(@pinned_machinery[:schema]),
                   shape_map: resolve.("conformance/schema/invalid_command.shapemap")
                 )

        laundered_shacl =
          laundered |> Map.fetch!("dialects") |> Enum.find(&(&1["dialect"] == "SHACL"))

        # The unpinned judge really admits the graph the admitted judge refused.
        assert laundered_shacl["status"] == "ADMITTED"
        assert laundered_shacl["detail"] =~ "0 violations"

        # 3. And with the admitted judge, the same graph is really refused.
        assert {:ok, honest} =
                 MetaAdmission.validate(
                   manifest,
                   @invalid_data,
                   Keyword.put(
                     @pinned_machinery,
                     :shape_map,
                     "conformance/schema/invalid_command.shapemap"
                   )
                 )

        refute honest.admitted?
        assert dialect(honest, "SHACL")["status"] == "REFUSED"
      end

      test "an unpinned ShEx schema is refused before the engine is reached", %{
        staged: staged,
        manifest: manifest
      } do
        unpinned_schema = "conformance/schema/rogue.shexj"

        File.write!(
          Path.join(staged.root, unpinned_schema),
          File.read!(Path.join(staged.root, @pinned_machinery[:schema]))
        )

        machinery = Keyword.put(@pinned_machinery, :schema, unpinned_schema)

        assert {:error, %{code: :REFUSED_META_RIGOR, detail: detail}} =
                 MetaAdmission.validate(manifest, @valid_data, machinery)

        assert detail.reason == :not_pinned
        assert detail.kind == "shex_schema"
      end

      test "a missing input data graph is refused without a fabricated verdict", %{
        manifest: manifest
      } do
        assert {:error, %{code: :REFUSED_META_RIGOR, detail: %{reason: :input_graph_missing}}} =
                 MetaAdmission.validate(manifest, "conformance/data/nope.ttl", @pinned_machinery)
      end
    end

    describe "INVARIANT 2 -- NOT Standing(r) => NOT CanonicalDerivation(r)" do
      setup do
        staged = stage()
        {:ok, manifest} = RootManifest.load(staged.path)
        %{staged: staged, manifest: manifest}
      end

      test "an admitted rule set really derives, with a real canonical graph hash", %{
        manifest: manifest
      } do
        assert {:ok, result} =
                 MetaAdmission.canonical_derivation(
                   manifest,
                   @valid_data,
                   "conformance/rules/derivation.n3"
                 )

        assert result.status == "ADMITTED"
        assert result.graph_hash =~ ~r/\A[0-9a-f]{64}\z/
        assert Map.fetch!(result.rules, "kind") == "n3_rules"
        assert result.manifest_digest == manifest.digest
      end

      test "FALSIFIER: an unpinned rule set never reaches the engine", %{manifest: manifest} do
        rogue = ConformanceCorpus.unpinned_falsifiers().n3_rules

        # It is a real, well-formed N3 rule file sitting right there...
        assert File.exists?(RootManifest.resolve(manifest, rogue))

        # ...and it cannot contribute a single derived triple.
        assert {:error, %{code: :REFUSED_META_RIGOR, detail: detail}} =
                 MetaAdmission.canonical_derivation(manifest, @valid_data, rogue)

        assert detail.reason == :not_pinned
        assert detail.kind == "n3_rules"
      end

      test "a rule set swapped after load is caught by the use-time digest check", %{
        staged: staged,
        manifest: manifest
      } do
        rules = "conformance/rules/derivation.n3"

        File.write!(
          Path.join(staged.root, rules),
          File.read!(Path.join(staged.root, ConformanceCorpus.unpinned_falsifiers().n3_rules))
        )

        assert {:error, %{code: :REFUSED_META_RIGOR, detail: %{reason: :digest_drift}}} =
                 MetaAdmission.canonical_derivation(manifest, @valid_data, rules)
      end
    end

    describe "canonical graph identity comes from the engine, never from Elixir" do
      test "the engine's RDFC-1.0 hash is order- and prefix-label-independent" do
        staged = stage()
        {:ok, manifest} = RootManifest.load(staged.path)

        original = RootManifest.resolve(manifest, @valid_data)

        reordered = Path.join(staged.root, "conformance/data/valid_command_reordered.ttl")

        File.write!(reordered, """
        @prefix zz:   <urn:ash-a2a:vocab:> .
        @prefix other: <urn:ash-a2a:conformance:> .

        other:command-001 zz:payloadDigest "sha256:0000000000000000000000000000000000000000000000000000000000000001" .
        other:command-001 zz:principalId   "principal:conformance-operator" .
        other:command-001 zz:capabilityId  "conformance:echo" .
        other:command-001 a                zz:Command .
        """)

        assert {:ok, a} = EngineProbe.graph_hash(original)
        assert {:ok, b} = EngineProbe.graph_hash(reordered)

        # Different prefix labels, different triple order, same canonical graph.
        refute File.read!(original) == File.read!(reordered)
        assert a == b

        # And a genuinely different graph hashes differently.
        assert {:ok, c} = EngineProbe.graph_hash(RootManifest.resolve(manifest, @invalid_data))
        refute a == c
      end
    end

    describe "engine standing is bound to USE time, not just load time" do
      setup do
        wasm_copy =
          Path.join(
            System.tmp_dir!(),
            "graphlaw_engine_copy_#{System.unique_integer([:positive, :monotonic])}.wasm"
          )

        File.cp!(EngineProbe.wasm_path([]), wasm_copy)
        on_exit(fn -> File.rm(wasm_copy) end)

        staged = Sa2aCorpus.stage!(engine_path: wasm_copy)
        on_exit(fn -> Sa2aCorpus.cleanup(staged.root) end)

        {:ok, manifest} = RootManifest.load(staged.path, wasm_path: wasm_copy)
        assert manifest.engine_verified?
        assert {:ok, expected_digest} = RootManifest.artifact_digest(wasm_copy)
        assert manifest.engine_verified_digest == expected_digest

        machinery = Keyword.put(@pinned_machinery, :wasm_path, wasm_copy)

        %{staged: staged, manifest: manifest, wasm_copy: wasm_copy, machinery: machinery}
      end

      test "(b) an unchanged engine artifact continues to authorize every call",
           %{manifest: manifest, machinery: machinery} do
        assert {:ok, first} = MetaAdmission.validate(manifest, @valid_data, machinery)
        assert first.admitted?

        assert {:ok, second} = MetaAdmission.validate(manifest, @valid_data, machinery)
        assert second.admitted?

        assert {:ok, derived} =
                 MetaAdmission.canonical_derivation(
                   manifest,
                   @valid_data,
                   "conformance/rules/derivation.n3",
                   wasm_path: machinery[:wasm_path]
                 )

        assert derived.status == "ADMITTED"
      end

      test "(a) a byte-altered, same-version engine swapped in after load is refused at use time",
           %{manifest: manifest, machinery: machinery, wasm_copy: wasm_copy} do
        # Baseline: the load-time-verified engine authorizes normally before any swap.
        assert {:ok, baseline} = MetaAdmission.validate(manifest, @valid_data, machinery)
        assert baseline.admitted?

        original_bytes = File.read!(wasm_copy)
        altered_bytes = append_functional_custom_section(original_bytes)
        refute altered_bytes == original_bytes

        # Swap the artifact AFTER load-time verification succeeded, BEFORE use.
        # This is the exact TOCTOU repro: load-time verification passed once,
        # against artifact A; execution now re-resolves the SAME path and must
        # not go on trusting it.
        File.write!(wasm_copy, altered_bytes)

        # The altered artifact is real and FUNCTIONAL -- it reports the
        # IDENTICAL version string the manifest expects. A version check
        # alone would not catch this swap; the bare `engine_verified?`
        # boolean this branch used to gate on would not either. Only a
        # real digest re-check at use time catches it.
        assert {:ok, "praxis-graphlaw v26.7.5"} = EngineProbe.version(wasm_path: wasm_copy)
        refute manifest.engine_verified_digest == RootManifest.digest_bytes(altered_bytes)

        assert {:error, %{code: :REFUSED_META_RIGOR, detail: detail}} =
                 MetaAdmission.validate(manifest, @valid_data, machinery)

        assert detail.reason == :engine_digest_drift
        assert detail.expected == manifest.engine_verified_digest
        refute detail.expected == detail.observed

        assert {:error, %{code: :REFUSED_META_RIGOR, detail: derivation_detail}} =
                 MetaAdmission.canonical_derivation(
                   manifest,
                   @valid_data,
                   "conformance/rules/derivation.n3",
                   wasm_path: wasm_copy
                 )

        assert derivation_detail.reason == :engine_digest_drift
      end
    end
  else
    test "SKIPPED: praxis-graphlaw engine not resolvable on this host" do
      # Named, visible skip -- the engine-backed invariant tests require the
      # real wasm. Never substituted with a mock.
      refute EngineProbe.available?()
    end
  end
end
