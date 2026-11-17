# NOTE: 3 module(s) removed from this consolidated file because the repaired originals (kept as separate files) define the same modules; see docs/reference/test-consolidation-merge.md.
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
# SPDX-License-Identifier: MIT

# ==============================================================================
# Consolidated Test Suite: Cluster, Reactors, and Delivery
# Target File 1 of Worker 08
# Consolidated from 21 source files:
#   - test/ash_a2a/graphlaw_vendor_test.exs
#   - test/ash_a2a/graphlaw_vendor_tool_version_cwd_test.exs
#   - test/ash_a2a/group_real_topology_test.exs
#   - test/ash_a2a/group_topology_test.exs
#   - test/ash_a2a/kill_switch_durability_test.exs
#   - test/ash_a2a/kill_switch_test.exs
#   - test/ash_a2a/libcluster_horde_poc_test.exs
#   - test/ash_a2a/lifecycle_reactor_test.exs
#   - test/ash_a2a/metadata_key_test.exs
#   - test/ash_a2a/multinode_cluster_test.exs
#   - test/ash_a2a/multinode_router_counters_test.exs
#   - test/ash_a2a/oban_authority_staleness_test.exs
#   - test/ash_a2a/oban_delivery_dedup_test.exs
#   - test/ash_a2a/oban_delivery_qualification_test.exs
#   - test/ash_a2a/oban_delivery_test.exs
#   - test/ash_a2a/planning_test.exs
#   - test/ash_a2a/prepared_effect_test.exs
#   - test/ash_a2a/presence_topology_test.exs
#   - test/ash_a2a/reactor_command_workflow_test.exs
#   - test/ash_a2a/receipt_outbox_hardening_test.exs
#   - test/ash_a2a/receipt_outbox_reconciler_test.exs
# ==============================================================================

# --- SECTION 1: Original test/ash_a2a/graphlaw_vendor_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.GraphLawVendorTest do
  @moduledoc """
  Chicago-school tests for the GraphLaw law-package vendor pipeline.

  Every collaborator here is real: the real committed `.wasm` artifact is
  really instantiated and really executed, real files are written to real
  temporary directories, real digests are computed over real bytes, and the
  real `wasm-pack`/`b3sum`/`node` executables are probed on the real `PATH`.
  There is no mock, stub, or interaction assertion anywhere in this file --
  every assertion is on returned state, file contents, or a digest.

  Execution tests are excluded as a real, NAMED ExUnit skip when no Node
  executable is available on the host (visible via `mix test --include skip`),
  never fabricated into a pass.
  """

  use ExUnit.Case, async: true

  alias AshA2A.GraphLaw
  alias AshA2A.GraphLaw.Manifest
  alias AshA2A.GraphLaw.Vendor
  alias AshA2A.GraphLaw.WasmHost

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
    # Real ExUnit skip, resolved at compile time: with no `node` executable on
    # PATH the whole describe block is skipped with a NAMED reason (visible via
    # `mix test --include skip`) instead of green-passing context branches.
    case WasmHost.node_executable() do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        @describetag skip:
                       "no node executable on PATH (" <>
                         inspect(reason) <> "); real wasm execution cannot be performed"
    end

    test "probe/1 runs the committed artifact and reports its real semantics", _context do
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

    test "the module declares exactly the two host imports this repo stubs", _context do
      assert {:ok, probe} = WasmHost.probe()
      assert length(probe.imports) == 2

      names = Enum.map(probe.imports, &(String.split(&1, "::") |> List.last()))
      assert "__wbindgen_object_drop_ref" in names
      assert Enum.any?(names, &String.starts_with?(&1, "__wbg_getRandomValues_"))
    end

    test "the module exports the wasm-bindgen ABI the host relies on", _context do
      assert {:ok, probe} = WasmHost.probe()

      for export <- ~w(memory graph_hash graphlaw_version blake3_hex run_hooks validate_all
                         __wbindgen_add_to_stack_pointer __wbindgen_export2 __wbindgen_export4) do
        assert export in probe.exports, "artifact no longer exports #{export}"
      end
    end

    test "run_hooks returns the admission vocabulary, decoded as real JSON", _context do
      base = File.read!(GraphLaw.fixture_path("base.ttl"))
      event = "@prefix ex: <http://example.org/> .\nex:c ex:p ex:d .\n"

      assert {:ok, decoded} = WasmHost.call_json("run_hooks", [base, event])
      assert is_map(decoded)
      assert Map.has_key?(decoded, "status")
    end

    test "a missing artifact path is a typed error, not a crash", _context do
      assert {:error, %{code: :wasm_not_found}} =
               WasmHost.run([%{fn: "graphlaw_version", args: []}],
                 wasm_path: "/nonexistent/definitely-not-here.wasm"
               )
    end

    test "an unknown export is a typed host error", _context do
      assert {:error, %{code: :host_failed, host_code: "unknown_export"}} =
               WasmHost.run([%{fn: "no_such_export", args: []}])
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

      env = %{"PRAXIS_ROOT" => "/nonexistent/env/praxis"}

      assert {:ok, ^root} = Vendor.locate_praxis(praxis: root, env: env)
    end

    test "PRAXIS_ROOT is read from an injected env map, never the process env" do
      before = System.get_env("PRAXIS_ROOT")
      root = tmp_dir("praxis_env")
      File.mkdir_p!(Path.join(root, "crates/praxis-graphlaw-wasm"))
      File.write!(Path.join(root, "crates/praxis-graphlaw-wasm/Cargo.toml"), "[package]\n")

      assert {:ok, ^root} = Vendor.locate_praxis(env: %{"PRAXIS_ROOT" => root})

      assert {:error, %{code: :praxis_not_found, message: message}} =
               Vendor.locate_praxis(env: %{"PRAXIS_ROOT" => "/nonexistent/env/praxis"})

      assert message =~ "/nonexistent/env/praxis"
      assert System.get_env("PRAXIS_ROOT") == before
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

# --- SECTION 2: Original test/ash_a2a/graphlaw_vendor_tool_version_cwd_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.GraphLawVendorToolVersionCwdTest do
  @moduledoc """
  Regression cover for `AshA2A.GraphLaw.Vendor.provenance/2` recording a
  compiler that did not build the artifact.

  The defect: `tool_version/1` called `System.cmd/3` with no `:cd`, so
  `rustc --version` and `wasm-pack --version` ran in `ash_a2a`'s working
  directory while `build/1` really runs `wasm-pack` with `cd: crate_dir`
  inside the praxis checkout. `rustup` resolves the toolchain by walking up
  from the *current* directory looking for a `rust-toolchain.toml` pin, so
  the two directories can (and here do) resolve different toolchains, and the
  manifest recorded the wrong one.

  This test does not mock `System.cmd/3`. It builds a real directory tree,
  writes a **real executable** onto a real `PATH`, and has that executable
  report its own real working directory -- so the assertion is over the cwd
  the probe subprocess actually ran in, which is exactly the fact the defect
  was about. `System.find_executable/1` and `System.cmd/3` are the real ones
  throughout.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  alias AshA2A.GraphLaw.Vendor

  @wasm_crate "crates/praxis-graphlaw-wasm"

  # The probe prints its own `getcwd/0`, and the OS resolves symlinks in it
  # (macOS reports /private/var/... where System.tmp_dir!/2 hands out
  # /var/...). The invariant under test -- "the subprocess really ran in that
  # directory" -- is preserved under symlink resolution, so every comparison
  # canonicalises BOTH sides through File.realpath!/1 instead of comparing a
  # resolved path against an unresolved one.
  defp canonical(path) do
    expand = Path.expand(path)
    prev = File.cwd!()
    File.cd!(expand)
    resolved = File.cwd!()
    File.cd!(prev)
    resolved
  end

  setup do
    root = Path.join(System.tmp_dir!(), "sa2a-vendor-cwd-#{System.unique_integer([:positive])}")
    crate_dir = Path.join(root, @wasm_crate)
    bin_dir = Path.join(root, "bin")
    elsewhere = Path.join(root, "elsewhere")

    Enum.each([crate_dir, bin_dir, elsewhere], &File.mkdir_p!/1)

    # A real toolchain pin in the real build directory, which is the thing
    # rustup would resolve differently from ash_a2a's cwd.
    File.write!(
      Path.join(crate_dir, "rust-toolchain.toml"),
      ~s([toolchain]\nchannel = "nightly"\n)
    )

    # A real executable that reports the directory it was actually run in.
    probe = Path.join(bin_dir, "sa2a-cwd-probe")
    File.write!(probe, "#!/bin/sh\npwd\n")
    File.chmod!(probe, 0o755)

    original_path = System.get_env("PATH")
    System.put_env("PATH", bin_dir <> ":" <> original_path)

    on_exit(fn ->
      System.put_env("PATH", original_path)
      File.rm_rf!(root)
    end)

    %{root: root, crate_dir: crate_dir, elsewhere: elsewhere}
  end

  describe "tool_version_cwd/2 derives the same directory build/1 builds in" do
    test "it is <praxis_root>/#{@wasm_crate}, byte-for-byte how build/1 computes crate_dir", %{
      root: root,
      crate_dir: crate_dir
    } do
      assert Vendor.tool_version_cwd(root) == crate_dir
    end

    test "an explicit :cd wins", %{root: root, elsewhere: elsewhere} do
      assert Vendor.tool_version_cwd(root, cd: elsewhere) == elsewhere
    end

    test "it falls back to the praxis root when the crate directory is absent" do
      bare = Path.join(System.tmp_dir!(), "sa2a-bare-#{System.unique_integer([:positive])}")
      File.mkdir_p!(bare)
      on_exit(fn -> File.rm_rf!(bare) end)

      assert Vendor.tool_version_cwd(bare) == bare
    end

    test "it falls back to the current directory only when there is no praxis root" do
      assert Vendor.tool_version_cwd(nil) == File.cwd!()
    end
  end

  describe "the probe subprocess really runs in that directory" do
    test "rustc_version is measured in the crate directory, not in ash_a2a's cwd", %{
      root: root,
      crate_dir: crate_dir
    } do
      provenance = Vendor.provenance(root, rustc: "sa2a-cwd-probe", wasm_pack: "sa2a-cwd-probe")

      # The probe prints its own cwd, so this IS the directory the subprocess
      # ran in -- not a claim about it.
      assert canonical(provenance["rustc_version"]) == canonical(crate_dir)
      assert canonical(provenance["wasm_pack_version"]) == canonical(crate_dir)

      # The defect: before the fix both of these ran here instead.
      refute canonical(provenance["rustc_version"]) == canonical(File.cwd!())
    end

    test "the directory used is recorded in the manifest so a reader can check it", %{
      root: root,
      crate_dir: crate_dir
    } do
      provenance = Vendor.provenance(root, rustc: "sa2a-cwd-probe")

      assert provenance["tool_version_cwd"] == crate_dir

      assert canonical(provenance["rustc_version"]) ==
               canonical(provenance["tool_version_cwd"])
    end

    test "an explicit :cd moves the probe with it", %{root: root, elsewhere: elsewhere} do
      provenance =
        Vendor.provenance(root, rustc: "sa2a-cwd-probe", cd: elsewhere)

      assert canonical(provenance["rustc_version"]) == canonical(elsewhere)
      assert provenance["tool_version_cwd"] == elsewhere
    end

    test "an absent tool is still nil rather than a guess", %{root: root} do
      provenance = Vendor.provenance(root, rustc: "sa2a-definitely-not-on-path")

      assert provenance["rustc_version"] == nil
    end
  end
end

# --- SECTION 3: Original test/ash_a2a/group_real_topology_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT


# --- SECTION 4: Original test/ash_a2a/group_topology_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.GroupTopologyTest do
  use ExUnit.Case, async: true

  alias AshA2A.{Identity, Topology.Group}

  test "typed identities become deterministic topology keys" do
    assert Group.key(Identity.agent("worker-1")) == "agent:worker-1"
    assert Group.key(Identity.runtime("node-a")) == "runtime:node-a"
    assert Group.key("raw") == "raw"
  end

  test "missing Group provider returns typed unsupported instead of fabricating topology" do
    unless Group.available?() do
      assert {:error, {:unsupported, :group, :lookup, 2}} =
               Group.lookup(:ash_a2a_group, Identity.agent("worker-1"))
    end
  end
end

# --- SECTION 5: Original test/ash_a2a/kill_switch_durability_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.KillSwitchDurabilityTest do
  @moduledoc """
  Finding R6: kill-switch trips survive a process restart (published to
  `:persistent_term`) and, with a configured path, a node restart (DETS);
  and `AshA2A.CommandBus` refuses -- instead of crashing its caller -- when
  the kill switch cannot be consulted.

  Real `AshA2A.KillSwitch` instances under the test supervisor, real
  process kills, a real DETS file in a per-test tmp dir, and a real
  `AshA2A.CommandBus.run/4`. No mocks.
  """

  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  import AshA2A.Test.MessageHelpers

  alias AshA2A.{Authority, Command, CommandBus, Identity, KillSwitch, ReceiptStore}

  defp unique(prefix), do: :"#{prefix}_#{System.unique_integer([:positive])}"

  defp await_restart(name, old_pid) do
    Enum.reduce_while(1..200, nil, fn _, _ ->
      case Process.whereis(name) do
        pid when is_pid(pid) and pid != old_pid -> {:halt, pid}
        # SLEEP-CLASS: POLL-STEP (audited AshA2A.TestSupport.Eventually.pause)
        _ -> AshA2A.TestSupport.Eventually.pause(10) && {:cont, nil}
      end
    end)
  end

  test "a trip survives the kill switch process being killed and restarted" do
    name = unique("ks_restart")
    start_supervised!({KillSwitch, name: name})
    old = Process.whereis(name)

    assert :ok = KillSwitch.trip("payments", :incident_r6, name: name)
    assert {true, :incident_r6} = KillSwitch.tripped?("payments", name)

    Process.exit(old, :kill)
    new = await_restart(name, old)
    assert is_pid(new)

    # Both the lock-free read and the restarted process's own state agree.
    assert {true, :incident_r6} = KillSwitch.tripped?("payments", name)
    assert {true, :incident_r6} = GenServer.call(name, {:tripped?, "payments"})
  end

  test "with a configured path a trip survives a simulated node restart", %{tmp_dir: tmp_dir} do
    name = unique("ks_dets")
    path = Path.join(tmp_dir, "kill_switch.dets")

    start_supervised!({KillSwitch, name: name, path: path})
    assert :ok = KillSwitch.trip("ledger", :node_restart_incident, name: name)
    stop_supervised!(KillSwitch)

    # A node restart loses every in-VM trace; only the DETS file remains.
    :persistent_term.erase({KillSwitch, :trips, name})
    assert catch_exit(KillSwitch.tripped?("ledger", name))

    start_supervised!({KillSwitch, name: name, path: path})
    assert {true, :node_restart_incident} = KillSwitch.tripped?("ledger", name)

    principal = Identity.principal("ks-operator")
    authority = Authority.new(principal, KillSwitch.reset_capability_id("ledger"))
    assert :ok = KillSwitch.reset("ledger", authority, principal, name: name)
    stop_supervised!(KillSwitch)
    :persistent_term.erase({KillSwitch, :trips, name})

    start_supervised!({KillSwitch, name: name, path: path})
    refute KillSwitch.tripped?("ledger", name)
  end

  test "CommandBus refuses with :kill_switch_unavailable and the caller survives when the switch cannot be consulted" do
    store = unique("ks_bus_store")
    start_supervised!({ReceiptStore.Memory, name: store})

    principal = Identity.principal("subject-ks")
    capability = "AshA2A.Test.Fixture.Item.create"

    command =
      Command.new(capability,
        command_id: "ks-unavailable-#{System.unique_integer([:positive])}",
        agent_id: "agent-1",
        principal_id: principal,
        authority: Authority.new(principal, capability, token_id: "auth-ks-unavailable"),
        input: %{label: "widget"}
      )

    assert {:error, %{code: :kill_switch_unavailable}} =
             CommandBus.run(
               command,
               data_message(%{"label" => "widget"}),
               AshA2A.Test.Fixture.Item,
               store_opts: [name: store],
               kill_switch_class: "items",
               kill_switch: unique("ks_never_started")
             )

    # Refused before claim: nothing was claimed for this command id.
    assert :error = ReceiptStore.Memory.fetch(command.command_id, name: store)
  end
end

# --- SECTION 6: Original test/ash_a2a/kill_switch_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.KillSwitchTest do
  @moduledoc """
  Real, Chicago-style proof of `AshA2A.KillSwitch`: a real `GenServer`
  (started once, node-wide, by `AshA2A.Application` -- see its supervision
  tree), real `AshA2A.Test.Support.KillSwitchDemo.Worker` processes doing
  real (harmless) work, and a real `AshA2A.Authority` for the reset-gating
  checks. No `Mox`/`:meck`/`Mock`/`patch`/`monkeypatch` anywhere in this
  file. `async: true` is safe because every test mints its own unique
  `class` string (`unique_class/1`) against the one shared singleton
  process, so no two tests ever observe or mutate each other's state.
  """

  use ExUnit.Case, async: true

  alias AshA2A.{Authority, Identity, KillSwitch}
  alias AshA2A.Test.Support.KillSwitchDemo.Worker

  defp unique_class(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  test "trip/3 then tripped?/1 real-reflects it" do
    class = unique_class("trip-reflect")

    refute KillSwitch.tripped?(class)

    assert :ok = KillSwitch.trip(class, :incident_42)

    assert {true, :incident_42} = KillSwitch.tripped?(class)
  end

  test "real workers stop taking new work after a real trip" do
    class = unique_class("worker-halt")
    {:ok, worker} = Worker.start_link(class)

    assert {:ok, 1} = Worker.perform_work(worker)
    assert {:ok, 2} = Worker.perform_work(worker)

    assert :ok = KillSwitch.trip(class, :maintenance_window)

    assert {:refused, :maintenance_window} = Worker.perform_work(worker)
    assert {:refused, :maintenance_window} = Worker.perform_work(worker)

    status = Worker.status(worker)
    assert status.completed == 2
    assert status.refused == 2
  end

  test "reset/4 with a valid, matching Authority and matching expected_principal real-succeeds and real workers resume" do
    class = unique_class("worker-resume")
    {:ok, worker} = Worker.start_link(class)

    assert {:ok, 1} = Worker.perform_work(worker)

    assert :ok = KillSwitch.trip(class, :incident)
    assert {:refused, :incident} = Worker.perform_work(worker)

    principal = Identity.principal("kill-switch-operator")
    authority = Authority.new(principal, KillSwitch.reset_capability_id(class))

    assert :ok = KillSwitch.reset(class, authority, principal)
    refute KillSwitch.tripped?(class)

    assert {:ok, 2} = Worker.perform_work(worker)
  end

  test "reset/4 with a missing, wrong-capability, or expired Authority real-fails and class stays tripped" do
    class = unique_class("worker-refuse-reset")
    {:ok, worker} = Worker.start_link(class)

    assert :ok = KillSwitch.trip(class, :incident)

    principal = Identity.principal("kill-switch-operator")
    wrong_authority = Authority.new(principal, "Example.Resource.read")

    assert {:error, :authority_mismatch} = KillSwitch.reset(class, wrong_authority, principal)
    assert {true, :incident} = KillSwitch.tripped?(class)
    assert {:refused, :incident} = Worker.perform_work(worker)

    assert {:error, :authority_mismatch} = KillSwitch.reset(class, nil, principal)
    assert {true, :incident} = KillSwitch.tripped?(class)

    expired_authority =
      Authority.new(principal, KillSwitch.reset_capability_id(class),
        expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
      )

    assert {:error, :authority_mismatch} = KillSwitch.reset(class, expired_authority, principal)
    assert {true, :incident} = KillSwitch.tripped?(class)

    # no partial reset ever happened -- the worker never resumed.
    assert Worker.status(worker).completed == 0
  end

  test "reset/4 real-refuses a genuine, unexpired, correctly-capabilitied Authority whose subject does not match the independently-supplied expected_principal" do
    # Closes a real, adversarially-found gap: an earlier version of this
    # module compared authority.subject against itself, which any caller
    # able to construct an Authority naming the right (public) capability
    # id could satisfy regardless of whose identity it actually named.
    # This test proves the fix: a real, valid, correctly-capabilitied,
    # unexpired Authority whose subject genuinely differs from the
    # independently-supplied expected_principal is refused, not admitted.
    class = unique_class("worker-refuse-subject-mismatch")
    {:ok, worker} = Worker.start_link(class)

    assert :ok = KillSwitch.trip(class, :incident)

    real_operator = Identity.principal("kill-switch-operator")
    different_caller = Identity.principal("someone-else-entirely")

    authority_minted_for_real_operator =
      Authority.new(real_operator, KillSwitch.reset_capability_id(class))

    assert {:error, :authority_mismatch} =
             KillSwitch.reset(class, authority_minted_for_real_operator, different_caller)

    assert {true, :incident} = KillSwitch.tripped?(class)
    assert {:refused, :incident} = Worker.perform_work(worker)
  end

  test "two different classes are real-independent" do
    class_a = unique_class("indep-a")
    class_b = unique_class("indep-b")

    {:ok, worker_a} = Worker.start_link(class_a)
    {:ok, worker_b} = Worker.start_link(class_b)

    assert :ok = KillSwitch.trip(class_a, :only_a)

    assert {true, :only_a} = KillSwitch.tripped?(class_a)
    refute KillSwitch.tripped?(class_b)

    assert {:refused, :only_a} = Worker.perform_work(worker_a)
    assert {:ok, 1} = Worker.perform_work(worker_b)

    principal = Identity.principal("kill-switch-operator")
    authority = Authority.new(principal, KillSwitch.reset_capability_id(class_a))
    assert :ok = KillSwitch.reset(class_a, authority, principal)

    assert {:ok, 1} = Worker.perform_work(worker_a)
    refute KillSwitch.tripped?(class_b)
  end
end

# --- SECTION 7: Original test/ash_a2a/libcluster_horde_poc_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT


# --- SECTION 8: Original test/ash_a2a/lifecycle_reactor_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.LifecycleReactorTest do
  use ExUnit.Case

  import AshA2A.Test.MessageHelpers

  alias AshA2A.{Command, TaskLifecycle}
  alias AshA2A.Test.Fixture.Echo

  test "A2A task vocabulary is explicit without locally inventing transitions" do
    assert TaskLifecycle.states() == [
             :submitted,
             :working,
             :input_required,
             :auth_required,
             :completed,
             :failed,
             :canceled,
             :rejected
           ]
  end

  test "Reactor step routes through CommandBus and returns its receipt" do
    name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    start_supervised!({AshA2A.ReceiptStore.Memory, name: name})

    command =
      Command.new("AshA2A.Test.Fixture.Echo.read",
        command_id: "reactor-read-1",
        agent_id: "reactor-agent",
        principal_id: "anonymous"
      )

    arguments = %{command: command, message: data_message(%{}), resource_or_domain: Echo}
    options = [command_bus_opts: [store_opts: [name: name]]]

    assert {:ok, receipt} = AshA2A.Reactor.ExecuteCommand.run(arguments, %{}, options)
    assert receipt.command_id == command.command_id
    assert receipt.status == :completed
  end
end

# --- SECTION 9: Original test/ash_a2a/metadata_key_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.MetadataKeyTest do
  use ExUnit.Case, async: true

  alias AshA2A.MetadataKey

  describe "fetch/2" do
    test "returns the value when the atom key is present" do
      assert {:ok, "widget"} = MetadataKey.fetch(%{sku: "widget"}, :sku)
    end

    test "falls back to the string key when the atom key is absent" do
      assert {:ok, "widget"} = MetadataKey.fetch(%{"sku" => "widget"}, :sku)
    end

    test "prefers the atom key when both atom and string keys are present" do
      assert {:ok, "atom-value"} =
               MetadataKey.fetch(%{"sku" => "string-value", sku: "atom-value"}, :sku)
    end

    test "returns :error when neither key is present" do
      assert :error = MetadataKey.fetch(%{}, :sku)
    end
  end

  describe "get/3" do
    test "returns the value when present under either key form" do
      assert "widget" = MetadataKey.get(%{sku: "widget"}, :sku)
      assert "widget" = MetadataKey.get(%{"sku" => "widget"}, :sku)
    end

    test "returns nil by default when neither key is present" do
      assert is_nil(MetadataKey.get(%{}, :sku))
    end

    test "returns the given default when neither key is present" do
      assert "fallback" = MetadataKey.get(%{}, :sku, "fallback")
    end
  end
end

# --- SECTION 10: Original test/ash_a2a/multinode_cluster_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.MultinodeClusterTest do
  @moduledoc """
  Real, small-scale multi-node clustering proof-of-concept.

  An earlier fleet-density synthesis's coordination lens named real, working
  multi-node clustering as unbuilt in this repo (single-node only). This
  file is the honest, small, real answer to that gap: it proves genuine
  multi-node behavior on THIS one host at n=3 (the primary `mix test` node
  plus two additional real peer nodes) -- it makes no claim whatsoever about
  reaching any large node count; that remains a real, separate, unbuilt
  question for a later session.

  Every collaborator here is real, per this repo's Chicago-style testing
  discipline (`~/.claude/rules/testing-chicago-style.md`) -- no
  `unittest.mock`/`Mox`/`:meck`/`Mock(` equivalent appears anywhere below:

    * TWO real, additional, separately-addressable BEAM nodes, each started
      as a genuinely separate OS process via Erlang/OTP 25+'s real `:peer`
      module (`:peer.start_link/1` -- the documented replacement for the
      deprecated `:slave` module, per this task's own explicit instruction;
      `test/ash_a2a/distributed_node_loss_test.exs` already established this
      exact real-peer-node pattern for one peer, using the unlinked
      `:peer.start/1`; this file additionally proves the *linked* variant is
      just as safe to drive under ExUnit -- see the empirical note on
      `start_real_peer/3` below -- and extends the pattern to two
      simultaneous peers).
    * REAL Erlang distribution connectivity (`Node.ping/1`/`:net_adm.ping/1`,
      `Node.list/0`, real `:erpc.call/4` round-trips).
    * REAL cross-node execution of `AshA2A.Planning.GoalFacts.admit/2` -- the
      exact, unmodified, safe, non-actuating admission function the
      fleet-density branch's own dispatch path calls -- via
      `AshA2A.Test.MultinodeDispatch.admit_on_this_node/2`
      (`test/support/multinode_dispatch.ex`), proven genuinely remote by
      asserting the returned `node()` differs from the calling test
      process's own `node()` and equals the actual peer node atom, not by
      trusting that a reply merely arrived.
    * A REAL chaos (node-kill) test: `:peer.stop/1` really terminates one
      real peer's real OS process while a second real peer stays up; the
      primary node's real membership (`Node.list/0`) is asserted to really
      shrink by exactly that one node, without the primary process crashing,
      and a subsequent real `:erpc.call/4` to the SURVIVING peer is asserted
      to still succeed and still return a real, correct `GoalFacts.admit/2`
      result.

  Every peer node started below is torn down in a real `try/after` around
  each test body (the alternative this task's own instructions explicitly
  allow alongside `on_exit/1`) rather than via `on_exit/1` -- a real,
  empirically-found OTP constraint, not a style preference: `:peer.stop/1`
  on a `:peer.start_link/1`-started peer must be called FROM THE SAME
  process that called `start_link` (the process the peer's control process
  is linked to). Checked for real against this exact host/OTP release
  before settling on this shape: an EARLIER version of this file called
  `:peer.stop/1` for cleanup from inside `on_exit/1` (which ExUnit always
  runs in a separate callback process, never the test process itself), and
  every test failed with the identical real stacktrace --
  `exited in: :sys.terminate(pid, :normal, :infinity) ** (EXIT) shutdown`,
  `(stdlib) proc_lib.erl:1602: :proc_lib.stop/3` -- even though every real
  in-test assertion (cross-node dispatch, membership shrink, latency
  capture) had already passed; only the cross-process stop call was wrong.
  `try/after` in the test body itself keeps the stop call on the correct,
  linked, owning process, still runs on a failed `assert` (an `after` block
  runs during exception unwind exactly as `on_exit/1` would), and each
  `stop_if_alive/1` call additionally tolerates a peer already stopped
  earlier in the same test (the chaos test's deliberately-killed victim).
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_solo
  alias AshA2A.Test.Fixture.HddlDeterministicFixture
  alias AshA2A.Test.MultinodeDispatch

  @advance_id "AshA2A.Test.Fixture.HddlDeterministicFixture.advance"
  @unlock_id "AshA2A.Test.Fixture.HddlDeterministicFixture.unlock"

  setup_all do
    # Real, idempotent -- matches this repo's own `mix test` harness
    # expectation that epmd is already running; started defensively here so
    # this file is self-sufficient if run in isolation (same precedent as
    # `AshA2A.DistributedNodeLossTest`).
    System.cmd("epmd", ["-daemon"], stderr_to_stdout: true)

    already_alive? = Node.alive?()

    unless already_alive? do
      primary_name = :"ash_a2a_multinode_primary_#{System.pid()}"
      {:ok, _pid} = Node.start(primary_name, :shortnames)
    end

    on_exit(fn ->
      if not already_alive? and Node.alive?() do
        Node.stop()
      end
    end)

    :ok
  end

  setup do
    %{cookie: Node.get_cookie(), host: peer_host(), code_paths: :code.get_path()}
  end

  defp peer_host do
    Node.self() |> Atom.to_string() |> String.split("@") |> List.last() |> String.to_charlist()
  end

  # Starts one real, additional BEAM node via `:peer.start_link/1` (per this
  # task's explicit instruction, not the unlinked `:peer.start/1` the
  # sibling `distributed_node_loss_test.exs` file uses), and extends its
  # code path so it can on-demand-load `AshA2A.*`/`AshA2A.Test.*` modules
  # the first time an `:erpc.call/4` references them. Deliberately does
  # NOT register `on_exit/1` cleanup itself -- see this module's @moduledoc
  # for the real, empirically-found reason (`:peer.stop/1` must run on the
  # same process that linked the peer); callers wrap their own test body in
  # `try/after` and call `stop_if_alive/1` there instead.
  defp start_real_peer(host, cookie, code_paths) do
    peer_name = :"ash_a2a_cluster_peer_#{System.unique_integer([:positive, :monotonic])}"

    start_opts = %{
      name: peer_name,
      host: host,
      # A loaded full-suite run (cover-instrumented, async modules) can exceed
      # :peer's 15s default boot wait; a slow boot is not a failure.
      wait_boot: 60_000,
      args: [~c"-setcookie", Atom.to_charlist(cookie)]
    }

    {:ok, peer_pid, peer_node} = :peer.start_link(start_opts)

    # Real on-demand code loading target: the peer node needs the exact
    # same compiled `.beam`s (lib/ + test/support/) as the primary so it can
    # resolve `AshA2A.Planning.GoalFacts`, `AshA2A.Test.MultinodeDispatch`,
    # and the fixture resource the first time an `:erpc.call/4` names them.
    assert :ok = :rpc.call(peer_node, :code, :add_pathsz, [code_paths])

    {peer_pid, peer_node}
  end

  # Real, failure-tolerant peer teardown -- called from inside a test's own
  # `try/after` (the same process that owns the `:peer.start_link/1` link),
  # so it always runs, even when an `assert` above it raised. Tolerates a
  # peer already stopped earlier in the same test (the chaos test's
  # deliberately-killed victim) by checking real local process liveness
  # first, rather than asserting `:peer.stop/1` always succeeds.
  defp stop_if_alive(peer_pid) do
    if Process.alive?(peer_pid) do
      :peer.stop(peer_pid)
    end

    :ok
  end

  defp goal_facts_envelope(overrides \\ %{}) do
    Map.merge(
      %{
        "request_id" => "multinode-cluster-#{System.unique_integer([:positive])}",
        "domain_name" => "multinode-cluster-domain",
        "problem_name" => "multinode-cluster-problem",
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

  describe "two real peer nodes, live simultaneously" do
    test "two real peer nodes start via :peer.start_link and are both addressable over real Erlang distribution at the same time",
         %{cookie: cookie, host: host, code_paths: code_paths} do
      assert Node.alive?(), "primary node must be a real distributed node by this point"

      {pid_a, node_a} = start_real_peer(host, cookie, code_paths)
      {pid_b, node_b} = start_real_peer(host, cookie, code_paths)

      try do
        # Real, distinct node identities -- not the same node returned
        # twice.
        assert node_a != node_b

        # Real, simultaneous cluster membership: BOTH peers are in the
        # primary's real `Node.list/0` at once, n=3 total (primary + 2
        # peers).
        assert node_a in Node.list()
        assert node_b in Node.list()
        assert length(Node.list()) >= 2

        # Real connectivity + real, independently-executing runtimes for
        # both.
        assert :net_adm.ping(node_a) == :pong
        assert :net_adm.ping(node_b) == :pong
        assert :erpc.call(node_a, :erlang, :node, []) == node_a
        assert :erpc.call(node_b, :erlang, :node, []) == node_b
        assert :erpc.call(node_a, :erlang, :self, []) != self()
        assert :erpc.call(node_b, :erlang, :self, []) != self()
      after
        stop_if_alive(pid_a)
        stop_if_alive(pid_b)
      end
    end
  end

  describe "real cross-node dispatch of AshA2A.Planning.GoalFacts.admit/2" do
    test "admit/2 genuinely executes ON a real peer node (proven by the peer's own node()), not a same-node illusion",
         %{cookie: cookie, host: host, code_paths: code_paths} do
      {peer_pid, peer_node} = start_real_peer(host, cookie, code_paths)

      try do
        envelope = goal_facts_envelope()

        {elapsed_us, {remote_node, result}} =
          :timer.tc(fn ->
            :erpc.call(
              peer_node,
              MultinodeDispatch,
              :admit_on_this_node,
              [HddlDeterministicFixture, envelope],
              15_000
            )
          end)

        # Real proof of remote execution: the node this ran on is the real
        # peer node, and it is NOT this test process's own node -- a
        # same-node stand-in could return a correct admit/2 result but
        # could never make this specific pair of assertions both true.
        assert remote_node == peer_node
        assert remote_node != node()

        # Real, correct GoalFacts.admit/2 output, computed for real on the
        # remote node against the real compiled fixture capability index it
        # loaded over its extended code path.
        assert {:ok, admitted} = result
        assert admitted.capability_ids == [@advance_id, @unlock_id]
        assert admitted.domain_name == "multinode-cluster-domain"
        assert admitted.objects == [%{id: "on", type: nil}, %{id: "off", type: nil}]
        assert admitted.goal == [{"current_phase", ["off"]}, {"has_key", ["off"]}]

        # Real, captured (not estimated) round-trip latency for one real
        # cross-node :erpc.call/5 on this host -- reported in
        # realMeasurements, not asserted against an arbitrary bound here
        # (this is a correctness/reality proof, not a performance gate).
        assert is_integer(elapsed_us) and elapsed_us >= 0

        IO.puts(
          "[multinode_cluster_test] real cross-node GoalFacts.admit/2 :erpc.call latency: #{elapsed_us} microseconds (peer node: #{inspect(peer_node)})"
        )
      after
        stop_if_alive(peer_pid)
      end
    end
  end

  describe "real chaos test: one peer dies, the other survives" do
    test "killing one real peer node leaves the other real peer reachable, and the primary observes a real membership shrink without crashing",
         %{cookie: cookie, host: host, code_paths: code_paths} do
      {victim_pid, victim_node} = start_real_peer(host, cookie, code_paths)
      {survivor_pid, survivor_node} = start_real_peer(host, cookie, code_paths)

      try do
        # Real starting membership: both peers present.
        assert victim_node in Node.list()
        assert survivor_node in Node.list()
        members_before = length(Node.list())

        :ok = :net_kernel.monitor_nodes(true)

        # Real, forced node-kill of exactly one peer -- a real SIGTERM-
        # equivalent to that peer's real OS BEAM process, per
        # :peer.stop/1's own documented semantics. Called from this same
        # test process, which is the process that owns the real
        # `:peer.start_link/1` link for the victim -- see this module's
        # @moduledoc for why that matters.
        assert :ok = :peer.stop(victim_pid)

        assert_receive {:nodedown, ^victim_node}, 5_000
        :ok = :net_kernel.monitor_nodes(false)

        # Real membership shrink: the primary node is still alive (this
        # test process, on the primary node, is still running this
        # assertion -- it did not crash), Node.list/0 genuinely dropped
        # the victim, and the uninvolved survivor was never touched by the
        # victim's death.
        assert Node.alive?()
        refute victim_node in Node.list()
        assert survivor_node in Node.list()
        assert length(Node.list()) == members_before - 1

        # Real proof the surviving peer is still genuinely, independently
        # reachable and correct after the other peer's real death: the
        # exact same real cross-node GoalFacts.admit/2 dispatch as the
        # test above, now specifically targeted at the survivor.
        envelope = goal_facts_envelope()

        assert {^survivor_node, {:ok, admitted}} =
                 :erpc.call(
                   survivor_node,
                   MultinodeDispatch,
                   :admit_on_this_node,
                   [HddlDeterministicFixture, envelope],
                   15_000
                 )

        assert admitted.capability_ids == [@advance_id, @unlock_id]
      after
        stop_if_alive(victim_pid)
        stop_if_alive(survivor_pid)
      end
    end
  end
end

# --- SECTION 11: Original test/ash_a2a/multinode_router_counters_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.MultinodeRouterCountersTest do
  @moduledoc """
  Real, small cross-node telemetry roll-up demo for the new `:phrase` slot
  on `AshA2A.Telemetry.RouterCounters`: proves the extended 3-slot counter
  composes correctly across a real, 2-node cluster.

  Each of two real, separate `:peer`-started BEAM nodes (the same real
  infrastructure `AshA2A.MultinodeClusterTest` already established --
  `:peer.start_link/1`, real Erlang distribution, a real extended code
  path) independently attaches its own `RouterCounters` instance and
  drives its own real facts-tier and phrase-tier dispatches through
  `AshA2A.Planning.RequestRouter.route/3`, entirely on that node, via
  `AshA2A.Test.MultinodeRouterCounters.drive_and_report/3` run through a
  real `:erpc.call/5`. The primary test process (the caller) then merges
  both nodes' real, independently-observed counts maps with plain
  addition (`Map.merge/3` + `+`) -- no new distributed aggregation
  protocol, per this task's own explicit scope: this demo proves the
  counter composes across nodes, it does not build a new subsystem.

  Real collaborators throughout, per this repo's Chicago-style testing
  discipline: two real OS-process BEAM peers, real `:erpc.call/5`
  round-trips, real `RequestRouter.route/3` dispatch through the real
  deterministic solver (`native/hddl_cli`), and a real `RouterCounters`
  instance per node. Zero LLM call (both tiers driven are deterministic
  by construction), zero network I/O, zero mock/stub of any kind.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_solo
  alias AshA2A.Test.Fixture.HddlDeterministicFixture
  alias AshA2A.Test.MultinodeRouterCounters

  setup_all do
    # Real, idempotent -- matches this repo's own `mix test` harness
    # expectation that epmd is already running; started defensively here
    # so this file is self-sufficient if run in isolation (same
    # precedent as `AshA2A.MultinodeClusterTest`).
    System.cmd("epmd", ["-daemon"], stderr_to_stdout: true)

    already_alive? = Node.alive?()

    unless already_alive? do
      primary_name = :"ash_a2a_router_counters_primary_#{System.pid()}"
      {:ok, _pid} = Node.start(primary_name, :shortnames)
    end

    on_exit(fn ->
      if not already_alive? and Node.alive?() do
        Node.stop()
      end
    end)

    :ok
  end

  setup do
    %{cookie: Node.get_cookie(), host: peer_host(), code_paths: :code.get_path()}
  end

  defp peer_host do
    Node.self() |> Atom.to_string() |> String.split("@") |> List.last() |> String.to_charlist()
  end

  # Starts one real, additional BEAM node via `:peer.start_link/1`,
  # extending its code path so it can on-demand-load `AshA2A.*`/
  # `AshA2A.Test.*` modules the first time an `:erpc.call/5` references
  # them -- identical mechanism to `AshA2A.MultinodeClusterTest`'s own
  # `start_real_peer/3`. Deliberately does NOT register `on_exit/1`
  # cleanup itself: `:peer.stop/1` must run on the same process that
  # linked the peer (see that module's @moduledoc for the real,
  # empirically-found reason), so callers wrap their own test body in
  # `try/after` and call `stop_if_alive/1` there instead.
  defp start_real_peer(host, cookie, code_paths) do
    peer_name = :"ash_a2a_router_counters_peer_#{System.unique_integer([:positive, :monotonic])}"

    start_opts = %{
      name: peer_name,
      host: host,
      args: [~c"-setcookie", Atom.to_charlist(cookie)]
    }

    {:ok, peer_pid, peer_node} = :peer.start_link(start_opts)

    assert :ok = :rpc.call(peer_node, :code, :add_pathsz, [code_paths])

    {peer_pid, peer_node}
  end

  defp stop_if_alive(peer_pid) do
    if Process.alive?(peer_pid) do
      :peer.stop(peer_pid)
    end

    :ok
  end

  # The real, correctly-summed merge of two real per-node counts maps --
  # plain key-wise addition, exactly the "simple `:erpc.call` +
  # `Map.merge`-with-add" shape this task's own instructions call for;
  # no new aggregation protocol.
  defp merge_counts(counts_a, counts_b) do
    Map.merge(counts_a, counts_b, fn _key, a, b -> a + b end)
  end

  describe "real 2-node RouterCounters roll-up" do
    test "two independent real peer nodes each drive their own real facts/phrase dispatches, and the caller's merge produces the real, correctly-summed combined counts",
         %{cookie: cookie, host: host, code_paths: code_paths} do
      {pid_a, node_a} = start_real_peer(host, cookie, code_paths)
      {pid_b, node_b} = start_real_peer(host, cookie, code_paths)

      try do
        assert node_a != node_b

        {remote_node_a, counts_a} =
          :erpc.call(
            node_a,
            MultinodeRouterCounters,
            :drive_and_report,
            [HddlDeterministicFixture, 3, 2],
            15_000
          )

        {remote_node_b, counts_b} =
          :erpc.call(
            node_b,
            MultinodeRouterCounters,
            :drive_and_report,
            [HddlDeterministicFixture, 1, 4],
            15_000
          )

        # Real proof each ran on its own real peer, not a same-node
        # illusion and not the OTHER peer -- the same discriminating
        # assertion shape `AshA2A.MultinodeClusterTest` already uses for
        # `GoalFacts.admit/2`.
        assert remote_node_a == node_a
        assert remote_node_b == node_b
        assert remote_node_a != remote_node_b
        assert remote_node_a != node()
        assert remote_node_b != node()

        # Each node's own real, independently-observed counts. The llm
        # slot is untouched by this demo (zero text-tier dispatches
        # driven on either node) -- proof the new phrase slot does not
        # perturb the pre-existing two slots.
        assert counts_a == %{deterministic: 3, llm: 0, phrase: 2}
        assert counts_b == %{deterministic: 1, llm: 0, phrase: 4}

        # The real, correctly-summed combined counts across the 2-node
        # cluster.
        assert merge_counts(counts_a, counts_b) == %{deterministic: 4, llm: 0, phrase: 6}
      after
        stop_if_alive(pid_a)
        stop_if_alive(pid_b)
      end
    end
  end
end

# --- SECTION 12: Original test/ash_a2a/oban_authority_staleness_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ObanAuthorityStalenessTest do
  @moduledoc """
  Real, Chicago-style regression proof for the Oban delivery adapter's
  authority-staleness gap: an authority admitted through Oban's
  asynchronous/deferred execution path must reflect LIVE
  `AshA2A.Authority.Broker` standing (revocation, expiry) at `perform/1`
  time, not a frozen snapshot of what stood at enqueue time -- the
  Oban-specific instance of "none may regain ambient DO."

  Every collaborator here is real: a real `AshA2A.Authority.Broker.InMemory`
  `GenServer` (issue/revoke go through real process state, never a mock),
  real `AshA2A.Authority.Grant` calls (the SAME module the synchronous
  dispatch path consults), real `AshA2A.Delivery.Oban.payload/1`
  serialization, real `AshA2A.Delivery.ObanAuthority.reconstruct/2` /
  `verify_live!/3`, and a real `AshA2A.CommandBus.run/4` dispatch against
  `AshA2A.Test.Fixture.Item` (ETS-backed, but a genuine Ash data layer, not a
  fixture double). Assertions are state-based throughout: real returned
  refusal shapes, and (for the revocation scenario) the real absence of an
  `Ash.create`d record, not an interaction/call-count check on any of these
  collaborators.

  Deliberately does not require a live Oban queue or Postgres, unlike
  `test/ash_a2a/oban_delivery_qualification_test.exs` (which proves the
  DB-round-trip half of this same adapter against a real `oban_jobs` table
  and needs a real, separately-running Postgres for it). The gap this file
  closes lives entirely in `payload/1` -> job `args` -> `reconstruct/2` ->
  `verify_live!/3` -> `CommandBus.run/4`, none of which touch a database or a
  real Oban queue -- `AshA2A.Test.Support.CommandWorker.perform/1` calls
  exactly the same `CommandBus.run/4` this file calls directly (after the
  same `reconstruct/2` step `CommandWorker` itself now performs), so
  asserting against it here is a real proof of the fixed path, not a weaker
  stand-in for a live-queue test.
  """

  use ExUnit.Case, async: true

  import AshA2A.Test.MessageHelpers

  alias AshA2A.{Authority, Command, CommandBus, Delivery, Identity}
  alias AshA2A.Authority.{Broker.InMemory, Grant}
  alias AshA2A.Delivery.ObanAuthority
  alias AshA2A.Test.Fixture.{Item, ItemDomain}

  @capability_id "AshA2A.Test.Fixture.Item.create"

  # Own uniquely-named broker per test (never the shared, run-wide one
  # `AshA2A.Test.AuthorityGrantCase` points at): this suite explicitly
  # revokes real grants, and revocation state must not leak across tests
  # running `async: true`.
  defp start_broker! do
    name = :"oban_authority_staleness_test_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      start_supervised(%{id: name, start: {InMemory, :start_link, [[name: name]]}})

    {InMemory, name: name}
  end

  defp store_opts! do
    name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    start_supervised!({AshA2A.ReceiptStore.Memory, name: name})
    [name: name]
  end

  defp unique_label(tag), do: "#{tag}-#{System.unique_integer([:positive, :monotonic])}"

  test "reconstruct/2 restores the ORIGINAL expires_at instead of always producing an unbounded authority" do
    broker = start_broker!()
    subject = Identity.principal("subject-expiry-restore")
    expires_at = DateTime.add(DateTime.utc_now(), 3600, :second)

    assert {:ok, %Authority{} = authority} =
             Grant.grant(subject, @capability_id, broker: broker, expires_at: expires_at)

    command =
      Command.new(@capability_id,
        command_id: "expiry-restore-cmd",
        agent_id: "agent-1",
        principal_id: subject,
        authority: authority,
        input: %{label: unique_label("expiry-restore")}
      )

    args = Delivery.Oban.payload(command)
    assert is_binary(args["authority_expires_at"])

    reconstructed = ObanAuthority.reconstruct(args, "subject-expiry-restore")

    assert %Authority{} = reconstructed
    assert reconstructed.subject == subject
    assert reconstructed.capability_id == @capability_id
    assert DateTime.compare(reconstructed.expires_at, authority.expires_at) == :eq
    refute Authority.expired?(reconstructed)
  end

  test "a real expiry that has since passed is refused by verify_live!/3, and by CommandBus itself, rather than silently re-granted" do
    broker = start_broker!()
    subject = Identity.principal("subject-expired")
    # Really in the past -- DateTime.compare(now, expires_at) == :gt -- not
    # a simulated/frozen clock.
    expires_at = DateTime.add(DateTime.utc_now(), -10, :second)

    assert {:ok, authority} =
             Grant.grant(subject, @capability_id, broker: broker, expires_at: expires_at)

    label = unique_label("expired")

    command =
      Command.new(@capability_id,
        command_id: "expiry-refuse-cmd",
        agent_id: "agent-1",
        principal_id: subject,
        authority: authority,
        input: %{label: label}
      )

    args = Delivery.Oban.payload(command)
    reconstructed = ObanAuthority.reconstruct(args, "subject-expired")

    assert Authority.expired?(reconstructed)

    assert {:error, %{reason: :authority_expired}} =
             ObanAuthority.verify_live!(reconstructed, @capability_id, broker: broker)

    # The real end effect a worker gating CommandBus.run/4 on verify_live!/3
    # gets: CommandBus's OWN admission also refuses this reconstructed
    # authority (Authority.admits?/2's `not expired?/1`), so the real
    # Ash.create never runs -- proven by the real final state below, not
    # merely by the refusal tuple.
    reconstructed_command = %{command | authority: reconstructed}

    assert {:error, %{code: :authority_mismatch}} =
             CommandBus.run(reconstructed_command, data_message(%{"label" => label}), Item,
               store_opts: store_opts!()
             )

    assert [] =
             Item
             |> Ash.read!(domain: ItemDomain)
             |> Enum.filter(&(&1.label == label))
  end

  test "a grant revoked after enqueue is refused by verify_live!/3 even though its (unbounded) authority is not itself expired" do
    broker = start_broker!()
    subject = Identity.principal("subject-revoked")
    label = unique_label("revoked")

    assert {:ok, authority} = Grant.grant(subject, @capability_id, broker: broker)

    command =
      Command.new(@capability_id,
        command_id: "revoke-cmd",
        agent_id: "agent-1",
        principal_id: subject,
        authority: authority,
        input: %{label: label}
      )

    args = Delivery.Oban.payload(command)
    reconstructed = ObanAuthority.reconstruct(args, "subject-revoked")

    # BEFORE revocation: the broker still stands, so re-verifying live is a
    # real, legitimate success -- not merely "no explicit expiry."
    assert {:ok, ^reconstructed} =
             ObanAuthority.verify_live!(reconstructed, @capability_id, broker: broker)

    # Simulates exactly the gap between Oban enqueue and perform/1 this test
    # exists to close: the principal's real broker grant is torn down while
    # the job would have been sitting in the queue.
    assert :ok = Grant.revoke(subject, @capability_id, broker: broker)

    # No time bound at all was ever set on this grant -- confirming this
    # scenario is NOT reducible to the expiry case above. Only a live
    # broker re-query (not carrying/parsing any timestamp) can catch it.
    refute Authority.expired?(reconstructed)

    assert {:error, %{reason: :authority_stale}} =
             ObanAuthority.verify_live!(reconstructed, @capability_id, broker: broker)

    # The real, currently-failing-then-passing effect this closes: a worker
    # that gates CommandBus.run/4 on verify_live!/3 (as AshA2A.Delivery.Oban's
    # moduledoc now instructs a host worker to) never reaches the real
    # Ash.create at all -- proven by the real final ETS-backed state, not
    # just the verify_live!/3 return value.
    result =
      with {:ok, _authority} <-
             ObanAuthority.verify_live!(reconstructed, @capability_id, broker: broker) do
        reconstructed_command = %{command | authority: reconstructed}

        CommandBus.run(reconstructed_command, data_message(%{"label" => label}), Item,
          store_opts: store_opts!()
        )
      end

    assert {:error, %{reason: :authority_stale}} = result

    assert [] =
             Item
             |> Ash.read!(domain: ItemDomain)
             |> Enum.filter(&(&1.label == label))
  end

  test "reconstruct/2 accepts a raw principal value, matching AshA2A.Test.Support.CommandWorker's own convention, and returns nil with no authority on the wire" do
    subject = Identity.principal("raw-principal-1")
    authority = Authority.new(subject, @capability_id, token_id: "auth-raw-1")

    command =
      Command.new(@capability_id,
        command_id: "raw-cmd-1",
        agent_id: "agent-1",
        principal_id: subject,
        authority: authority,
        input: %{}
      )

    args = Delivery.Oban.payload(command)

    assert %Authority{} = reconstructed = ObanAuthority.reconstruct(args, "raw-principal-1")
    assert reconstructed.subject == subject
    assert reconstructed.capability_id == @capability_id
    assert reconstructed.expires_at == nil

    no_authority_command =
      Command.new("AshA2A.Test.Fixture.Echo.read",
        command_id: "no-auth-1",
        agent_id: "agent-1",
        principal_id: "anonymous",
        input: %{}
      )

    no_authority_args = Delivery.Oban.payload(no_authority_command)
    assert is_nil(no_authority_args["authority_token_id"])
    assert is_nil(no_authority_args["authority_expires_at"])
    assert is_nil(ObanAuthority.reconstruct(no_authority_args, "anonymous"))
    assert {:ok, nil} = ObanAuthority.verify_live!(nil, "AshA2A.Test.Fixture.Echo.read")
  end
end

# --- SECTION 13: Original test/ash_a2a/oban_delivery_dedup_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ObanDeliveryDedupTest do
  @moduledoc """
  R11: `AshA2A.Delivery.Oban.enqueue/3` must hold at most one live job per
  admitted command (`command_id` + `fingerprint`), and
  `AshA2A.Delivery.Oban.perform_result/2` must turn a CommandBus claim that
  is still held elsewhere into an Oban snooze instead of a burned attempt.

  Real Postgres-backed `oban_jobs` table and a real `Oban` instance (same
  setup as `oban_delivery_qualification_test.exs`), a real
  `AshA2A.CommandBus` and a real `AshA2A.ReceiptStore.Memory` claim. No
  mocks.
  """
  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_solo

  import Ecto.Query

  alias AshA2A.{Command, CommandBus, Delivery, Identity}
  alias AshA2A.Authority.Grant
  alias AshA2A.Test.Support.CommandWorker

  @oban_name AshA2A.Test.ObanDedup
  @capability_id "AshA2A.Test.Fixture.Item.create"

  setup_all do
    {:ok, _} = Application.ensure_all_started(:postgrex)
    start_supervised!(AshA2A.Test.Repo)

    case Ecto.Migrator.up(
           AshA2A.Test.Repo,
           20_260_913_000_001,
           AshA2A.Test.Repo.Migrations.AddObanJobsTable,
           log: false
         ) do
      :ok -> :ok
      :already_up -> :ok
    end

    start_supervised!(
      {Oban, name: @oban_name, repo: AshA2A.Test.Repo, queues: [], plugins: false}
    )

    :ok
  end

  setup do
    # Run-unique: oban_jobs rows persist across runs and dedup is by command_id.
    %{
      suffix:
        Base.encode16(:crypto.strong_rand_bytes(6), case: :lower) <>
          "-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
    }
  end

  test "enqueueing the same command twice yields one live job", %{suffix: suffix} do
    command = build_command("dedup-#{suffix}", %{label: "a-#{suffix}"})

    assert {:ok, %Delivery{provider_ref: first_id} = first} = enqueue(command)
    assert first.metadata.deduplicated? == false

    assert {:ok, %Delivery{provider_ref: second_id} = second} = enqueue(command)
    assert second.metadata.deduplicated? == true
    assert second_id == first_id

    assert [_one] = jobs_for(command)
  end

  test "same command_id with different content is not absorbed", %{suffix: suffix} do
    a = build_command("conflict-#{suffix}", %{label: "a-#{suffix}"})

    b =
      %{a | input: %{label: "b-#{suffix}"}} |> then(&%{&1 | fingerprint: Command.fingerprint(&1)})

    refute a.fingerprint == b.fingerprint

    assert {:ok, %Delivery{provider_ref: a_id}} = enqueue(a)
    assert {:ok, %Delivery{provider_ref: b_id} = b_delivery} = enqueue(b)
    refute a_id == b_id
    assert b_delivery.metadata.deduplicated? == false
    assert length(jobs_for(a)) == 2
  end

  test "a discarded job does not block a legitimate re-enqueue", %{suffix: suffix} do
    command = build_command("discarded-#{suffix}", %{label: "d-#{suffix}"})

    assert {:ok, %Delivery{provider_ref: first_id}} = enqueue(command)

    AshA2A.Test.Repo.update_all(
      from(j in Oban.Job, where: j.id == ^first_id),
      set: [state: "discarded", discarded_at: DateTime.utc_now()]
    )

    assert {:ok, %Delivery{provider_ref: second_id} = second} = enqueue(command)
    refute second_id == first_id
    assert second.metadata.deduplicated? == false
  end

  test "callers can opt out with job_opts unique: false", %{suffix: suffix} do
    command = build_command("optout-#{suffix}", %{label: "o-#{suffix}"})

    opts = [name: @oban_name, job_opts: [queue: :commands, unique: false]]
    assert {:ok, %Delivery{provider_ref: a}} = Delivery.Oban.enqueue(CommandWorker, command, opts)
    assert {:ok, %Delivery{provider_ref: b}} = Delivery.Oban.enqueue(CommandWorker, command, opts)
    refute a == b
    assert length(jobs_for(command)) == 2
  end

  test "a real in-flight CommandBus claim maps to a snooze, not a burned attempt",
       %{suffix: suffix} do
    command = build_command("inflight-#{suffix}", %{label: "i-#{suffix}"})
    store = CommandBus.default_store()

    # A real claim held by a first executor that has not committed yet.
    assert {:execute, _execution_id} = store.claim(command, [])

    message =
      AshA2A.Protocol.Message.new_user([
        AshA2A.Protocol.Part.Data.new(%{"label" => "i-#{suffix}"})
      ])

    result = CommandBus.run(command, message, AshA2A.Test.Fixture.Item)

    assert {:error, %{code: :in_flight}} = result
    assert {:snooze, 30} = Delivery.Oban.perform_result(result)
    assert {:snooze, 5} = Delivery.Oban.perform_result(result, 5)
  end

  test "perform_result/2 passes success and other refusals through" do
    assert :ok = Delivery.Oban.perform_result(:ok)
    assert :ok = Delivery.Oban.perform_result({:ok, :receipt})
    assert {:snooze, 30} = Delivery.Oban.perform_result({:error, :in_flight})
    assert {:snooze, 30} = Delivery.Oban.perform_result({:error, %{code: :actuation_in_flight}})

    assert {:error, %{code: :command_conflict}} =
             Delivery.Oban.perform_result({:error, %{code: :command_conflict}})

    assert {:error, {:unexpected_command_bus_result, :weird}} =
             Delivery.Oban.perform_result(:weird)
  end

  defp enqueue(command) do
    Delivery.Oban.enqueue(CommandWorker, command,
      name: @oban_name,
      job_opts: [queue: :commands]
    )
  end

  defp jobs_for(command) do
    command_id = Identity.external(command.command_id)

    AshA2A.Test.Repo.all(
      from(j in Oban.Job,
        where: fragment("?->>'command_id' = ?", j.args, ^command_id),
        where: j.state not in ["cancelled", "discarded"]
      )
    )
  end

  defp build_command(command_id, input) do
    principal = Identity.principal("subject-#{command_id}")
    {:ok, authority} = Grant.grant(principal, @capability_id)

    Command.new(@capability_id,
      command_id: command_id,
      agent_id: "agent-#{command_id}",
      principal_id: principal,
      authority: authority,
      input: input
    )
  end
end

# --- SECTION 14: Original test/ash_a2a/oban_delivery_qualification_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ObanDeliveryQualificationTest do
  @moduledoc """
  GAP D -- real Oban integration qualification.

  `test/ash_a2a/oban_delivery_test.exs` only ever exercised
  `AshA2A.Delivery.new/3` and `AshA2A.Delivery.Oban.payload/1` -- pure
  functions over plain structs/maps. `AshA2A.Delivery.Oban.enqueue/3`, the
  only function that actually touches a real `Oban.Job`/`Oban`, was never
  called by any test in this repo (nor was `Oban` a resolvable dependency
  at all until this same release cycle's `feat(deps)` commit).

  This file proves, against a real PostgreSQL-backed `oban_jobs` table and
  a real `Oban` instance (no mocked queue, no stubbed job execution, per
  this workspace's Chicago-style testing discipline):

    1. `AshA2A.Delivery.Oban.available?/0` is real `true` now that `oban`
       is a resolvable dependency.
    2. `enqueue/3` real-inserts a real `Oban.Job` row, carrying a real
       `AshA2A.Command`'s serialized content as `args` -- confirmed by
       querying `oban_jobs` directly through `AshA2A.Test.Repo`, not by
       trusting `enqueue/3`'s own return value alone.
    3. Queue acceptance is not an execution receipt: immediately after
       `enqueue/3` succeeds, no `AshA2A.Receipt` exists yet for that
       command in the default `AshA2A.ReceiptStore.Memory`.
    4. A real `AshA2A.Test.Support.CommandWorker` (`Oban.Worker`), run
       through `Oban.Testing.perform_job/2` (Oban's own real,
       non-mocking test-execution helper -- no hand-rolled job loop),
       reconstructs the real `AshA2A.Command` from the job's real,
       DB-persisted `args` and calls `AshA2A.CommandBus.run/4`, which
       performs a real `Ash.create` against
       `AshA2A.Test.Fixture.Item` (ETS-backed, but a genuine Ash data
       layer, not a fixture double) and commits a real `AshA2A.Receipt`.
    5. Running that same worker's `perform/1` a second time for the
       identical command (Oban's own at-least-once delivery semantics: a
       job may legitimately be re-attempted) replays the already-committed
       receipt instead of re-executing the `Ash.create` a second time --
       proven by the real final state (`Ash.read!/2` against the fixture's
       real ETS-backed records), not merely by inspecting receipt
       bookkeeping.

  Needs a real, reachable PostgreSQL instance for `AshA2A.Test.Repo`
  (`config/test.exs`); `setup_all` checks that for real and raises with
  setup instructions (matching this repo's own `hddl_cli binary not built
  at ...` raise-with-instructions convention,
  `test/support/semantic_hddl_verification.ex`) rather than crashing
  opaquely if a future run has none reachable. The Ash-domain side
  (`AshA2A.Test.Fixture.Item`'s ETS data layer, `AshA2A.CommandBus`,
  `AshA2A.ReceiptStore.Memory`) needs no Postgres at all -- only the real
  `oban_jobs` table this test inserts into and reads back from does.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_solo
  alias AshA2A.{Command, Delivery, Identity, SemanticSubject}
  alias AshA2A.Authority.Grant
  alias AshA2A.Test.Fixture.{Item, ItemDomain}
  alias AshA2A.Test.Support.CommandWorker

  @oban_name AshA2A.Test.Oban
  @capability_id "AshA2A.Test.Fixture.Item.create"

  setup_all do
    repo_config = ensure_postgres_reachable!()

    {:ok, _} = Application.ensure_all_started(:postgrex)
    start_supervised!(AshA2A.Test.Repo)

    apply_oban_migration!()

    start_supervised!(
      {Oban, name: @oban_name, repo: AshA2A.Test.Repo, queues: [], plugins: false}
    )

    %{repo_config: repo_config}
  end

  setup do
    # Run-unique, not just VM-unique: `oban_jobs` persists across runs and
    # `AshA2A.Delivery.Oban.enqueue/3` deduplicates on command_id +
    # fingerprint by default (R11), so a VM-monotonic suffix could collide
    # with a prior run's still-live row and return that job instead.
    suffix =
      Base.encode16(:crypto.strong_rand_bytes(6), case: :lower) <>
        "-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))

    %{suffix: suffix, label: "oban-qual-item-#{suffix}"}
  end

  test "AshA2A.Delivery.Oban.available?/0 is real true now that oban is a resolvable dep" do
    assert Delivery.Oban.available?() == true
  end

  test "enqueue/3 real-inserts a real Oban.Job row carrying a real Command, and no receipt exists yet",
       %{suffix: suffix, label: label} do
    command = build_command("cmd-#{suffix}", label)

    assert {:ok, %Delivery{} = delivery} = enqueue(command)

    assert delivery.provider == :oban
    assert delivery.status == :scheduled
    assert is_integer(delivery.provider_ref)

    # Confirmed by querying the real oban_jobs table directly -- not by
    # trusting enqueue/3's own return value alone.
    job = AshA2A.Test.Repo.get!(Oban.Job, delivery.provider_ref)

    assert job.worker == "AshA2A.Test.Support.CommandWorker"
    assert job.state == "available"
    assert job.queue == "commands"
    assert job.args["capability_id"] == @capability_id
    assert job.args["command_id"] == Identity.external(command.command_id)
    assert job.args["principal_id"] == Identity.external(command.principal_id)
    assert job.args["authority_token_id"] == Identity.external(command.authority.token_id)
    assert job.args["input"] == %{"label" => label}
    assert job.args["fingerprint"] == command.fingerprint

    # Queue acceptance != execution receipt: the job was really accepted
    # (real DB row, confirmed above), but the command has not been
    # admitted/dispatched/receipted at all yet.
    assert :error = AshA2A.ReceiptStore.Memory.fetch(command.command_id)

    assert [] =
             Item
             |> Ash.read!(domain: ItemDomain)
             |> Enum.filter(&(&1.label == label))
  end

  test "a real CommandWorker.perform/1, run via Oban.Testing.perform_job/2, reconstructs the command, performs a real Ash.create, and commits a real Receipt",
       %{suffix: suffix, label: label} do
    command = build_command("cmd-#{suffix}", label)

    assert {:ok, %Delivery{provider_ref: job_id}} = enqueue(command)

    job = AshA2A.Test.Repo.get!(Oban.Job, job_id) |> dequeue!()

    assert :ok = Oban.Testing.perform_job(job, repo: AshA2A.Test.Repo)

    assert {:ok, receipt} = AshA2A.ReceiptStore.Memory.fetch(command.command_id)
    assert receipt.status == :completed
    assert receipt.consequence == :change
    assert receipt.replayed? == false
    assert receipt.capability_id == @capability_id

    created =
      Item
      |> Ash.read!(domain: ItemDomain)
      |> Enum.filter(&(&1.label == label))

    assert [%Item{label: ^label}] = created
  end

  test "running CommandWorker.perform/1 twice for the same command_id replays instead of double-executing",
       %{suffix: suffix, label: label} do
    command = build_command("cmd-#{suffix}", label)

    assert {:ok, %Delivery{provider_ref: job_id}} = enqueue(command)

    job = AshA2A.Test.Repo.get!(Oban.Job, job_id) |> dequeue!()

    assert :ok = Oban.Testing.perform_job(job, repo: AshA2A.Test.Repo)
    assert {:ok, first_receipt} = AshA2A.ReceiptStore.Memory.fetch(command.command_id)

    items_after_first =
      Item
      |> Ash.read!(domain: ItemDomain)
      |> Enum.filter(&(&1.label == label))

    assert [%Item{id: created_id}] = items_after_first

    # Oban's own at-least-once delivery semantics: the same real DB job row
    # is dequeued and attempted a second time (a real Ecto update bumping
    # `attempt`/`attempted_at`, exactly what a live Oban queue producer's
    # own dequeue SQL does on redelivery -- not a fabricated retry).
    job = dequeue!(job)
    assert :ok = Oban.Testing.perform_job(job, repo: AshA2A.Test.Repo)
    assert {:ok, second_receipt} = AshA2A.ReceiptStore.Memory.fetch(command.command_id)

    # Same stored receipt identity both times -- the store never
    # re-committed a second receipt for this command_id.
    assert second_receipt.receipt_id == first_receipt.receipt_id
    assert second_receipt.fingerprint == first_receipt.fingerprint

    # Real final state, not just receipt bookkeeping: no second Ash.create
    # happened -- still exactly one real Item row for this label, and it
    # is the same record.
    items_after_second =
      Item
      |> Ash.read!(domain: ItemDomain)
      |> Enum.filter(&(&1.label == label))

    assert [%Item{id: ^created_id}] = items_after_second
  end

  test "a command carrying a real semantic_subject round-trips its fingerprint through real Oban delivery + real CommandWorker reconstruction",
       %{suffix: suffix, label: label} do
    command = build_command_with_semantic_subject("cmd-sem-#{suffix}", label)

    assert {:ok, %Delivery{provider_ref: job_id}} = enqueue(command)

    job = AshA2A.Test.Repo.get!(Oban.Job, job_id)

    # The real, DB-persisted job args carry the semantic_subject fields --
    # confirmed directly against the real oban_jobs row, not by trusting
    # payload/1's return value alone.
    assert job.args["semantic_subject_graph_digest"] == command.semantic_subject.graph_digest

    assert job.args["semantic_subject_projection_digest"] ==
             command.semantic_subject.projection_digest

    assert job.args["semantic_subject_manufacturer_digest"] ==
             command.semantic_subject.manufacturer_digest

    assert job.args["semantic_subject_ephemeral"] == command.semantic_subject.ephemeral?

    job = dequeue!(job)
    assert :ok = Oban.Testing.perform_job(job, repo: AshA2A.Test.Repo)

    assert {:ok, receipt} = AshA2A.ReceiptStore.Memory.fetch(command.command_id)

    # The real regression this closes: AshA2A.Test.Support.CommandWorker's
    # real reconstruct_command/1, run through a real Oban job round-trip,
    # must recompute the SAME fingerprint the original command carried --
    # exactly the discriminator AshA2A.ReceiptStore's claim logic uses to
    # tell a legitimate replay apart from a :command_conflict.
    assert receipt.fingerprint == command.fingerprint

    created =
      Item
      |> Ash.read!(domain: ItemDomain)
      |> Enum.filter(&(&1.label == label))

    assert [%Item{label: ^label}] = created
  end

  # Same shape as build_command/2, plus a real, validated
  # AshA2A.SemanticSubject -- exercising the documented WF-5 continuation
  # flow this fix targets, where a command carries exact
  # semantic/manufacture identity through delivery.
  defp build_command_with_semantic_subject(command_id, label) do
    principal = Identity.principal("subject-#{command_id}")
    # Real grant, not a hand-built struct -- CommandWorker.perform/1 now
    # re-verifies live broker standing (see command_worker.ex's moduledoc,
    # "Live authority re-verification"), so the authority must really be
    # granted through the configured broker, not merely constructed.
    {:ok, authority} = Grant.grant(principal, @capability_id)

    {:ok, semantic_subject} =
      SemanticSubject.new(
        graph_digest: "sha256:" <> String.duplicate("1", 64),
        projection_digest: "sha256:" <> String.duplicate("2", 64),
        manufacturer_digest: "sha256:" <> String.duplicate("3", 64),
        ephemeral?: false
      )

    Command.new(@capability_id,
      command_id: command_id,
      agent_id: "agent-#{command_id}",
      principal_id: principal,
      authority: authority,
      semantic_subject: semantic_subject,
      input: %{"label" => label}
    )
  end

  # Real dequeue-claim step, replicating what a live Oban queue producer's
  # own dequeue SQL does when it claims an `available` job for execution
  # (`attempted_at: now`, `attempt: attempt + 1`) -- `deps/oban/lib/oban/
  # queues/executor.ex:198-200`'s `record_finished/1` requires a non-nil
  # `job.attempted_at` (it computes `queue_time` as `DateTime.diff(job.
  # attempted_at, job.scheduled_at, ...)`), which a job fetched straight off
  # `oban_jobs` never has -- real Oban always sets it via this same dequeue
  # step, which this test intentionally bypasses (no active queue: `queues:
  # []`) so it can drive `Oban.Testing.perform_job/2` directly. A real Ecto
  # update against the real row, not an in-memory-only patch, so `oban_jobs`
  # itself reflects the real attempt count/timestamp exactly as it would
  # under a live queue.
  defp dequeue!(%Oban.Job{} = job) do
    job
    |> Ecto.Changeset.change(attempted_at: DateTime.utc_now(), attempt: job.attempt + 1)
    |> AshA2A.Test.Repo.update!()
  end

  # `AshA2A.Delivery.Oban.enqueue/3` calls `Oban.Job.new/2` directly (not
  # `CommandWorker.new/2`), so it does not itself merge in the worker's own
  # `use Oban.Worker, queue: :commands` compile-time default -- a caller
  # supplies its intended queue explicitly via `job_opts:`, exactly as a
  # real host integration would.
  defp enqueue(command) do
    Delivery.Oban.enqueue(CommandWorker, command,
      name: @oban_name,
      job_opts: [queue: :commands]
    )
  end

  # -- Real command construction, mirroring
  # test/ash_a2a/command_bus_test.exs's own
  # "matching authority admits a real create and commits its receipt"
  # pattern -- same capability id form, same Authority/Command shape.
  defp build_command(command_id, label) do
    principal = Identity.principal("subject-#{command_id}")
    # Real grant, not a hand-built struct -- see build_command_with_semantic_
    # subject/2's comment above for why.
    {:ok, authority} = Grant.grant(principal, @capability_id)

    Command.new(@capability_id,
      command_id: command_id,
      agent_id: "agent-#{command_id}",
      principal_id: principal,
      authority: authority,
      input: %{label: label}
    )
  end

  defp apply_oban_migration! do
    case Ecto.Migrator.up(
           AshA2A.Test.Repo,
           20_260_913_000_001,
           AshA2A.Test.Repo.Migrations.AddObanJobsTable,
           log: false
         ) do
      :ok -> :ok
      :already_up -> :ok
    end
  end

  defp ensure_postgres_reachable! do
    repo_config = Application.fetch_env!(:ash_a2a, AshA2A.Test.Repo)

    connect_opts = [
      hostname: Keyword.fetch!(repo_config, :hostname),
      port: Keyword.fetch!(repo_config, :port),
      username: Keyword.fetch!(repo_config, :username),
      password: Keyword.fetch!(repo_config, :password),
      database: Keyword.fetch!(repo_config, :database),
      timeout: 2_000,
      connect_timeout: 2_000
    ]

    case Postgrex.start_link(connect_opts) do
      {:ok, pid} ->
        # Postgrex connects lazily by default: start_link alone succeeds even
        # with the database down, deferring failure to opaque pool timeouts.
        # Force a synchronous round trip so an unreachable database fails at
        # this gate, fast, with the run instructions below.
        try do
          Postgrex.query!(pid, "SELECT 1", [])
        rescue
          error ->
            GenServer.stop(pid)

            raise """
            Real Postgres not reachable at #{connect_opts[:hostname]}:#{connect_opts[:port]}/#{connect_opts[:database]} \
            for AshA2A.Test.Repo (test/ash_a2a/oban_delivery_qualification_test.exs).
            Reason: #{Exception.message(error)}

            This test needs a real, dedicated local Postgres instance to create
            and query Oban's real `oban_jobs` table against (GAP D real Oban
            integration -- Chicago-style discipline: no mocked queue, no
            stubbed DB). This release cycle expects one already running at
            that host/port/db (see config/test.exs for the exact connection
            opts this test reads). Start one and re-run, e.g.:

              docker run --rm -p 55432:5432 -e POSTGRES_PASSWORD=postgres \\
                -e POSTGRES_DB=ash_a2a_test postgres:16

            then: mix test test/ash_a2a/oban_delivery_qualification_test.exs
            """
        end

        GenServer.stop(pid)
        repo_config

      {:error, reason} ->
        raise """
        Real Postgres not reachable at #{connect_opts[:hostname]}:#{connect_opts[:port]}/#{connect_opts[:database]} \
        for AshA2A.Test.Repo (test/ash_a2a/oban_delivery_qualification_test.exs).
        Reason: #{inspect(reason)}

        This test needs a real, dedicated local Postgres instance to create
        and query Oban's real `oban_jobs` table against (GAP D real Oban
        integration -- Chicago-style discipline: no mocked queue, no
        stubbed DB). This release cycle expects one already running at
        that host/port/db (see config/test.exs for the exact connection
        opts this test reads). Start one and re-run, e.g.:

          docker run --rm -p 55432:5432 -e POSTGRES_PASSWORD=postgres \\
            -e POSTGRES_DB=ash_a2a_test postgres:16

        then: mix test test/ash_a2a/oban_delivery_qualification_test.exs
        """
    end
  end
end

# --- SECTION 15: Original test/ash_a2a/oban_delivery_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ObanDeliveryTest do
  use ExUnit.Case, async: true

  alias AshA2A.{Authority, Command, Delivery, Identity, SemanticSubject}

  test "provider delivery id remains distinct from A2A task id" do
    command =
      Command.new("Example.Resource.read",
        command_id: "command-1",
        agent_id: "agent-1",
        principal_id: "principal-1",
        task_id: "task-1"
      )

    delivery = Delivery.new(:oban, command, provider_ref: 42, status: :scheduled)

    assert Delivery.task_key(delivery) == "task:task-1"
    assert delivery.provider_ref == 42
    refute delivery.provider_ref == Delivery.task_key(delivery)
  end

  test "Oban payload carries command references but not execution identity" do
    principal = Identity.principal("principal-1")
    authority = Authority.new(principal, "Example.Resource.update", token_id: "auth-1")

    command =
      Command.new("Example.Resource.update",
        command_id: "command-2",
        agent_id: "agent-1",
        principal_id: principal,
        task_id: "task-2",
        authority: authority,
        input: %{value: 7}
      )

    payload = Delivery.Oban.payload(command)

    assert payload["command_id"] == "command:command-2"
    assert payload["task_id"] == "task:task-2"
    assert payload["authority_token_id"] == "runtime:auth-1"
    assert payload["fingerprint"] == command.fingerprint
    refute Map.has_key?(payload, "execution_id")

    # No semantic_subject on this command -- byte-identical to before
    # semantic_subject fields existed on the payload at all.
    refute Map.has_key?(payload, "semantic_subject_graph_digest")
    refute Map.has_key?(payload, "semantic_subject_projection_digest")
    refute Map.has_key?(payload, "semantic_subject_manufacturer_digest")
    refute Map.has_key?(payload, "semantic_subject_ephemeral")
  end

  test "Oban payload carries a real non-nil semantic_subject's fields so fingerprint can round-trip" do
    principal = Identity.principal("principal-3")

    {:ok, semantic_subject} =
      SemanticSubject.new(
        graph_digest: "sha256:" <> String.duplicate("a", 64),
        projection_digest: "sha256:" <> String.duplicate("b", 64),
        manufacturer_digest: "sha256:" <> String.duplicate("c", 64),
        ephemeral?: false
      )

    command =
      Command.new("Example.Resource.update",
        command_id: "command-3",
        agent_id: "agent-1",
        principal_id: principal,
        semantic_subject: semantic_subject,
        input: %{value: 9}
      )

    payload = Delivery.Oban.payload(command)

    assert payload["semantic_subject_graph_digest"] == semantic_subject.graph_digest
    assert payload["semantic_subject_projection_digest"] == semantic_subject.projection_digest
    assert payload["semantic_subject_manufacturer_digest"] == semantic_subject.manufacturer_digest
    assert payload["semantic_subject_ephemeral"] == false

    # Reconstructing a real SemanticSubject from the carried payload fields
    # (mirroring AshA2A.Test.Support.CommandWorker.reconstruct_semantic_subject/1)
    # and rebuilding the Command from it must recompute the exact same
    # fingerprint the original command carries -- the real regression this
    # payload/1 fix closes: before it, a reconstructed command with a real
    # semantic_subject computed a DIFFERENT fingerprint than the original,
    # because the semantic_subject fields never reached the worker at all.
    {:ok, reconstructed_subject} =
      SemanticSubject.new(
        graph_digest: payload["semantic_subject_graph_digest"],
        projection_digest: payload["semantic_subject_projection_digest"],
        manufacturer_digest: payload["semantic_subject_manufacturer_digest"],
        ephemeral?: payload["semantic_subject_ephemeral"]
      )

    reconstructed =
      Command.new(payload["capability_id"],
        command_id: "command-3",
        agent_id: "agent-1",
        principal_id: principal,
        semantic_subject: reconstructed_subject,
        input: payload["input"]
      )

    assert Command.fingerprint(reconstructed) == command.fingerprint
  end
end

# --- SECTION 16: Original test/ash_a2a/planning_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.PlanningTest do
  use ExUnit.Case, async: true

  alias AshA2A.Planning
  alias AshA2A.Planning.Candidate
  alias AshA2A.Test.Fixture.Echo

  test "canonical planner capability ids are admitted but remain candidate-only" do
    envelope = %{
      "request_id" => "plan-1",
      "steps" => [%{"capability_id" => "AshA2A.Test.Fixture.Echo.read"}]
    }

    assert {:ok, candidate} =
             Planning.from_envelope(Echo, envelope,
               planner: :ferroplan,
               formalism: :pddl
             )

    assert candidate.standing == :candidate
    assert candidate.authority == :none
    assert candidate.planner == :ferroplan
    assert candidate.formalism == :pddl
    assert candidate.capability_ids == ["AshA2A.Test.Fixture.Echo.read"]
    assert [%{id: "AshA2A.Test.Fixture.Echo.read"}] = candidate.admitted_skills
  end

  test "noncanonical planner capability ids are refused before execution" do
    envelope = %{
      "steps" => [%{"capability_id" => "AshA2A.Test.Fixture.Echo.delete_everything"}]
    }

    assert {:error, %{code: :noncanonical_capability}} =
             Planning.from_envelope(Echo, envelope, planner: :ferroplan)
  end

  test "candidate authority ceiling cannot be widened by a planner" do
    candidate =
      Candidate.new(
        :external,
        %{"steps" => []},
        ["AshA2A.Test.Fixture.Echo.read"]
      )
      |> Map.put(:authority, :do)

    assert {:error, %{code: :planner_authority_ceiling_violated}} =
             Planning.admit(Echo, candidate)
  end

  test "nested capability projections are collected deterministically" do
    envelope = %{
      "methods" => [
        %{
          "subtasks" => [
            %{"capability_id" => "AshA2A.Test.Fixture.Echo.read"},
            %{"capability_ids" => ["AshA2A.Test.Fixture.Echo.read"]}
          ]
        }
      ]
    }

    assert Planning.extract_capability_ids(envelope) == [
             "AshA2A.Test.Fixture.Echo.read"
           ]
  end
end

# --- SECTION 17: Original test/ash_a2a/prepared_effect_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.PreparedEffectTest do
  use ExUnit.Case, async: true

  defp evidence_ref do
    %{
      "schema" => "sa2a.semantic-evidence-envelope.v1",
      "contractVersion" => "v26.9.29",
      "subject" => "urn:subject:1",
      "sourceDigest" => "sha256:" <> String.duplicate("a", 64),
      "graphDigest" => "sha256:" <> String.duplicate("b", 64),
      "replayIdentity" => "replay:subject:1",
      "envelopeDigest" => "sha256:" <> String.duplicate("c", 64),
      "authority" => "NONE",
      "consequence" => "EVIDENCE_ONLY"
    }
  end

  test "prepared digest binds effect" do
    {:ok, i} =
      AshA2A.EffectInstance.new(%{
        request: %{},
        subject: %{"id" => 1},
        effect: %{"op" => "update"}
      })

    assert {:ok, p} = AshA2A.PreparedEffect.new(i, %{"op" => "update"}, :change)
    assert p.prepared_digest =~ "sha256:"
    assert p.semantic_evidence == nil
  end

  test "semantic evidence is bound into prepared identity without authority promotion" do
    {:ok, i} =
      AshA2A.EffectInstance.new(%{
        request: %{},
        subject: %{"id" => 1},
        effect: %{"op" => "update"}
      })

    assert {:ok, plain} = AshA2A.PreparedEffect.new(i, %{"op" => "update"}, :change)

    assert {:ok, evidenced} =
             AshA2A.PreparedEffect.new(i, %{"op" => "update"}, :change,
               semantic_evidence: evidence_ref()
             )

    refute plain.prepared_digest == evidenced.prepared_digest
    assert evidenced.semantic_evidence["authority"] == "NONE"
  end

  test "prepared effect refuses evidence authority smuggling" do
    {:ok, i} =
      AshA2A.EffectInstance.new(%{
        request: %{},
        subject: %{"id" => 1},
        effect: %{"op" => "update"}
      })

    evidence = Map.put(evidence_ref(), "authority", "DO")

    assert {:error, %{code: :refused_semantic_evidence, subject: :authority}} =
             AshA2A.PreparedEffect.new(i, %{"op" => "update"}, :change,
               semantic_evidence: evidence
             )
  end
end

# --- SECTION 18: Original test/ash_a2a/presence_topology_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.PresenceTopologyTest do
  use ExUnit.Case, async: true

  alias AshA2A.{Identity, Topology.Presence}

  test "presence keys preserve typed machine identity" do
    assert Presence.key(Identity.agent("agent-1")) == "agent:agent-1"
    assert Presence.key(Identity.task("task-1")) == "task:task-1"
  end

  test "missing host Presence module returns typed unsupported" do
    missing = AshA2A.Test.MissingPresence
    refute Presence.available?(missing)

    assert {:error, {:unsupported, :phoenix_presence, ^missing, :list, 1}} =
             Presence.list(missing, "agents")
  end
end

# --- SECTION 19: Original test/ash_a2a/reactor_command_workflow_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Reactor.CommandWorkflowTest do
  @moduledoc """
  Real `Reactor.run/2..4` execution over `AshA2A.Reactor.CommandWorkflow` --
  the actual Reactor DAG-execution/scheduler engine, not a bare function
  call to a `Reactor.Step` callback (which is all
  `test/ash_a2a/lifecycle_reactor_test.exs` exercised before this file).
  Uses the same default, application-supervised `AshA2A.ReceiptStore.Memory`
  process real callers (`AshA2AAgentCommandBusTest`) already rely on --
  every command below carries a globally unique `command_id`
  (`System.unique_integer/1`), so no dedicated per-test store process is
  needed for isolation. No Mock/mox/patch/monkeypatch anywhere in this file.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  import AshA2A.Test.MessageHelpers

  alias AshA2A.{Authority, Identity, Receipt, ReceiptStore}
  alias AshA2A.Test.Fixture.{Echo, Item, ItemDomain}

  test "a real Reactor.run/2 DAG builds a command, routes it through CommandBus, and confirms the committed receipt (:observe)" do
    command_id = "reactor-workflow-read-#{System.unique_integer([:positive])}"

    inputs = %{
      capability_id: "AshA2A.Test.Fixture.Echo.read",
      agent_id: "reactor-workflow-agent",
      principal_id: "anonymous",
      command_input: %{},
      resource_or_domain: Echo,
      message: data_message(%{}),
      authority: nil,
      command_id: command_id
    }

    assert {:ok, %Receipt{} = receipt} =
             Reactor.run(AshA2A.Reactor.CommandWorkflow, inputs, %{})

    assert receipt.command_id == Identity.command(command_id)
    assert receipt.status == :completed
    assert receipt.consequence == :observe
    refute receipt.replayed?

    assert {:ok, stored} = ReceiptStore.Memory.fetch(Identity.command(command_id), [])
    assert stored.receipt_id == receipt.receipt_id
  end

  test "a real Reactor.run/2 DAG admits and commits an authorized consequence-bearing command (:change)" do
    command_id = "reactor-workflow-create-#{System.unique_integer([:positive])}"
    capability_id = "AshA2A.Test.Fixture.Item.create"

    principal =
      Identity.principal("reactor-workflow-subject-#{System.unique_integer([:positive])}")

    authority =
      Authority.new(principal, capability_id,
        token_id: "reactor-workflow-auth-#{System.unique_integer([:positive])}"
      )

    inputs = %{
      capability_id: capability_id,
      agent_id: "reactor-workflow-agent",
      principal_id: principal,
      command_input: %{label: "reactor-workflow-widget"},
      resource_or_domain: Item,
      message: data_message(%{"label" => "reactor-workflow-widget"}),
      authority: authority,
      command_id: command_id
    }

    assert {:ok, %Receipt{} = receipt} =
             Reactor.run(AshA2A.Reactor.CommandWorkflow, inputs, %{})

    assert receipt.status == :completed
    assert receipt.consequence == :change
    refute receipt.replayed?

    assert {:ok, stored} = ReceiptStore.Memory.fetch(Identity.command(command_id), [])
    assert stored.receipt_id == receipt.receipt_id

    assert {:ok, items} = Ash.read(Item, domain: ItemDomain)
    assert Enum.any?(items, &(&1.label == "reactor-workflow-widget"))
  end

  test "the real Reactor engine surfaces CommandBus's real :authority_required refusal for an unauthorized consequence-bearing command -- never a raw unguarded Ash exception, never a silent bypass" do
    command_id = "reactor-workflow-unauth-#{System.unique_integer([:positive])}"
    capability_id = "AshA2A.Test.Fixture.Item.create"
    label = "reactor-workflow-should-never-exist-#{System.unique_integer([:positive])}"

    inputs = %{
      capability_id: capability_id,
      agent_id: "reactor-workflow-agent",
      # A real principal with NO `AshA2A.Authority` admitted for this
      # capability -- the deliberately unauthorized input this test exists
      # to construct.
      principal_id: "reactor-workflow-subject-no-authority",
      command_input: %{label: label},
      resource_or_domain: Item,
      message: data_message(%{"label" => label}),
      authority: nil,
      command_id: command_id
    }

    assert {:error, errors} = Reactor.run(AshA2A.Reactor.CommandWorkflow, inputs, %{})

    # The real refusal CommandBus.admit/2 raises for a :change command with
    # no admitted Authority (lib/ash_a2a/command_bus.ex `defp admit(_command,
    # consequence) when consequence in [:change, :external_do] -> {:error,
    # refusal(:authority_required)}`) must be the real reason the Reactor
    # engine halted on -- found by walking the real
    # `Reactor.Error.Invalid.RunStepError` chain Reactor wraps step failures
    # in, not asserted as an opaque error tuple.
    assert :authority_required = refusal_code(errors)

    # The real CommandBus admission boundary refused this command BEFORE the
    # real Ash dispatcher/action ever ran -- proven two ways, not asserted:
    # no receipt was ever committed for this command_id (CommandBus.admit/2
    # short-circuits before the store is even asked to claim it), and no
    # Item record with this unique label exists in the real ETS-backed
    # data layer.
    assert :error = ReceiptStore.Memory.fetch(Identity.command(command_id), [])

    assert {:ok, items} = Ash.read(Item, domain: ItemDomain)
    refute Enum.any?(items, &(&1.label == label))
  end

  # Reactor wraps every step-level `{:error, reason}` in a real
  # `Reactor.Error.Invalid.RunStepError` (`error.error` holding the original
  # reason), then Reactor's own Splode-based error aggregation may nest that
  # inside a list and/or a composite `Reactor.Error.Invalid` -- this walks
  # that real, observed shape rather than assuming one fixed level of
  # nesting.
  defp refusal_code(errors) do
    errors
    |> List.wrap()
    |> Enum.flat_map(&flatten_error/1)
    |> Enum.find_value(fn
      %{code: code} -> code
      _ -> nil
    end)
  end

  defp flatten_error(%Reactor.Error.Invalid.RunStepError{error: inner}),
    do: [inner | flatten_error(inner)]

  defp flatten_error(%{errors: nested}) when is_list(nested),
    do: Enum.flat_map(nested, &flatten_error/1)

  defp flatten_error(other), do: [other]

  test "AshEx4pm.Reactor.OcelMiddleware emits telemetry events on step execution" do
    command_id = "reactor-workflow-telemetry-#{System.unique_integer([:positive])}"
    test_pid = self()
    handler_id = {:test_reactor_telemetry, System.unique_integer([:positive])}

    :telemetry.attach(
      handler_id,
      [:ash_ex4pm, :reactor, :event],
      fn event_name, measurements, metadata, _config ->
        send(test_pid, {:telemetry_event, event_name, measurements, metadata})
      end,
      nil
    )

    inputs = %{
      capability_id: "AshA2A.Test.Fixture.Echo.read",
      agent_id: "reactor-workflow-agent",
      principal_id: "anonymous",
      command_input: %{},
      resource_or_domain: Echo,
      message: data_message(%{}),
      authority: nil,
      command_id: command_id
    }

    try do
      assert {:ok, %Receipt{}} = Reactor.run(AshA2A.Reactor.CommandWorkflow, inputs, %{})
      assert_receive {:telemetry_event, [:ash_ex4pm, :reactor, :event], _meas, _meta}, 1000
    after
      :telemetry.detach(handler_id)
    end
  end
end

# --- SECTION 20: Original test/ash_a2a/receipt_outbox_hardening_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT


# --- SECTION 21: Original test/ash_a2a/receipt_outbox_reconciler_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ReceiptOutboxReconcilerTest do
  @moduledoc """
  Chicago-school evidence for `AshA2A.ReceiptOutbox.Reconciler`: real journal
  entries on a real filesystem outbox directory, a real `GenServer`
  (`start_supervised!`), a real (unstarted, therefore genuinely unavailable
  -- not mocked) `AshA2A.ReceiptStore.Memory` target, and real
  `:telemetry.attach/4` handlers forwarding real emitted events to this test
  process's own mailbox. No `Mox`/`:meck`/`Mock`/`patch`/`monkeypatch`
  anywhere in this file; every assertion is on real returned/observed state
  (telemetry payloads, `ReceiptOutbox.entries/0`, `ReceiptOutbox.count/0`),
  never on "was this called".

  `async: false`: `Application.put_env(:ash_a2a, :receipt_outbox_dir, ...)`
  is process-global application config.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  alias AshA2A.{Command, Identity, Receipt, ReceiptOutbox}
  alias AshA2A.ReceiptOutbox.Reconciler

  setup do
    outbox_dir =
      Path.join(
        System.tmp_dir!(),
        "ash-a2a-outbox-reconciler-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:ash_a2a, :receipt_outbox_dir, outbox_dir)

    on_exit(fn ->
      Application.delete_env(:ash_a2a, :receipt_outbox_dir)
      File.rm_rf!(outbox_dir)
    end)

    {:ok, outbox_dir: outbox_dir}
  end

  # A real, deliberately-never-started `AshA2A.ReceiptStore.Memory` name:
  # every `GenServer.call` against it real-exits `:noproc`, which
  # `AshA2A.ReceiptOutbox`'s own `safe/3` real-catches as
  # `{:error, :receipt_store_unavailable}` -- a real unavailable-collaborator
  # condition (per this codebase's own existing convention for that state),
  # not a test double standing in for the store.
  defp unavailable_store_opts do
    [name: Module.concat(__MODULE__, "UnstartedStore#{System.unique_integer([:positive])}")]
  end

  defp append_pending_receipt!(command_id_value, attempts) do
    principal = Identity.principal("subject-reconciler-probe")

    command =
      Command.new("AshA2A.Test.Fixture.reconciler_probe",
        command_id: command_id_value,
        agent_id: "agent-reconciler-probe",
        principal_id: principal
      )

    execution_id = Identity.execution("exec-#{command_id_value}")

    receipt =
      command
      |> Receipt.pending(execution_id, :change)
      |> Map.put(:reconciliation, %{state: :pending, attempts: attempts})

    :ok = ReceiptOutbox.append(receipt)
    receipt
  end

  defp attach_forwarder(event) do
    test_pid = self()
    handler_id = {__MODULE__, event, make_ref()}

    :telemetry.attach(
      handler_id,
      event,
      fn _event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  test "tick/1 drains the real outbox and emits a real :tick telemetry event with real counts" do
    attach_forwarder([:ash_a2a, :receipt_outbox, :reconciler, :tick])

    append_pending_receipt!("cmd-tick-a", 0)
    append_pending_receipt!("cmd-tick-b", 0)
    assert ReceiptOutbox.count() == 2

    name = Module.concat(__MODULE__, "Reconciler#{System.unique_integer([:positive])}")

    start_supervised!({
      Reconciler,
      # Long enough that no automatic tick races the synchronous one below.
      name: name,
      interval_ms: 60_000,
      store: AshA2A.ReceiptStore.Memory,
      store_opts: unavailable_store_opts()
    })

    assert {:ok, %{committed: 0, remaining: 2}} = Reconciler.tick(name)

    assert_receive {:telemetry, [:ash_a2a, :receipt_outbox, :reconciler, :tick],
                    %{committed: 0, remaining: 2}, %{}}

    # Real evidence the drain never actually removed the entries (store is
    # genuinely unavailable): both journal files are still really there.
    assert ReceiptOutbox.count() == 2
  end

  test "tick/1 emits a real :stuck event only for entries at/above the real attempts threshold" do
    tick_event = [:ash_a2a, :receipt_outbox, :reconciler, :tick]
    stuck_event = [:ash_a2a, :receipt_outbox, :reconciler, :stuck]
    attach_forwarder(tick_event)
    attach_forwarder(stuck_event)

    append_pending_receipt!("cmd-stuck", 7)
    append_pending_receipt!("cmd-fine", 1)

    name = Module.concat(__MODULE__, "Reconciler#{System.unique_integer([:positive])}")

    start_supervised!(
      {Reconciler,
       name: name,
       interval_ms: 60_000,
       stuck_attempts_threshold: 5,
       store: AshA2A.ReceiptStore.Memory,
       store_opts: unavailable_store_opts()}
    )

    assert {:ok, %{committed: 0, remaining: 2}} = Reconciler.tick(name)

    assert_receive {:telemetry, ^tick_event, %{committed: 0, remaining: 2}, %{}}

    assert_receive {:telemetry, ^stuck_event, %{attempts: 7},
                    %{command_id: "cmd-stuck", receipt_id: _receipt_id, threshold: 5}}

    refute_receive {:telemetry, ^stuck_event, %{attempts: 1}, _metadata}, 100
  end

  test "the reconciler really wakes on its own schedule without any manual tick/1 call" do
    tick_event = [:ash_a2a, :receipt_outbox, :reconciler, :tick]
    attach_forwarder(tick_event)

    name = Module.concat(__MODULE__, "Reconciler#{System.unique_integer([:positive])}")

    start_supervised!(
      {Reconciler,
       name: name,
       interval_ms: 20,
       store: AshA2A.ReceiptStore.Memory,
       store_opts: unavailable_store_opts()}
    )

    assert_receive {:telemetry, ^tick_event, %{committed: 0, remaining: 0}, %{}}, 500
  end
end

