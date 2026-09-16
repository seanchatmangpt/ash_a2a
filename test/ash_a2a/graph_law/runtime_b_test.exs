defmodule AshA2A.GraphLaw.RuntimeBTest do
  @moduledoc """
  Real, non-mocked exercise of Runtime B: every assertion below is on a value
  that came back from a real OS subprocess (`native/graphlaw_host`) that really
  compiled and ran `priv/graphlaw/praxis_graphlaw_wasm.wasm` under Wasmtime.

  There is no test double anywhere in this file. No wasm result is
  hand-constructed, no collaborator is stubbed, and nothing asserts "was X
  called" -- the assertions are on real returned digests, real JSON, and real
  typed errors.

  The expected digests are not this test's invention either: they are the
  values the same artifact produces under a *different* host (a hand-written
  JavaScript shim over `WebAssembly.instantiate` in Node), recorded as the
  conformance vectors for RFC-SA2A-001 S12/S51. That is the whole experiment:
  same bytes, different host, same answers.

  When `native/graphlaw_host/target/release/graphlaw_host` has not been built
  the wasm-executing tests are **skipped by name and loudly**, never silently
  replaced by a double. Build it with:

      cd native/graphlaw_host && cargo build --release
  """

  use ExUnit.Case, async: false

  alias AshA2A.GraphLaw.ConformanceVectors
  alias AshA2A.GraphLaw.RuntimeB

  # --- Conformance vectors (RFC-SA2A-001 S12 canonical graph identity) -------

  @base """
  @prefix ex: <http://example.org/> .
  ex:a ex:p ex:b .
  ex:b ex:p ex:c .
  """

  # Same graph, different prefix *label* and different triple *order*.
  # A canonicalizing hash must not be able to tell it apart from @base.
  @reordered """
  @prefix zz: <http://example.org/> .
  zz:b zz:p zz:c .
  zz:a zz:p zz:b .
  """

  # One object term changed: must hash differently.
  @different """
  @prefix ex: <http://example.org/> .
  ex:a ex:p ex:b .
  ex:b ex:p ex:ZZZ .
  """

  @base_hash "9b8180962a93910d17c51d029626f393d65ac2f724b9ffc657c90bc4f3b5939d"
  @different_hash "610ccbcd4ed4b23cf4179fde360625da286557d18a15403f76797e28c1c68f66"

  # The published BLAKE3 test vector for the input "abc".
  @blake3_abc "6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85"

  # The published BLAKE3 test vector for the *empty* input, which is also what
  # an empty graph's canonical N-Quads form hashes to.
  @empty_graph_hash "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"

  @vendored_wasm_sha256 "187688d9e7e33a575713d6911d75687adb38713ed37412e211af263dfcbe0c28"

  describe "path resolution and availability (no subprocess)" do
    test "wasm_digest/1 hashes the real vendored artifact on disk" do
      assert {:ok, @vendored_wasm_sha256} = RuntimeB.wasm_digest()
    end

    test "a missing native binary is a typed refusal, not a crash" do
      assert {:error, error} =
               RuntimeB.graph_hash(@base, binary_path: "/nonexistent/graphlaw_host")

      assert error.code == :graphlaw_host_not_built
      assert error.path == "/nonexistent/graphlaw_host"
      assert error.message =~ "cargo build --release"
    end

    test "a missing wasm artifact is a typed refusal, not a crash" do
      # `/bin/sh` really exists, so the binary check passes and the wasm check
      # is the one that fires -- and no subprocess is ever spawned, because the
      # refusal happens before that.
      assert {:error, error} =
               RuntimeB.graph_hash(@base,
                 binary_path: "/bin/sh",
                 wasm_path: "/nonexistent/graphlaw.wasm"
               )

      assert error.code == :graphlaw_wasm_missing
    end

    test "available?/1 reports real on-disk state" do
      refute RuntimeB.available?(binary_path: "/nonexistent/graphlaw_host")
    end
  end

  if AshA2A.GraphLaw.RuntimeB.available?() do
    describe "Runtime B executes the vendored artifact under Wasmtime" do
      test "reports the engine version out of the wasm itself" do
        assert {:ok, result} = RuntimeB.graphlaw_version()
        assert result.value =~ "praxis-graphlaw"
        assert result.runtime == "wasmtime"
      end

      test "every result carries cross-checked artifact identity" do
        assert {:ok, result} = RuntimeB.graph_hash(@base)
        assert {:ok, expected} = RuntimeB.wasm_digest()

        # The native host independently hashed the bytes it compiled; this
        # assertion is what turns `WASM_A = WASM_B` from an assumption into a
        # checked fact (falsifier #1).
        assert result.wasm_sha256 == expected
        assert result.wasm_sha256 == @vendored_wasm_sha256
        assert result.wasm_bytes == 3_249_361
        assert result.runtime == "wasmtime"
        assert is_binary(result.runtime_version)
        assert result.host =~ "graphlaw_host/"
      end

      test "graph_hash/2 reproduces the S12 canonical identity vector" do
        assert {:ok, %{value: @base_hash}} = RuntimeB.graph_hash(@base)
      end

      test "graph_hash/2 is invariant to prefix label and triple order" do
        assert {:ok, %{value: base}} = RuntimeB.graph_hash(@base)
        assert {:ok, %{value: reordered}} = RuntimeB.graph_hash(@reordered)

        assert base == reordered
        assert base == @base_hash
      end

      test "graph_hash/2 separates a graph that differs by one term" do
        assert {:ok, %{value: base}} = RuntimeB.graph_hash(@base)
        assert {:ok, %{value: different}} = RuntimeB.graph_hash(@different)

        refute base == different
        assert different == @different_hash
      end

      test "blake3_hex/2 reproduces the published BLAKE3 vector for \"abc\"" do
        assert {:ok, %{value: @blake3_abc}} = RuntimeB.blake3_hex("abc")
      end

      test "run_hooks/3 returns the real admission JSON from the engine" do
        event = """
        @prefix ex: <http://example.org/> .
        ex:c ex:p ex:d .
        """

        assert {:ok, result} = RuntimeB.run_hooks(@base, event)
        assert {:ok, decoded} = JSON.decode(result.value)
        assert decoded["status"] == "ADMITTED"
        assert is_list(decoded["verdicts"])
      end
    end

    describe "batch/2 (one subprocess, one wasm compile, many jobs)" do
      test "runs the whole conformance vector set in a single host process" do
        jobs = [
          {"graph_hash", [@base]},
          {"graph_hash", [@reordered]},
          {"graph_hash", [@different]},
          {"blake3_hex", ["abc"]}
        ]

        assert {:ok, batch} = RuntimeB.batch(jobs)
        assert batch.wasm_sha256 == @vendored_wasm_sha256

        assert [
                 {:ok, %{value: @base_hash}},
                 {:ok, %{value: @base_hash}},
                 {:ok, %{value: @different_hash}},
                 {:ok, %{value: @blake3_abc}}
               ] = batch.results
      end

      test "a bad job inside a batch is typed and does not poison its siblings" do
        assert {:ok, batch} =
                 RuntimeB.batch([
                   {"graph_hash", [@base]},
                   {"no_such_function", []}
                 ])

        assert [{:ok, %{value: @base_hash}}, {:error, bad}] = batch.results
        assert bad.code == :unsupported_fn
        assert bad.message =~ "no_such_function"
      end

      test "wrong arity is refused by the host rather than trapping the module" do
        assert {:ok, batch} = RuntimeB.batch([{"graph_hash", []}])
        assert [{:error, bad}] = batch.results
        assert bad.code == :bad_arity
      end
    end

    describe "the finite conformance suite, driven from priv/graphlaw/conformance_vectors.json" do
      test "every recorded vector reproduces exactly under Runtime B" do
        assert {:ok, doc} = ConformanceVectors.load()
        assert {:ok, jobs} = ConformanceVectors.jobs()
        assert {:ok, batch} = RuntimeB.batch(jobs)

        # Same artifact the expectations were recorded against -- otherwise
        # agreement would prove nothing about host independence.
        assert batch.wasm_sha256 == doc["wasm_sha256"]
        assert batch.wasm_bytes == doc["wasm_bytes"]

        pairs = Enum.zip(doc["vectors"], batch.results)
        assert length(pairs) == length(doc["vectors"])

        for {vector, result} <- pairs do
          assert {:ok, %{value: value}} = result
          assert value == vector["expect"], "vector #{vector["id"]} diverged under Runtime B"
        end
      end

      test "the suite really covers the S12 identity triple and both BLAKE3 vectors" do
        assert {:ok, vectors} = ConformanceVectors.vectors()
        ids = MapSet.new(vectors, & &1["id"])

        for required <- [
              "S12-canonical-base",
              "S12-prefix-label-and-order-invariance",
              "S12-one-term-changed",
              "blake3-abc"
            ] do
          assert MapSet.member?(ids, required), "conformance suite lost vector #{required}"
        end
      end

      test "a missing vector document is a typed refusal, not a crash" do
        assert {:error, %{code: :conformance_vectors_missing}} =
                 ConformanceVectors.load(vectors_path: "/nonexistent/vectors.json")
      end
    end

    describe "real failure modes" do
      # Measured, not assumed: this engine's `graph_hash` is *lenient*. Feeding
      # it malformed Turtle does NOT produce its `{"error": ...}` object -- it
      # produces the canonical hash of whatever triples it managed to parse,
      # which for wholly unparseable input is the empty graph. A caller cannot
      # use "did graph_hash error" as a syntax check; a conformance suite must
      # therefore pin this behaviour rather than assume strictness.
      test "malformed Turtle still hashes: `graph_hash` never reports a syntax error" do
        for junk <- ["this is not turtle <<<", "@@@ bad", "<http://a> <http://b"] do
          assert {:ok, %{value: value}} = RuntimeB.graph_hash(junk)
          # A 64-char lowercase hex digest, not an `{"error": ...}` object.
          assert value =~ ~r/\A[0-9a-f]{64}\z/, "unexpected result for #{inspect(junk)}"
        end
      end

      test "input the parser recovers nothing from yields the empty-graph digest" do
        for empty_equivalent <- ["@@@ bad", "<http://a> <http://b"] do
          assert {:ok, %{value: @empty_graph_hash}} = RuntimeB.graph_hash(empty_equivalent)
        end
      end

      test "a lenient parse is still deterministic across separate host processes" do
        junk = "this is not turtle <<<"
        assert {:ok, %{value: first}} = RuntimeB.graph_hash(junk)
        assert {:ok, %{value: second}} = RuntimeB.graph_hash(junk)

        # Two independent subprocesses, two independent wasm instantiations.
        assert first == second
        refute first == @empty_graph_hash
      end

      test "the empty-graph digest is BLAKE3 of the empty canonical N-Quads form" do
        assert {:ok, %{value: @empty_graph_hash}} = RuntimeB.graph_hash("")
        assert {:ok, %{value: @empty_graph_hash}} = RuntimeB.blake3_hex("")
      end

      test "a non-wasm file is refused at compile time with artifact identity intact" do
        path =
          Path.join(System.tmp_dir!(), "ash_a2a_not_a_wasm_#{System.unique_integer([:positive])}")

        File.write!(path, "definitely not webassembly")

        try do
          assert {:error, error} = RuntimeB.graph_hash(@base, wasm_path: path)
          assert error.code == :wasm_compile_failed
          # Identity is still reported for the (wrong) artifact: the host
          # hashes what it was handed before it tries to compile it.
          assert error.wasm_sha256 ==
                   Base.encode16(
                     :crypto.hash(:sha256, "definitely not webassembly"),
                     case: :lower
                   )
        after
          File.rm(path)
        end
      end

      test "a deadline that cannot be met kills the subprocess and returns :timeout" do
        # Compiling a 3.2 MB module is seconds-scale work; 1 ms cannot finish.
        assert {:error, %{code: :timeout, timeout_ms: 1}} =
                 RuntimeB.graph_hash(@base, timeout: 1)
      end
    end
  else
    test "SKIPPED: graphlaw_host is not built, so Runtime B was not executed" do
      IO.warn("""
      Runtime B wasm-execution tests were SKIPPED because the native host is \
      not built at #{RuntimeB.binary_path()}.

      These tests are never replaced by a mock or a stub. Build the real host \
      and re-run:

          cd native/graphlaw_host && cargo build --release
      """)

      refute RuntimeB.available?()
    end
  end
end
