defmodule AshA2A.GraphLawWasmexHostTest do
  @moduledoc """
  Chicago-school tests for `AshA2A.GraphLaw.WasmexHost`.

  Every assertion below is state-based against the REAL vendored
  `praxis-graphlaw` WebAssembly artifact, executed by the REAL Wasmtime
  runtime through `wasmex`. No collaborator is mocked, stubbed, or faked:
  the wasm bytes are read from real disk, the instance is a real supervised
  GenServer holding a real Wasmtime store, and every digest asserted here
  was produced by real linear-memory marshaling into the real engine.

  ## Why the hard-coded digests are the strongest assertion available

  The digest constants asserted here were measured independently, under a
  DIFFERENT host runtime (V8 under Node, instantiating the same wasm bytes
  with a hand-written import shim), before this Elixir host existed. They
  are therefore not "whatever this implementation happens to produce" --
  they are a cross-runtime oracle. If this host's ABI marshaling were
  wrong, these tests fail.

  That is exactly the shape of the "SA2A Portable Semantic Execution
  Conformance" claim (`Runtime_A != Runtime_B`, `WASM_A = WASM_B`,
  `O*_input,A = O*_input,B` => same outputs), reduced to the two runtimes
  and handful of inputs actually measured so far. These tests are one
  bench in that court. They do NOT establish universal semantic
  equivalence, production ALIVE, or cross-implementation equivalence.

  `blake3_hex("abc")` additionally matches the PUBLISHED BLAKE3 test vector
  for `"abc"`, which is an external oracle independent of both runtimes.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  alias AshA2A.GraphLaw.WasmexHost

  # --- Measured constants (see moduledoc) ------------------------------
  @base_ttl "@prefix ex: <http://example.org/> .\nex:a ex:p ex:b .\nex:b ex:p ex:c .\n"

  # Same graph, DIFFERENT prefix label AND DIFFERENT triple order.
  @reordered_ttl "@prefix zz: <http://example.org/> .\nzz:b zz:p zz:c .\nzz:a zz:p zz:b .\n"

  # One triple's object changed.
  @changed_ttl "@prefix ex: <http://example.org/> .\nex:a ex:p ex:b .\nex:b ex:p ex:ZZZ .\n"

  @base_digest "9b8180962a93910d17c51d029626f393d65ac2f724b9ffc657c90bc4f3b5939d"
  @changed_digest "610ccbcd4ed4b23cf4179fde360625da286557d18a15403f76797e28c1c68f66"
  @blake3_abc "6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85"
  # Published BLAKE3 digest of the empty input.
  @blake3_empty "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"

  @event_ttl "@prefix ex: <http://example.org/> .\nex:c ex:p ex:d .\n"

  @shacl_shapes """
  @prefix sh: <http://www.w3.org/ns/shacl#> .
  @prefix ex: <http://example.org/> .
  ex:PShape a sh:NodeShape ;
    sh:targetSubjectsOf ex:p ;
    sh:property [ sh:path ex:p ; sh:minCount 1 ] .
  """

  setup_all do
    # A real, independently-named instance so these tests never depend on
    # (or disturb) the application-supervised singleton.
    {:ok, pid} = start_supervised({WasmexHost, name: :graphlaw_wasm_test})
    %{engine: pid}
  end

  describe "artifact vendoring" do
    test "the real .wasm artifact is present in priv and non-trivially sized" do
      path = WasmexHost.wasm_path()
      assert File.exists?(path), "vendored artifact missing at #{path}"
      assert %File.Stat{size: size} = File.stat!(path)
      assert size > 1_000_000, "artifact is #{size} bytes, far too small to be the law package"
    end

    test "WASMEX_HOST_MANIFEST.json records the artifact's REAL on-disk digests" do
      assert {:ok, manifest} = WasmexHost.manifest()

      real_bytes = File.read!(WasmexHost.wasm_path())
      real_sha256 = real_bytes |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

      assert manifest["sha256"] == real_sha256,
             "WASMEX_HOST_MANIFEST.json sha256 does not match the bytes actually on disk"

      assert manifest["size_bytes"] == byte_size(real_bytes)
    end

    test "WASMEX_HOST_MANIFEST.json's recorded blake3 is re-derivable by a real external BLAKE3 tool" do
      # The manifest's sha256 is already re-derived from the real bytes by
      # the test above using :crypto. BLAKE3 has no OTP implementation, so
      # this re-derives that field with the real external tool instead of
      # trusting the recorded value. Degrades to a NAMED, VISIBLE skip on a
      # machine without b3sum -- never to a silent pass.
      assert {:ok, manifest} = WasmexHost.manifest()
      assert manifest["blake3"] =~ ~r/\A[0-9a-f]{64}\z/

      case System.find_executable("b3sum") do
        nil ->
          IO.puts(
            "\n[SKIPPED ASSERTION] b3sum not on PATH; WASMEX_HOST_MANIFEST.json blake3 " <>
              "re-derivation not performed on this machine."
          )

        b3sum ->
          {out, 0} = System.cmd(b3sum, [WasmexHost.wasm_path()])
          [measured | _] = String.split(out, ~r/\s+/, trim: true)
          assert measured == manifest["blake3"]
      end
    end

    test "WASMEX_HOST_MANIFEST.json's recorded engine version is what the REAL engine reports" do
      assert {:ok, manifest} = WasmexHost.manifest()
      assert {:ok, reported} = WasmexHost.version(:graphlaw_wasm_test)
      assert manifest["engine_version_reported"] == reported
    end

    test "the engine's BLAKE3 agrees with the same external tool on real file bytes" do
      # Cross-implementation check of the engine's own BLAKE3 against b3sum
      # (a different BLAKE3 implementation entirely), over a real file on
      # real disk -- this is what makes `blake3_hex/3` usable as the single
      # receipt hash algorithm. UTF-8 content, because `blake3_hex` takes a
      # `&str`, not arbitrary bytes.
      case System.find_executable("b3sum") do
        nil ->
          IO.puts("\n[SKIPPED ASSERTION] b3sum not on PATH; engine-vs-b3sum cross-check skipped.")

        b3sum ->
          path =
            Path.join(
              System.tmp_dir!(),
              "graphlaw_blake3_xcheck_#{System.unique_integer([:positive])}.txt"
            )

          content = "SA2A conformance probe\n日本語\n" <> String.duplicate("x", 5000)
          File.write!(path, content)

          try do
            {out, 0} = System.cmd(b3sum, [path])
            [external | _] = String.split(out, ~r/\s+/, trim: true)
            assert {:ok, ^external} = WasmexHost.blake3_hex(content, :graphlaw_wasm_test)
          after
            File.rm(path)
          end
      end
    end
  end

  describe "version/1" do
    test "returns the engine's REAL self-reported version", %{engine: _} do
      assert {:ok, version} = WasmexHost.version(:graphlaw_wasm_test)
      assert version == "praxis-graphlaw v26.7.5"
    end
  end

  describe "graph_hash/3 -- RFC S12 canonical graph identity" do
    test "produces the digest measured independently under a different host runtime" do
      assert {:ok, @base_digest} = WasmexHost.graph_hash(@base_ttl, :graphlaw_wasm_test)
    end

    test "is INVARIANT under prefix relabelling and triple reordering" do
      assert {:ok, base} = WasmexHost.graph_hash(@base_ttl, :graphlaw_wasm_test)
      assert {:ok, reordered} = WasmexHost.graph_hash(@reordered_ttl, :graphlaw_wasm_test)

      assert base == reordered,
             "canonicalization failed: same graph, different serialization, different digest"

      assert reordered == @base_digest
    end

    test "DISTINGUISHES a graph whose content actually changed" do
      assert {:ok, changed} = WasmexHost.graph_hash(@changed_ttl, :graphlaw_wasm_test)
      assert changed == @changed_digest
      refute changed == @base_digest
    end

    test "is stable across repeated real calls on one reused instance" do
      digests =
        for _ <- 1..10 do
          {:ok, d} = WasmexHost.graph_hash(@base_ttl, :graphlaw_wasm_test)
          d
        end

      assert Enum.uniq(digests) == [@base_digest]
    end

    test "round-trips non-ASCII literals through linear memory correctly" do
      unicode = "@prefix ex: <http://example.org/> .\nex:a ex:p \"日本語 ünïcode\" .\n"
      assert {:ok, digest} = WasmexHost.graph_hash(unicode, :graphlaw_wasm_test)
      assert digest =~ ~r/\A[0-9a-f]{64}\z/

      # Same bytes in, same digest out -- proves the UTF-8 length accounting
      # in the ABI marshaling (byte_size, not String.length) is right.
      assert {:ok, ^digest} = WasmexHost.graph_hash(unicode, :graphlaw_wasm_test)
      refute digest == @base_digest
    end
  end

  describe "blake3_hex/3" do
    test "matches the PUBLISHED BLAKE3 test vector for \"abc\"" do
      assert {:ok, @blake3_abc} = WasmexHost.blake3_hex("abc", :graphlaw_wasm_test)
    end

    test "matches the published BLAKE3 digest of the empty input" do
      assert {:ok, @blake3_empty} = WasmexHost.blake3_hex("", :graphlaw_wasm_test)
    end
  end

  describe "run_hooks/4" do
    test "returns a real decoded verdict map" do
      assert {:ok, result} = WasmexHost.run_hooks(@base_ttl, @event_ttl, :graphlaw_wasm_test)
      assert result["status"] == "ADMITTED"
      assert result["verdicts"] == []
      assert result["receipts"] == []
      assert result["schedule"] == []
    end
  end

  describe "validate_all/7" do
    test "runs every dialect and reports per-dialect status plus the graph hash" do
      assert {:ok, result} =
               WasmexHost.validate_all(@base_ttl, "", "", "", "", :graphlaw_wasm_test)

      assert result["graph_hash"] == @base_digest

      statuses =
        Map.new(result["dialects"], fn d -> {d["dialect"], d["status"]} end)

      assert statuses["DATALOG"] == "ADMITTED"
      assert statuses["N3_DENIAL"] == "ADMITTED"
      assert statuses["SHACL"] == "UNSUPPORTED"
      assert statuses["SHEX"] == "UNSUPPORTED"
      assert statuses["OWL_RL"] == "PROFILE_NOT_ADMITTED"

      # The engine's own self-replay check: hashing the same graph twice
      # inside one call must agree.
      assert result["replay"]["status"] == "ADMITTED"
      assert result["replay"]["first_hash"] == result["replay"]["second_hash"]
      assert result["hash_algorithms"] == %{"BLAKE3" => "1.0"}
    end

    test "ADMITS a graph that satisfies real SHACL shapes" do
      assert {:ok, result} =
               WasmexHost.validate_all(@base_ttl, "", @shacl_shapes, "", "", :graphlaw_wasm_test)

      shacl = Enum.find(result["dialects"], &(&1["dialect"] == "SHACL"))
      assert shacl["status"] == "ADMITTED"
      assert shacl["detail"] =~ "0 violations"
    end

    test "REFUSES an unparseable SHACL shapes graph, with a real parser diagnostic" do
      assert {:ok, result} =
               WasmexHost.validate_all(
                 @base_ttl,
                 "",
                 "!!!not shacl!!!",
                 "",
                 "",
                 :graphlaw_wasm_test
               )

      shacl = Enum.find(result["dialects"], &(&1["dialect"] == "SHACL"))

      # {:ok, _} means "the engine ran", not "everything validated" -- the
      # refusal is a per-dialect verdict INSIDE the result, by design.
      assert shacl["status"] == "REFUSED"
      assert shacl["detail"] =~ "Parsing error"

      # Other dialects are unaffected by one dialect's refusal.
      assert result["graph_hash"] == @base_digest
    end
  end

  describe "malformed input does not crash or poison the instance" do
    test "graph_hash/3 on garbage Turtle returns a value, and the instance still works" do
      # MEASURED REALITY, not an assumption: `graph_hash` is LENIENT.
      # `praxis-graphlaw-wasm/src/core.rs`'s `graph_hash_core_impl/1` has no
      # fallible parse step -- its only Err is an engine panic caught by its
      # own `catch_unwind`. So malformed Turtle silently degrades to the
      # subset that parsed (possibly the empty graph) rather than erroring.
      # This test asserts the behavior that actually exists; it does not
      # pretend an error path fires here.
      assert {:ok, garbage_digest} =
               WasmexHost.graph_hash("this is not turtle @@@ <<<", :graphlaw_wasm_test)

      assert garbage_digest =~ ~r/\A[0-9a-f]{64}\z/

      # A truncated statement drops to the EMPTY graph, whose canonical
      # digest is BLAKE3's published empty-input vector.
      assert {:ok, @blake3_empty} =
               WasmexHost.graph_hash("@prefix ex: <http://e/> .\nex:a ex:p", :graphlaw_wasm_test)

      # The instance is NOT poisoned: the same engine still produces the
      # exact cross-runtime digest afterwards.
      assert {:ok, @base_digest} = WasmexHost.graph_hash(@base_ttl, :graphlaw_wasm_test)
      assert {:ok, "praxis-graphlaw v26.7.5"} = WasmexHost.version(:graphlaw_wasm_test)
    end

    test "run_hooks/4 survives garbage on both inputs and the instance stays usable" do
      assert {:ok, result} = WasmexHost.run_hooks("!!!", "!!!", :graphlaw_wasm_test)
      assert is_map(result)
      assert {:ok, @base_digest} = WasmexHost.graph_hash(@base_ttl, :graphlaw_wasm_test)
    end

    test "a long sequence of mixed good/bad inputs leaves the instance correct" do
      inputs = [
        @base_ttl,
        "!!!!",
        @changed_ttl,
        "",
        @reordered_ttl,
        "<not a valid iri> <p> <o> .",
        @base_ttl
      ]

      results =
        Enum.map(inputs, fn ttl ->
          assert {:ok, digest} = WasmexHost.graph_hash(ttl, :graphlaw_wasm_test)
          digest
        end)

      assert List.first(results) == @base_digest
      assert List.last(results) == @base_digest
      assert Enum.at(results, 2) == @changed_digest
      assert Enum.at(results, 4) == @base_digest
    end
  end

  describe "concurrency -- one shared instance, many real BEAM processes" do
    test "concurrent callers each get the correct digest (serialized transactions)" do
      # If the multi-step wasm-bindgen ABI transaction were NOT serialized,
      # concurrent callers would interleave shadow-stack claims and read
      # each other's return slots. This asserts real state (every digest
      # correct), not "was a lock taken".
      cases = [
        {@base_ttl, @base_digest},
        {@reordered_ttl, @base_digest},
        {@changed_ttl, @changed_digest}
      ]

      results =
        1..40
        |> Task.async_stream(
          fn i ->
            {ttl, expected} = Enum.at(cases, rem(i, 3))
            {:ok, digest} = WasmexHost.graph_hash(ttl, :graphlaw_wasm_test)
            digest == expected
          end,
          max_concurrency: 20,
          timeout: 60_000
        )
        |> Enum.map(fn {:ok, ok?} -> ok? end)

      assert length(results) == 40
      assert Enum.all?(results), "concurrent ABI transactions corrupted each other"
    end
  end

  describe "encoding guard -- non-UTF-8 input never reaches the engine" do
    # CONFIRMED DEFECT, real repro (this session, before this fix):
    # `WasmexHost.graph_hash(<<0xFF>>)` committed 2,148,270,080 bytes of the
    # engine's linear memory in ONE call and PERMANENTLY POISONED the
    # instance -- a second call on the poisoned instance committed a
    # further 1,073,807,360 bytes. `ensure_utf8/1` must stop every public
    # function below before any wasm transaction, so memory must not grow
    # at all across these calls, and the instance must keep serving real
    # requests afterward.
    @invalid <<0xFF>>

    test "ensure_utf8/1 itself: valid input is :ok, invalid names the real first offset" do
      assert WasmexHost.ensure_utf8("ok") == :ok
      assert WasmexHost.ensure_utf8(@base_ttl) == :ok
      assert WasmexHost.ensure_utf8(@invalid) == {:error, {:invalid_encoding, 0}}
      assert WasmexHost.ensure_utf8(<<"ok", 0xFF>>) == {:error, {:invalid_encoding, 2}}
    end

    test "graph_hash/3 rejects non-UTF-8 input without committing any engine memory" do
      assert {:ok, before} = WasmexHost.memory_size(:graphlaw_wasm_test)

      assert {:error, {:invalid_encoding, 0}} =
               WasmexHost.graph_hash(@invalid, :graphlaw_wasm_test)

      assert {:ok, after_bytes} = WasmexHost.memory_size(:graphlaw_wasm_test)

      assert after_bytes == before,
             "engine memory grew from #{before} to #{after_bytes} bytes -- " <>
               "the guard let a non-UTF-8 call reach the wasm instance"

      # The instance is not poisoned: it still serves the real, previously
      # measured cross-runtime digest.
      assert {:ok, @base_digest} = WasmexHost.graph_hash(@base_ttl, :graphlaw_wasm_test)
    end

    test "blake3_hex/3 rejects non-UTF-8 input without committing any engine memory" do
      assert {:ok, before} = WasmexHost.memory_size(:graphlaw_wasm_test)

      assert {:error, {:invalid_encoding, 0}} =
               WasmexHost.blake3_hex(@invalid, :graphlaw_wasm_test)

      assert {:ok, after_bytes} = WasmexHost.memory_size(:graphlaw_wasm_test)

      assert after_bytes == before,
             "engine memory grew from #{before} to #{after_bytes} bytes -- " <>
               "the guard let a non-UTF-8 call reach the wasm instance"

      assert {:ok, @blake3_abc} = WasmexHost.blake3_hex("abc", :graphlaw_wasm_test)
    end

    test "run_hooks/4 rejects non-UTF-8 input on either argument without committing any engine memory" do
      assert {:ok, before} = WasmexHost.memory_size(:graphlaw_wasm_test)

      assert {:error, {:invalid_encoding, 0}} =
               WasmexHost.run_hooks(@invalid, @event_ttl, :graphlaw_wasm_test)

      assert {:error, {:invalid_encoding, 0}} =
               WasmexHost.run_hooks(@base_ttl, @invalid, :graphlaw_wasm_test)

      assert {:ok, after_bytes} = WasmexHost.memory_size(:graphlaw_wasm_test)

      assert after_bytes == before,
             "engine memory grew from #{before} to #{after_bytes} bytes -- " <>
               "the guard let a non-UTF-8 call reach the wasm instance"

      assert {:ok, result} = WasmexHost.run_hooks(@base_ttl, @event_ttl, :graphlaw_wasm_test)
      assert result["status"] == "ADMITTED"
    end

    test "validate_all/7 rejects non-UTF-8 input on any of its five arguments without committing any engine memory" do
      assert {:ok, before} = WasmexHost.memory_size(:graphlaw_wasm_test)

      assert {:error, {:invalid_encoding, 0}} =
               WasmexHost.validate_all(@invalid, "", "", "", "", :graphlaw_wasm_test)

      assert {:error, {:invalid_encoding, 0}} =
               WasmexHost.validate_all(@base_ttl, "", "", "", @invalid, :graphlaw_wasm_test)

      assert {:ok, after_bytes} = WasmexHost.memory_size(:graphlaw_wasm_test)

      assert after_bytes == before,
             "engine memory grew from #{before} to #{after_bytes} bytes -- " <>
               "the guard let a non-UTF-8 call reach the wasm instance"

      assert {:ok, result} =
               WasmexHost.validate_all(@base_ttl, "", "", "", "", :graphlaw_wasm_test)

      assert result["graph_hash"] == @base_digest
    end
  end

  describe "graceful degradation when the artifact is absent" do
    test "starts anyway and returns a typed error on every call" do
      missing =
        Path.join(
          System.tmp_dir!(),
          "definitely_not_a_wasm_#{System.unique_integer([:positive])}.wasm"
        )

      refute File.exists?(missing)

      {:ok, _pid} =
        start_supervised(
          {WasmexHost, name: :graphlaw_wasm_absent_test, wasm_path: missing},
          id: :graphlaw_absent
        )

      # The process is alive -- a missing native artifact does not take down
      # the supervision tree (same convention as HddlSolver's missing binary).
      assert Process.whereis(:graphlaw_wasm_absent_test) |> Process.alive?()
      refute WasmexHost.available?(:graphlaw_wasm_absent_test)

      assert {:error, %{code: :graphlaw_wasm_not_vendored, path: ^missing}} =
               WasmexHost.version(:graphlaw_wasm_absent_test)

      assert {:error, %{code: :graphlaw_wasm_not_vendored}} =
               WasmexHost.graph_hash(@base_ttl, :graphlaw_wasm_absent_test)

      assert {:error, %{code: :graphlaw_wasm_not_vendored}} =
               WasmexHost.validate_all(@base_ttl, "", "", "", "", :graphlaw_wasm_absent_test)
    end

    test "calling an unstarted instance is a typed error, not an exit" do
      assert {:error, %{code: :graphlaw_not_started}} =
               WasmexHost.graph_hash(@base_ttl, :graphlaw_wasm_definitely_not_started)
    end
  end

  describe "the loaded instance reports itself available" do
    test "available?/1 is true for the real loaded engine" do
      assert WasmexHost.available?(:graphlaw_wasm_test)
    end
  end
end
