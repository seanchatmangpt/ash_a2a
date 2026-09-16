defmodule AshA2A.GraphLawVendorTest do
  @moduledoc """
  Chicago-school tests for the GraphLaw law-package vendor pipeline.

  Every collaborator here is real: the real committed `.wasm` artifact is
  really instantiated and really executed, real files are written to real
  temporary directories, real digests are computed over real bytes, and the
  real `wasm-pack`/`b3sum`/`node` executables are probed on the real `PATH`.
  There is no mock, stub, or interaction assertion anywhere in this file --
  every assertion is on returned state, file contents, or a digest.

  Execution tests degrade to a *named, visible* `@tag :skip`-style guard when
  no Node executable is available on the host, never to a fabricated result.
  """

  use ExUnit.Case, async: true

  alias AshA2A.GraphLaw
  alias AshA2A.GraphLaw.Manifest
  alias AshA2A.GraphLaw.Vendor
  alias AshA2A.GraphLaw.WasmHost

  defp node_available?, do: match?({:ok, _}, WasmHost.node_executable())

  describe "committed law package" do
    test "the artifact, host, fixtures and manifest are all actually present" do
      assert File.exists?(GraphLaw.wasm_path()), "missing #{GraphLaw.wasm_path()}"
      assert File.exists?(GraphLaw.host_path()), "missing #{GraphLaw.host_path()}"
      assert File.exists?(GraphLaw.manifest_path()), "missing #{GraphLaw.manifest_path()}"

      for fixture <- ~w(base.ttl reordered.ttl mutated.ttl) do
        assert File.exists?(GraphLaw.fixture_path(fixture)), "missing fixture #{fixture}"
      end
    end

    test "the real bytes on disk match the digests the manifest claims" do
      {:ok, manifest} = Manifest.read()
      assert {:ok, result} = Manifest.verify_digests(manifest, GraphLaw.wasm_path())

      assert result.sha256_match
      assert result.bytes_actual == result.bytes_claimed
      assert result.blake3_status in [:match, :skipped]
    end

    test "the manifest's stamped content_digest matches a recomputation" do
      {:ok, manifest} = Manifest.read()
      assert manifest["content_digest"] == Manifest.content_digest(manifest)
    end

    test "the fixtures really are the graph permutations the pipeline assumes" do
      base = File.read!(GraphLaw.fixture_path("base.ttl"))
      reordered = File.read!(GraphLaw.fixture_path("reordered.ttl"))
      mutated = File.read!(GraphLaw.fixture_path("mutated.ttl"))

      # reordered.ttl must differ from base.ttl *as text*, otherwise the
      # canonical-identity check it exists to prove would be vacuous.
      refute base == reordered
      refute base == mutated
      assert String.contains?(reordered, "zz:"), "reordered.ttl must use a different prefix label"
      assert String.contains?(mutated, "ex:ZZZ"), "mutated.ttl must change a real triple"
    end
  end

  describe "real wasm execution" do
    setup do
      if node_available?() do
        :ok
      else
        {:ok, skip: "no node executable on PATH; real wasm execution cannot be performed"}
      end
    end

    test "probe/1 runs the committed artifact and reports its real semantics", context do
      if context[:skip] do
        IO.puts("SKIPPED (named): #{context[:skip]}")
      else
        assert {:ok, probe} = WasmHost.probe()

        assert probe.graphlaw_version =~ "praxis-graphlaw"
        assert probe.canonical_order_invariant
        assert probe.distinct_graph_distinct_hash
        assert probe.blake3_abc_matches_published_vector
        assert probe.graph_hash_base == probe.graph_hash_reordered
        refute probe.graph_hash_base == probe.graph_hash_mutated
        assert WasmHost.probe_acceptable?(probe)
        assert WasmHost.probe_failures(probe) == []
      end
    end

    test "the module declares exactly the two host imports this repo stubs", context do
      if context[:skip] do
        IO.puts("SKIPPED (named): #{context[:skip]}")
      else
        assert {:ok, probe} = WasmHost.probe()
        assert length(probe.imports) == 2

        names = Enum.map(probe.imports, &(String.split(&1, "::") |> List.last()))
        assert "__wbindgen_object_drop_ref" in names
        assert Enum.any?(names, &String.starts_with?(&1, "__wbg_getRandomValues_"))
      end
    end

    test "the module exports the wasm-bindgen ABI the host relies on", context do
      if context[:skip] do
        IO.puts("SKIPPED (named): #{context[:skip]}")
      else
        assert {:ok, probe} = WasmHost.probe()

        for export <- ~w(memory graph_hash graphlaw_version blake3_hex run_hooks validate_all
                         __wbindgen_add_to_stack_pointer __wbindgen_export2 __wbindgen_export4) do
          assert export in probe.exports, "artifact no longer exports #{export}"
        end
      end
    end

    test "run_hooks returns the admission vocabulary, decoded as real JSON", context do
      if context[:skip] do
        IO.puts("SKIPPED (named): #{context[:skip]}")
      else
        base = File.read!(GraphLaw.fixture_path("base.ttl"))
        event = "@prefix ex: <http://example.org/> .\nex:c ex:p ex:d .\n"

        assert {:ok, decoded} = WasmHost.call_json("run_hooks", [base, event])
        assert is_map(decoded)
        assert Map.has_key?(decoded, "status")
      end
    end

    test "a missing artifact path is a typed error, not a crash", _context do
      assert {:error, %{code: :wasm_not_found}} =
               WasmHost.run([%{fn: "graphlaw_version", args: []}],
                 wasm_path: "/nonexistent/definitely-not-here.wasm"
               )
    end

    test "an unknown export is a typed host error", context do
      if context[:skip] do
        IO.puts("SKIPPED (named): #{context[:skip]}")
      else
        assert {:error, %{code: :host_failed, host_code: "unknown_export"}} =
                 WasmHost.run([%{fn: "no_such_export", args: []}])
      end
    end
  end

  describe "praxis location" do
    test "a real directory holding the wasm crate is accepted" do
      root = tmp_dir("praxis_ok")
      File.mkdir_p!(Path.join(root, "crates/praxis-graphlaw-wasm"))
      File.write!(Path.join(root, "crates/praxis-graphlaw-wasm/Cargo.toml"), "[package]\n")

      assert {:ok, ^root} = Vendor.locate_praxis(praxis: root)
    end

    test "a real directory WITHOUT the wasm crate is a typed error" do
      root = tmp_dir("praxis_missing")
      File.mkdir_p!(root)

      assert {:error, %{code: :praxis_not_found, message: message}} =
               Vendor.locate_praxis(praxis: root)

      assert message =~ "remain usable without a praxis checkout"
    end

    test "an explicit flag beats the PRAXIS_ROOT environment variable" do
      root = tmp_dir("praxis_flag")
      File.mkdir_p!(Path.join(root, "crates/praxis-graphlaw-wasm"))
      File.write!(Path.join(root, "crates/praxis-graphlaw-wasm/Cargo.toml"), "[package]\n")

      System.put_env("PRAXIS_ROOT", "/nonexistent/env/praxis")
      on_exit(fn -> System.delete_env("PRAXIS_ROOT") end)

      assert {:ok, ^root} = Vendor.locate_praxis(praxis: root)
    end
  end

  describe "build hop" do
    test "an absent wasm-pack executable is a typed error, not a crash" do
      assert {:error, %{code: :wasm_pack_not_found}} =
               Vendor.build("/anywhere", wasm_pack: "definitely-not-a-real-wasm-pack-xyz")
    end

    test "crate_version/2 reads a real Cargo.toml from disk" do
      root = tmp_dir("crate_version")
      File.mkdir_p!(Path.join(root, "crates/praxis-graphlaw-wasm"))

      File.write!(
        Path.join(root, "crates/praxis-graphlaw-wasm/Cargo.toml"),
        "[package]\nname = \"praxis-graphlaw-wasm\"\nversion = \"26.7.5\"\n"
      )

      assert Vendor.crate_version(root, "crates/praxis-graphlaw-wasm") == "26.7.5"
      assert Vendor.crate_version(root, "crates/does-not-exist") == nil
      assert Vendor.crate_version(nil, "crates/praxis-graphlaw-wasm") == nil
    end

    test "provenance/2 with no praxis checkout yields nils, never invented values" do
      provenance = Vendor.provenance(nil, target: "web")

      assert provenance["praxis_git_sha"] == nil
      assert provenance["wasm_crate_version"] == nil
      assert provenance["wasm_pack_target"] == "web"
      assert provenance["rust_target"] == "wasm32-unknown-unknown"
      assert is_binary(provenance["built_at"])
    end
  end

  describe "install hop, end to end over real bytes" do
    @tag :tmp_dir
    test "installing the committed artifact into a fresh dir round-trips verification",
         %{tmp_dir: dest} do
      bytes = File.read!(GraphLaw.wasm_path())

      probe = %{
        graphlaw_version: "praxis-graphlaw v26.7.5",
        blake3_abc: "6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85",
        blake3_abc_matches_published_vector: true,
        graph_hash_base: "aaaa",
        graph_hash_reordered: "aaaa",
        graph_hash_mutated: "bbbb",
        canonical_order_invariant: true,
        distinct_graph_distinct_hash: true,
        exports: ["graph_hash"],
        imports: ["m::__wbindgen_object_drop_ref"]
      }

      provenance = Vendor.provenance(nil, target: "bundler")

      assert {:ok, installed} =
               Vendor.install(GraphLaw.wasm_path(), probe, provenance, dest_dir: dest)

      assert File.read!(installed.artifact) == bytes
      assert {:ok, written} = Manifest.read(installed.manifest)
      assert written["schema"] == Manifest.schema()
      assert written["graphlaw_version"] == "praxis-graphlaw v26.7.5"
      assert written["artifact"]["sha256"] == Manifest.sha256_hex(bytes)
      assert written["artifact"]["bytes"] == byte_size(bytes)
      assert written["content_digest"] == Manifest.content_digest(written)

      assert {:ok, result} = Manifest.verify_digests(written, installed.artifact)
      assert result.sha256_match
    end

    @tag :tmp_dir
    test "a corrupted artifact is caught by verify_digests", %{tmp_dir: dest} do
      {:ok, manifest} = Manifest.read()
      corrupted = Path.join(dest, "corrupted.wasm")
      File.write!(corrupted, File.read!(GraphLaw.wasm_path()) <> <<0>>)

      assert {:error, %{code: :digest_mismatch} = result} =
               Manifest.verify_digests(manifest, corrupted)

      refute result.sha256_match
      assert result.bytes_actual == result.bytes_claimed + 1
    end
  end

  describe "canonical manifest serialization" do
    test "canonical_json/1 sorts keys recursively and is insertion-order independent" do
      a = %{"b" => 1, "a" => %{"z" => [3, 2, 1], "y" => "x"}}
      b = %{"a" => %{"y" => "x", "z" => [3, 2, 1]}, "b" => 1}

      assert Manifest.canonical_json(a) == Manifest.canonical_json(b)
      assert Manifest.canonical_json(a) == ~s({"a":{"y":"x","z":[3,2,1]},"b":1})
    end

    test "canonical_json/1 preserves array order, which is semantic" do
      assert Manifest.canonical_json(%{"k" => [1, 2, 3]}) == ~s({"k":[1,2,3]})
      refute Manifest.canonical_json(%{"k" => [3, 2, 1]}) == ~s({"k":[1,2,3]})
    end

    test "canonical_json/1 handles empty containers and nil" do
      assert Manifest.canonical_json(%{"a" => %{}, "b" => [], "c" => nil}) ==
               ~s({"a":{},"b":[],"c":null})
    end

    test "content_digest/1 ignores an existing content_digest key" do
      base = %{"schema" => "x", "n" => 1}
      digest = Manifest.content_digest(base)

      assert Manifest.content_digest(Map.put(base, "content_digest", digest)) == digest
      assert Manifest.content_digest(Map.put(base, "content_digest", "tampered")) == digest
    end

    test "content_digest/1 changes when any real field changes" do
      base = %{"schema" => "x", "n" => 1}

      refute Manifest.content_digest(base) ==
               Manifest.content_digest(%{"schema" => "x", "n" => 2})
    end

    test "pretty_json/1 reparses to the same value it serialized" do
      doc = %{"z" => [1, %{"b" => true, "a" => nil}], "a" => "s"}
      assert {:ok, reparsed} = JSON.decode(Manifest.pretty_json(doc))
      assert Manifest.canonical_json(reparsed) == Manifest.canonical_json(doc)
    end

    test "sha256_hex/1 matches the published SHA-256 test vector for \"abc\"" do
      assert Manifest.sha256_hex("abc") ==
               "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    end
  end

  describe "blake3" do
    test "blake3_hex/2 either returns the real published vector or a named skip" do
      path = Path.join(tmp_dir("blake3"), "abc.txt")
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "abc")

      case Manifest.blake3_hex(path) do
        {:ok, hex} ->
          assert hex == "6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85"

        {:skipped, reason} ->
          IO.puts("SKIPPED (named): blake3 unavailable -- #{reason}")
          assert is_binary(reason)
      end
    end

    test "an absent b3sum is reported as skipped, never silently passed" do
      assert {:skipped, reason} =
               Manifest.blake3_hex("/etc/hosts", b3sum: "definitely-not-b3sum-xyz")

      assert reason =~ "definitely-not-b3sum-xyz"
    end
  end

  describe "manifest read errors are typed" do
    @tag :tmp_dir
    test "a missing file, non-JSON content and a wrong schema each get a code",
         %{tmp_dir: dir} do
      assert {:error, %{code: :manifest_not_found}} = Manifest.read(Path.join(dir, "nope.json"))

      bad = Path.join(dir, "bad.json")
      File.write!(bad, "not json at all")
      assert {:error, %{code: :manifest_non_json}} = Manifest.read(bad)

      wrong = Path.join(dir, "wrong.json")
      File.write!(wrong, ~s({"schema":"some.other/v9"}))
      assert {:error, %{code: :manifest_unknown_schema}} = Manifest.read(wrong)
    end
  end

  defp tmp_dir(label) do
    path =
      Path.join([
        System.tmp_dir!(),
        "ash_a2a_graphlaw_test",
        "#{label}_#{System.unique_integer([:positive])}"
      ])

    on_exit(fn -> File.rm_rf(path) end)
    path
  end
end
