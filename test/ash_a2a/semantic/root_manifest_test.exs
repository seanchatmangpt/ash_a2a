defmodule AshA2A.Semantic.RootManifestTest do
  @moduledoc """
  Real tests for the SA2A content-addressed trust root (RFC S21).

  Chicago school throughout: real files on disk, real SHA-256 digests, real
  `AshA2A.Authority` structs, and -- where the engine is resolvable -- the
  real `praxis-graphlaw` wasm module executed as a real subprocess. Nothing
  here stubs a collaborator or asserts that a function "was called".
  """

  use ExUnit.Case, async: true

  alias AshA2A.{Authority, Identity}
  alias AshA2A.Semantic.RootManifest
  alias AshA2A.Semantic.RootManifest.{ConformanceCorpus, EngineProbe}
  alias AshA2A.Test.Support.Sa2aCorpus

  @engine_available EngineProbe.available?()

  defp stage(opts \\ []) do
    staged = Sa2aCorpus.stage!(opts)
    on_exit(fn -> Sa2aCorpus.cleanup(staged.root) end)
    staged
  end

  defp custodian(subject_value \\ "root-custodian-1") do
    principal = Identity.principal(subject_value)

    {principal,
     Authority.new(principal, RootManifest.mutation_capability_id(), source: :root_custodian)}
  end

  describe "content address coverage" do
    test "every struct field is either addressed or explicitly unaddressed" do
      struct_fields =
        %RootManifest{} |> Map.from_struct() |> Map.keys() |> Enum.sort()

      declared =
        Enum.sort(RootManifest.addressed_fields() ++ RootManifest.unaddressed_fields())

      # A field added later that is neither addressed nor deliberately
      # excluded would silently fall outside the content address. This is the
      # mechanical check that closes that hole.
      assert struct_fields == declared
    end

    test "machine-local values are excluded from the address" do
      assert :root in RootManifest.unaddressed_fields()
      assert :digest in RootManifest.unaddressed_fields()
      assert :engine_verified? in RootManifest.unaddressed_fields()
      assert :verified_at in RootManifest.unaddressed_fields()
    end
  end

  describe "content addressing" do
    @tag :graphlaw_engine
    test "the committed manifest's recorded digest is reproduced by rebuilding from the real corpus" do
      {:ok, rebuilt} = ConformanceCorpus.build()

      committed =
        ConformanceCorpus.manifest_path()
        |> File.read!()
        |> JSON.decode!()
        |> Map.fetch!("digest")

      assert rebuilt.digest == committed
      assert String.starts_with?(rebuilt.digest, "sha256:")
      assert byte_size(rebuilt.digest) == 7 + 64
    end

    @tag :graphlaw_engine
    test "the content address is INDEPENDENT of where the corpus lives on disk" do
      {:ok, at_priv} = ConformanceCorpus.build()
      staged = stage()

      # Same bytes, different absolute root. Two runtimes never agree on
      # absolute paths, so a path-dependent address could never be shared.
      refute staged.root == ConformanceCorpus.root()
      assert staged.manifest.digest == at_priv.digest
    end

    test "canonical_form sorts keys, so the address survives large non-sorted maps" do
      # >32 keys forces Elixir's hashmap representation, whose iteration order
      # is NOT sorted -- a real test of the sorting rather than a tautology.
      keys = for i <- 1..40, do: "k#{i}"
      forward = keys |> Enum.map(&{&1, &1}) |> Map.new()
      reverse = keys |> Enum.reverse() |> Enum.map(&{&1, &1}) |> Map.new()

      refute Map.keys(forward) == Enum.sort(Map.keys(forward)),
             "expected an unsorted hashmap iteration order for this test to be meaningful"

      a = %RootManifest{version_policy: forward}
      b = %RootManifest{version_policy: reverse}

      assert IO.iodata_to_binary(RootManifest.canonical_form(a)) ==
               IO.iodata_to_binary(RootManifest.canonical_form(b))

      assert RootManifest.content_digest(a) == RootManifest.content_digest(b)
    end

    @tag :graphlaw_engine
    test "changing any addressed field moves the content address" do
      {:ok, manifest} = ConformanceCorpus.build()
      moved = %{manifest | version_policy: Map.put(manifest.version_policy, "extra", "x")}

      refute RootManifest.content_digest(moved) == manifest.digest
    end

    @tag :graphlaw_engine
    test "changing an UNADDRESSED field does not move the content address" do
      {:ok, manifest} = ConformanceCorpus.build()
      relocated = %{manifest | root: "/somewhere/else", verified_at: DateTime.utc_now()}

      assert RootManifest.content_digest(relocated) == manifest.digest
    end
  end

  describe "load/2 fails closed" do
    test "refuses a missing manifest" do
      assert {:error, %{code: :REFUSED_MANIFEST_NOT_FOUND}} =
               RootManifest.load("/nonexistent/sa2a/root_manifest.json", require_engine: false)
    end

    @tag :graphlaw_engine
    test "refuses a manifest whose recorded digest does not match its contents" do
      staged = stage()

      tampered =
        staged.path
        |> File.read!()
        |> JSON.decode!()
        |> put_in(["version_policy", "ordinary_transport_agents_may_mutate"], true)
        |> JSON.encode!()

      File.write!(staged.path, tampered)

      assert {:error, %{code: :REFUSED_MANIFEST_DIGEST_MISMATCH, detail: detail}} =
               RootManifest.load(staged.path, require_engine: false)

      assert detail.recorded != detail.recomputed
    end

    @tag :graphlaw_engine
    test "refuses when a pinned artifact's real bytes drifted" do
      staged = stage()
      shapes = Path.join(staged.root, "conformance/shapes/command_envelope.shacl.ttl")
      File.write!(shapes, File.read!(shapes) <> "\n# silently appended\n")

      assert {:error, %{code: :REFUSED_MANIFEST_DRIFT, detail: detail}} =
               RootManifest.load(staged.path, require_engine: false)

      assert detail.path == "conformance/shapes/command_envelope.shacl.ttl"
      assert detail.kind == "shacl_shapes"
      refute detail.pinned == detail.actual
    end

    @tag :graphlaw_engine
    test "refuses when a pinned artifact is gone" do
      staged = stage()
      File.rm!(Path.join(staged.root, "conformance/rules/derivation.n3"))

      assert {:error, %{code: :REFUSED_MANIFEST_ARTIFACT_MISSING}} =
               RootManifest.load(staged.path, require_engine: false)
    end

    @tag :graphlaw_engine
    test "refuses a malformed (non-JSON-object) manifest" do
      staged = stage()
      File.write!(staged.path, "not json at all")

      assert {:error, %{code: :REFUSED_MANIFEST_MALFORMED}} =
               RootManifest.load(staged.path, require_engine: false)
    end

    @tag :graphlaw_engine
    test "refuses a manifest missing a required field" do
      staged = stage()

      stripped = staged.path |> File.read!() |> JSON.decode!() |> Map.delete("validators")
      File.write!(staged.path, JSON.encode!(stripped))

      assert {:error,
              %{code: :REFUSED_MANIFEST_MALFORMED, detail: %{missing_fields: [:validators]}}} =
               RootManifest.load(staged.path, require_engine: false)
    end

    @tag :graphlaw_engine
    test "require_engine: false yields a manifest explicitly marked unverified" do
      staged = stage()
      assert {:ok, manifest} = RootManifest.load(staged.path, require_engine: false)
      refute manifest.engine_verified?
    end
  end

  if @engine_available do
    describe "engine identity (real praxis-graphlaw wasm executed)" do
      test "the engine really reports the version the manifest pins" do
        assert {:ok, version} = EngineProbe.version()
        assert version == ConformanceCorpus.expected_engine_version()
      end

      test "the pinned engine artifact's real sha256 matches the pin" do
        {:ok, manifest} = ConformanceCorpus.build()
        {:ok, actual} = RootManifest.artifact_digest(EngineProbe.wasm_path())

        assert Map.fetch!(manifest.engine, "artifact_digest") == actual
      end

      test "a fully verified load marks the engine verified" do
        staged = stage()
        assert {:ok, manifest} = RootManifest.load(staged.path)
        assert manifest.engine_verified?
        assert %DateTime{} = manifest.verified_at
      end

      test "refuses when the engine reports a different version than pinned" do
        staged = stage(expected_version: "praxis-graphlaw v0.0.0-not-the-pinned-build")

        assert {:error, %{code: :REFUSED_MANIFEST_ENGINE_DRIFT, detail: detail}} =
                 RootManifest.load(staged.path)

        assert detail.reason == :version_mismatch
        assert detail.expected == "praxis-graphlaw v0.0.0-not-the-pinned-build"
        assert detail.actual == ConformanceCorpus.expected_engine_version()
      end

      test "refuses when the resolved engine artifact is not the pinned one" do
        staged = stage()
        other_real_file = EngineProbe.host_path()

        assert {:error, %{code: :REFUSED_MANIFEST_ENGINE_DRIFT, detail: detail}} =
                 RootManifest.load(staged.path, wasm_path: other_real_file)

        assert detail.reason == :artifact_digest_mismatch
        refute detail.pinned == detail.actual
      end

      test "refuses when the engine artifact cannot be resolved at all" do
        staged = stage()

        assert {:error, %{code: :REFUSED_MANIFEST_ENGINE_DRIFT, detail: %{reason: reason}}} =
                 RootManifest.load(staged.path, wasm_path: "/nonexistent/graphlaw.wasm")

        assert reason == :engine_artifact_missing
      end
    end
  else
    test "SKIPPED: praxis-graphlaw engine not resolvable on this host" do
      # A named, visible skip -- never a silent mock substitution. Set
      # GRAPHLAW_WASM (or config :ash_a2a, :graphlaw_wasm_path) to the real
      # praxis_graphlaw_wasm_bg.wasm to run the engine-backed cases.
      refute EngineProbe.available?()
    end
  end

  describe "mutate/5 -- no ordinary agent may mutate the trust root" do
    setup do
      staged = stage()
      {:ok, manifest} = RootManifest.load(staged.path, require_engine: false)
      %{manifest: manifest}
    end

    @tag :graphlaw_engine
    test "an ordinary transport-verified agent is refused even with the right capability and subject",
         %{manifest: manifest} do
      # This is the exact authority an ordinary authenticated A2A caller gets.
      ordinary =
        Authority.from_verified_identity("agent-7", RootManifest.mutation_capability_id())

      # It genuinely admits for the capability -- the capability check passes.
      assert Authority.admits?(ordinary, %{
               principal_id: ordinary.subject,
               capability_id: RootManifest.mutation_capability_id()
             })

      # And it is still structurally refused, on custody source.
      assert {:error, %{code: :REFUSED_ROOT_CUSTODY, detail: detail}} =
               RootManifest.mutate(
                 manifest,
                 %{version_policy: %{"ordinary_transport_agents_may_mutate" => true}},
                 ordinary,
                 ordinary.subject,
                 require_engine: false
               )

      assert detail.actual_source == :transport_verified
      assert detail.required_source == RootManifest.custody_source()
    end

    @tag :graphlaw_engine
    test "an authority whose subject does not match the independently supplied principal is refused",
         %{manifest: manifest} do
      {_alice, authority} = custodian("alice")
      bob = Identity.principal("bob")

      # The tautological version of this check (comparing authority.subject
      # against itself) would have passed here. It must not.
      assert {:error, %{code: :authority_mismatch}} =
               RootManifest.mutate(manifest, %{manufacturers: []}, authority, bob,
                 require_engine: false
               )
    end

    @tag :graphlaw_engine
    test "an expired custodian authority is refused", %{manifest: manifest} do
      principal = Identity.principal("root-custodian-expired")

      expired =
        Authority.new(principal, RootManifest.mutation_capability_id(),
          source: :root_custodian,
          expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
        )

      assert {:error, %{code: :authority_mismatch}} =
               RootManifest.mutate(manifest, %{manufacturers: []}, expired, principal,
                 require_engine: false
               )
    end

    @tag :graphlaw_engine
    test "a custodian authority for the wrong capability is refused", %{manifest: manifest} do
      principal = Identity.principal("root-custodian-1")
      wrong = Authority.new(principal, "some:other:capability", source: :root_custodian)

      assert {:error, %{code: :authority_mismatch}} =
               RootManifest.mutate(manifest, %{manufacturers: []}, wrong, principal,
                 require_engine: false
               )
    end

    @tag :graphlaw_engine
    test "a nil authority is refused", %{manifest: manifest} do
      assert {:error, %{code: :authority_mismatch}} =
               RootManifest.mutate(
                 manifest,
                 %{manufacturers: []},
                 nil,
                 Identity.principal("whoever"),
                 require_engine: false
               )
    end

    @tag :graphlaw_engine
    test "a non-principal identity is refused", %{manifest: manifest} do
      {_p, authority} = custodian()

      assert {:error, %{code: :authority_mismatch}} =
               RootManifest.mutate(
                 manifest,
                 %{manufacturers: []},
                 authority,
                 Identity.agent("not-a-principal"),
                 require_engine: false
               )
    end

    @tag :graphlaw_engine
    test "an unknown field is refused and no new atom is created", %{manifest: manifest} do
      {principal, authority} = custodian()
      before = :erlang.system_info(:atom_count)

      assert {:error, %{code: :REFUSED_MANIFEST_MALFORMED, detail: detail}} =
               RootManifest.mutate(
                 manifest,
                 %{"totally_made_up_field_qwerty" => 1},
                 authority,
                 principal,
                 require_engine: false
               )

      assert :"$unknown" in detail.unmutable_or_unknown_fields
      assert :erlang.system_info(:atom_count) == before
    end

    @tag :graphlaw_engine
    test "a real custodian mutation succeeds and MOVES the content address", %{manifest: manifest} do
      {principal, authority} = custodian()
      original_digest = manifest.digest

      assert {:ok, mutated} =
               RootManifest.mutate(
                 manifest,
                 %{manufacturers: manifest.manufacturers ++ [%{"id" => "new-manufacturer"}]},
                 authority,
                 principal,
                 require_engine: false
               )

      refute mutated.digest == original_digest
      assert mutated.digest == RootManifest.content_digest(mutated)
      assert length(mutated.manufacturers) == length(manifest.manufacturers) + 1

      # The input manifest is untouched -- there is no partial mutation.
      assert manifest.digest == original_digest
    end

    @tag :graphlaw_engine
    test "mutation re-verifies pins against disk and refuses if the corpus drifted" do
      staged = stage()
      {:ok, manifest} = RootManifest.load(staged.path, require_engine: false)
      {principal, authority} = custodian()

      rules = Path.join(staged.root, "conformance/rules/derivation.n3")
      File.write!(rules, File.read!(rules) <> "\n# drift\n")

      assert {:error, %{code: :REFUSED_MANIFEST_DRIFT}} =
               RootManifest.mutate(manifest, %{manufacturers: []}, authority, principal,
                 require_engine: false
               )
    end
  end

  describe "pin metadata" do
    @tag :graphlaw_engine
    test "the corpus pins exactly the machinery, and deliberately not the data or the falsifiers" do
      {:ok, manifest} = ConformanceCorpus.build()
      paths = manifest |> RootManifest.all_pins() |> Enum.map(&Map.fetch!(&1, "path"))
      falsifiers = ConformanceCorpus.unpinned_falsifiers()

      assert "conformance/shapes/command_envelope.shacl.ttl" in paths
      assert "conformance/schema/command_envelope.shexj" in paths
      assert "conformance/rules/derivation.n3" in paths
      assert "conformance/queries/falsifier_unauthorized_actuation.rq" in paths

      refute falsifiers.shacl_shapes in paths
      refute falsifiers.n3_rules in paths
      refute "conformance/data/valid_command.ttl" in paths
      refute "conformance/data/invalid_command.ttl" in paths

      # ...and the unpinned falsifiers are nonetheless real files on disk.
      assert File.exists?(Path.join(ConformanceCorpus.root(), falsifiers.shacl_shapes))
      assert File.exists?(Path.join(ConformanceCorpus.root(), falsifiers.n3_rules))
    end

    @tag :graphlaw_engine
    test "every pin carries a real sha256 of the real file" do
      {:ok, manifest} = ConformanceCorpus.build()

      for pin <- RootManifest.all_pins(manifest) do
        absolute = RootManifest.resolve(manifest, Map.fetch!(pin, "path"))
        assert {:ok, actual} = RootManifest.artifact_digest(absolute)
        assert Map.fetch!(pin, "digest") == actual
        assert Map.fetch!(pin, "kind") in AshA2A.Semantic.MetaAdmission.artifact_kinds()
      end
    end
  end
end
