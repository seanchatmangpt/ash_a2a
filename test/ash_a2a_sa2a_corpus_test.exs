defmodule AshA2ASA2ACorpusTest do
  @moduledoc """
  Chicago-school tests over the REAL SA2A conformance corpus on disk.

  No mocks, no stubs, no fabricated fixtures: every assertion is over real file
  bytes in `priv/sa2a_conformance/`, real SHA-256 digests recomputed here by
  `:crypto`, and the real typed values decoded from the real sidecars. The
  drift tests copy the real corpus to a real temp directory and really mutate a
  real byte, then assert the loader really fails closed.
  """
  use ExUnit.Case, async: true

  alias AshA2A.SA2A.Corpus
  alias AshA2A.SA2A.Corpus.Vector

  setup_all do
    {:ok, corpus: Corpus.load!()}
  end

  describe "load/1 integrity gate" do
    test "loads the shipped corpus with every manifested sha256 matching", %{corpus: corpus} do
      assert %Corpus{} = corpus
      assert map_size(corpus.files) == 30
      assert corpus.dir |> Path.basename() == "sa2a_conformance"
    end

    test "every manifested sha256 really is the sha256 of the real file bytes", %{corpus: corpus} do
      for {rel, entry} <- corpus.files do
        bytes = File.read!(Path.join(corpus.dir, rel))
        actual = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

        assert actual == entry["sha256"], "sha256 drift in #{rel}"
        assert entry["bytes"] == byte_size(bytes), "size drift in #{rel}"
        assert String.length(entry["blake3"]) == 64
      end
    end

    test "a single flipped byte fails the load closed" do
      tmp = temp_corpus()
      victim = Path.join(tmp, "base.ttl")
      File.write!(victim, File.read!(victim) <> "\n# drift\n")

      assert {:error, %{code: :sa2a_corpus_digest_mismatch, detail: detail}} =
               Corpus.load(dir: tmp)

      assert detail.file == "base.ttl"
      assert detail.algorithm == :sha256
      refute detail.expected == detail.actual
    end

    test "a deleted manifested file fails the load closed" do
      tmp = temp_corpus()
      File.rm!(Path.join(tmp, "rules/denials.n3"))

      assert {:error, %{code: :sa2a_corpus_file_missing, detail: %{file: "rules/denials.n3"}}} =
               Corpus.load(dir: tmp)
    end

    test "an extra unmanifested file fails the load closed" do
      tmp = temp_corpus()
      File.write!(Path.join(tmp, "negative/smuggled.ttl"), "@prefix ex: <http://x/> .\n")

      assert {:error, %{code: :sa2a_corpus_unmanifested_file, detail: extra}} =
               Corpus.load(dir: tmp)

      assert "negative/smuggled.ttl" in extra
    end

    test "a missing directory fails the load closed" do
      assert {:error, %{code: :sa2a_corpus_dir_missing}} =
               Corpus.load(dir: Path.join(System.tmp_dir!(), "sa2a_no_such_corpus_#{uniq()}"))
    end
  end

  describe "vectors" do
    test "the RFC S61 minimum falsifier suite is present, one vector per class", %{corpus: corpus} do
      classes = corpus |> Corpus.vectors() |> Enum.map(& &1.class) |> Enum.sort()

      assert classes == [
               "canonicalization_distinctness",
               "canonicalization_isomorphism",
               "graph_global_falsifier",
               "malformed_turtle",
               "positive_baseline",
               "shacl_violation",
               "shacl_violation_over_warning",
               "shacl_warning_only",
               "shex_invalid_structure",
               "unadmitted_predicate"
             ]
    end

    test "every expected value is a digest or a typed refusal code, never RDF text", %{
      corpus: corpus
    } do
      for v <- Corpus.vectors(corpus) do
        assert v.expected_admission in [:admitted, :refused]
        assert v.graph_digest =~ ~r/\A[0-9a-f]{64}\z/
        assert v.law_graph_digest =~ ~r/\A[0-9a-f]{64}\z/

        case v.expected_refusal do
          nil ->
            assert v.expected_admission == :admitted

          %{code: code} ->
            assert v.expected_admission == :refused
            assert is_atom(code)
            assert Atom.to_string(code) =~ ~r/\Asa2a_/
        end
      end
    end

    test "refusal codes are a closed vocabulary -- an invented one fails the load" do
      tmp = temp_corpus()
      sidecar = Path.join(tmp, "negative/shacl_violation.expected.json")

      File.read!(sidecar)
      |> String.replace("\"sa2a_shacl_violation\"", "\"sa2a_invented_code\"")
      |> then(&File.write!(sidecar, &1))

      remanifest(tmp, "negative/shacl_violation.expected.json")

      assert {:error, %{code: :sa2a_corpus_vector_invalid, detail: detail}} =
               Corpus.load(dir: tmp)

      assert detail.unknown_refusal_code == "sa2a_invented_code"
    end

    test "each vector's graph is the real file content on disk", %{corpus: corpus} do
      for v <- Corpus.vectors(corpus) do
        assert v.graph == File.read!(Path.join(corpus.dir, v.file))
      end
    end

    test "fetch_vector!/2 raises for an unknown name", %{corpus: corpus} do
      assert %Vector{name: "base"} = Corpus.fetch_vector!(corpus, "base")
      assert_raise KeyError, fn -> Corpus.fetch_vector!(corpus, "no_such_vector") end
    end
  end

  describe "RFC S12 -- canonical graph identity" do
    test "the isomorphism vector demands the base digest and records that it FAILS today", %{
      corpus: corpus
    } do
      iso = Corpus.fetch_vector!(corpus, "base_bnode_relabelled")
      base = Corpus.fetch_vector!(corpus, "base")

      # The RFC requirement, held at the RFC's value rather than weakened to the engine's.
      assert iso.digest_must_equal_vector == "base"
      assert iso.expected_admission == :admitted

      # ...and the honest, measured state of the pinned engine.
      assert iso.conformance == :failing_on_pinned_engine
      assert iso.failure =~ "BLANK NODE RELABELLING"
      refute iso.graph_digest == base.graph_digest
    end

    test "the one-triple-changed vector is lawful but must not collide with base", %{
      corpus: corpus
    } do
      changed = Corpus.fetch_vector!(corpus, "one_triple_changed")
      base = Corpus.fetch_vector!(corpus, "base")

      assert changed.digest_must_differ_from_vector == "base"
      assert changed.conformance == :holds
      assert changed.expected_admission == :admitted
      refute changed.graph_digest == base.graph_digest

      # It really does differ from base by exactly one triple's object: take the
      # statement lines of both files (dropping the comment headers, which
      # legitimately differ) and diff them.
      base_stmts = statements(base.graph)
      changed_stmts = statements(changed.graph)

      assert length(base_stmts) == length(changed_stmts)
      assert base_stmts -- changed_stmts == [~s(ex:tier "1"^^xsd:integer .)]
      assert changed_stmts -- base_stmts == [~s(ex:tier "9"^^xsd:integer .)]
    end

    test "all ten vector digests are pairwise distinct", %{corpus: corpus} do
      digests = corpus |> Corpus.vectors() |> Enum.map(& &1.graph_digest)
      assert length(Enum.uniq(digests)) == length(digests)
    end
  end

  describe "RFC S15 -- a sh:Warning must not override a failing sh:Violation" do
    test "the severity partition decides admission on every SHACL vector", %{corpus: corpus} do
      for name <-
            ~w(base shacl_warning_only shacl_violation shacl_violation_and_warning unadmitted_predicate) do
        v = Corpus.fetch_vector!(corpus, name)
        p = Vector.shacl_partition(v)
        viol = p["violations_only"]["status"]

        assert Vector.admission_from_severity(viol) == v.expected_admission,
               "S15 derivation disagrees with the sidecar for #{name}"
      end
    end

    test "warning-only is REFUSED by graphlaw's conforms but ADMITTED by SA2A", %{corpus: corpus} do
      v = Corpus.fetch_vector!(corpus, "shacl_warning_only")
      p = Vector.shacl_partition(v)

      assert v.measured["dialects"]["SHACL"] == "REFUSED"
      assert p["full"]["status"] == "REFUSED"
      assert p["violations_only"]["status"] == "ADMITTED"
      assert p["warnings_only"]["status"] == "REFUSED"

      assert Vector.severity_class("ADMITTED", "REFUSED") == :warning_only
      assert v.expected_admission == :admitted
      assert v.expected_refusal == nil
      assert v.conformance == :holds
    end

    test "a violation alongside a warning still refuses, attributed to the violation", %{
      corpus: corpus
    } do
      v = Corpus.fetch_vector!(corpus, "shacl_violation_and_warning")
      p = Vector.shacl_partition(v)

      assert p["full"]["results"] == 2
      assert p["violations_only"]["results"] == 1
      assert p["warnings_only"]["results"] == 1
      assert Vector.severity_class("REFUSED", "REFUSED") == :violation
      assert v.expected_admission == :refused
      assert v.expected_refusal.code == :sa2a_shacl_violation
      assert v.expected_refusal.severity == "sh:Violation"
    end

    test "a clean graph classifies as clean, not as warning-only", %{corpus: corpus} do
      p = corpus |> Corpus.fetch_vector!("base") |> Vector.shacl_partition()
      assert Vector.severity_class(p["violations_only"]["status"], p["full"]["status"]) == :clean
    end
  end

  describe "dialect isolation -- each negative vector names one cause" do
    test "each single-dialect vector refuses exactly the dialect it targets", %{corpus: corpus} do
      expected = %{
        "shex_structure" => "SHEX",
        "shacl_violation" => "SHACL",
        "unadmitted_predicate" => "SHACL",
        "falsifier_positive" => "N3_DENIAL"
      }

      for {name, dialect} <- expected do
        v = Corpus.fetch_vector!(corpus, name)
        refused = for {d, "REFUSED"} <- v.measured["dialects"], do: d

        assert refused == [dialect],
               "#{name} should refuse only #{dialect}, refused #{inspect(refused)}"

        assert v.expected_refusal.dialect == dialect
      end
    end

    test "the base vector admits on every dialect", %{corpus: corpus} do
      v = Corpus.fetch_vector!(corpus, "base")
      assert Map.values(v.measured["dialects"]) |> Enum.uniq() == ["ADMITTED"]
      assert v.expected_admission == :admitted
    end
  end

  describe "law graph composition" do
    test "law_graph/2 is the subject graph plus the admitted rules and hooks", %{corpus: corpus} do
      v = Corpus.fetch_vector!(corpus, "base")
      law = Corpus.law_graph(corpus, v)

      assert law ==
               Enum.join(
                 [v.graph, Corpus.part(corpus, :rules), Corpus.part(corpus, :hooks)],
                 "\n"
               )

      assert law =~ "=> false ."
      assert law =~ "kh:Hook"
      assert String.starts_with?(law, v.graph)
    end

    test "the fixed parts are the real files", %{corpus: corpus} do
      for {key, file} <- [
            profile: "profile.ttl",
            shapes: "shapes.shacl.ttl",
            shapes_violations: "shapes.violations.shacl.ttl",
            shapes_warnings: "shapes.warnings.shacl.ttl",
            shex_schema: "schema.shex",
            shape_map: "shape_map.json",
            rules: "rules/denials.n3",
            hooks: "hooks/admitted_hooks.ttl",
            event: "event.ttl"
          ] do
        assert Corpus.part(corpus, key) == File.read!(Path.join(corpus.dir, file))
      end
    end

    test "the severity-partitioned shapes really are severity-partitioned", %{corpus: corpus} do
      # Compare STATEMENTS, not raw text: each partition's comment header
      # explains both severities, so a substring check over the whole file would
      # be measuring prose rather than shapes.
      viol = corpus |> Corpus.part(:shapes_violations) |> statements() |> Enum.join("\n")
      warn = corpus |> Corpus.part(:shapes_warnings) |> statements() |> Enum.join("\n")
      full = corpus |> Corpus.part(:shapes) |> statements() |> Enum.join("\n")

      refute viol =~ "sh:Warning"
      assert viol =~ "sh:severity sh:Violation"

      assert warn =~ "sh:severity sh:Warning"
      refute warn =~ "sh:Violation"

      assert full =~ "sh:severity sh:Warning"
      assert full =~ "sh:severity sh:Violation"

      # The partition is exhaustive: every severity-bearing statement in the
      # full shapes graph appears in exactly one of the two partitions.
      severities = fn text ->
        text |> statements() |> Enum.filter(&String.starts_with?(&1, "sh:severity"))
      end

      assert Enum.sort(severities.(Corpus.part(corpus, :shapes))) ==
               Enum.sort(
                 severities.(Corpus.part(corpus, :shapes_violations)) ++
                   severities.(Corpus.part(corpus, :shapes_warnings))
               )
    end

    test "the shape map is the [[node, shape], ...] shape validate_all/5 parses", %{
      corpus: corpus
    } do
      assert {:ok, pairs} = JSON.decode(Corpus.part(corpus, :shape_map))
      assert length(pairs) == 2
      for pair <- pairs, do: assert(length(pair) == 2)
    end

    test "the ShEx schema is ShExJ, which is what the wasm boundary actually takes", %{
      corpus: corpus
    } do
      assert {:ok, schema} = JSON.decode(Corpus.part(corpus, :shex_schema))
      assert schema["type"] == "Schema"
      assert [%{"type" => "ShapeDecl", "id" => id}] = schema["shapes"]
      assert id == "http://example.org/sa2a/AgentShexShape"
    end
  end

  describe "engine pinning and honest deferrals" do
    test "the manifest pins the exact wasm artifact the values were measured against", %{
      corpus: corpus
    } do
      e = Corpus.engine(corpus)

      assert e["graphlaw_version"] == "praxis-graphlaw v26.7.5"
      assert e["wasm_sha256"] =~ ~r/\A[0-9a-f]{64}\z/
      assert e["wasm_bytes"] == 3_249_361

      # The pinned engine's own BLAKE3 self-test equals the published vector for "abc".
      assert e["blake3_self_test"]["digest"] ==
               "6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85"
    end

    test "if the pinned wasm is on this machine its real sha256 matches the manifest", %{
      corpus: corpus
    } do
      path = Path.join("/Users/sac/praxis", Corpus.engine(corpus)["wasm_path"])

      if File.exists?(path) do
        actual = Base.encode16(:crypto.hash(:sha256, File.read!(path)), case: :lower)
        assert actual == Corpus.engine(corpus)["wasm_sha256"]
      else
        # Not a silent pass: the pinning claim is simply not checkable here.
        assert Corpus.engine(corpus)["wasm_sha256"] =~ ~r/\A[0-9a-f]{64}\z/
      end
    end

    test "every measured divergence from the RFC is recorded, not hidden", %{corpus: corpus} do
      ids = corpus |> Corpus.deferred() |> Enum.map(& &1["id"]) |> Enum.sort()

      assert ids == [
               "hooks_never_register_through_wasm_run_hooks",
               "malformed_turtle_is_not_refused_by_the_engine",
               "profile_graph_axioms_are_not_applied_to_the_data_graph",
               "shacl_result_severity_not_exposed_by_pinned_wasm"
             ]

      for entry <- Corpus.deferred(corpus) do
        assert entry["status"] in ~w(BLOCKED_ON_PINNED_ENGINE WORKED_AROUND HOST_GATE_REQUIRED OBSERVED)
        assert String.length(entry["measured"]) > 80
        assert String.length(entry["consequence"]) > 40
      end
    end

    test "the malformed vector is honestly marked as needing a host-side gate", %{corpus: corpus} do
      v = Corpus.fetch_vector!(corpus, "malformed")

      assert v.expected_admission == :refused
      assert v.expected_refusal.code == :sa2a_malformed_graph
      assert v.expected_refusal.dialect == "HOST_PARSE_GATE"
      assert v.conformance == :host_gate_required
    end

    test "run_hooks was really measured on every vector, and the result is recorded as-is", %{
      corpus: corpus
    } do
      for v <- Corpus.vectors(corpus) do
        hooks = v.measured["run_hooks"]
        assert hooks["status"] == "ADMITTED"
        # Recorded exactly as measured, including the empty schedule that the
        # `hooks_never_register_through_wasm_run_hooks` deferral explains.
        assert hooks["schedule"] == []
      end
    end

    test "the manifest states the qualification's exact scope and its non-claims", %{
      corpus: corpus
    } do
      claim = corpus.manifest["qualification_claim"]

      assert corpus.manifest["qualification"] == "SA2A Portable Semantic Execution Conformance"
      assert claim =~ "over THIS finite suite"
      assert claim =~ "does not establish universal semantic equivalence"
      assert claim =~ "cross-IMPLEMENTATION"
    end

    test "replay verification on the pinned engine was byte-identical", %{corpus: corpus} do
      d = corpus.manifest["determinism"]

      assert d["graph_hash_run2"] == d["graph_hash_run3"]
      assert d["validate_all_replay"]["status"] == "ADMITTED"
      assert d["validate_all_replay"]["first_hash"] == d["validate_all_replay"]["second_hash"]
    end
  end

  # --- real helpers, no fakes -------------------------------------------

  defp temp_corpus do
    src = Corpus.load!().dir
    dest = Path.join(System.tmp_dir!(), "sa2a_corpus_#{uniq()}")
    File.mkdir_p!(dest)
    File.cp_r!(src, dest)
    on_exit(fn -> File.rm_rf(dest) end)
    dest
  end

  # Re-stamps one file's sha256 in a temp corpus's manifest, so a test that is
  # about a DIFFERENT failure mode (an unknown refusal code) is not short-
  # circuited by the digest gate firing first.
  defp remanifest(dir, rel) do
    path = Path.join(dir, "MANIFEST.json")
    {:ok, manifest} = JSON.decode(File.read!(path))
    bytes = File.read!(Path.join(dir, rel))

    updated =
      put_in(manifest, ["files", rel], %{
        "bytes" => byte_size(bytes),
        "sha256" => Base.encode16(:crypto.hash(:sha256, bytes), case: :lower),
        "blake3" => manifest["files"][rel]["blake3"]
      })

    File.write!(path, JSON.encode!(updated))
  end

  defp uniq, do: System.unique_integer([:positive, :monotonic])

  # Statement lines of a Turtle document: comments and blank lines dropped,
  # whitespace normalized. Comment headers legitimately differ between vectors.
  defp statements(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
  end
end
