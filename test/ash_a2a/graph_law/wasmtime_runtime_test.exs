defmodule AshA2A.GraphLaw.WasmtimeRuntimeTest do
  @moduledoc """
  Real, non-mocked exercise of `AshA2A.GraphLaw.WasmtimeRuntime`, the native
  Wasmtime host: every assertion below is on a value that came back from a
  real OS subprocess (`native/graphlaw_host`) that really compiled and ran
  `priv/graphlaw/praxis_graphlaw.wasm` under Wasmtime.

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
  alias AshA2A.GraphLaw.{Runtime, RuntimeB, WasmexSession, WasmtimeRuntime}

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
      assert {:ok, @vendored_wasm_sha256} = WasmtimeRuntime.wasm_digest()
    end

    test "a missing native binary is a typed refusal, not a crash" do
      assert {:error, error} =
               WasmtimeRuntime.graph_hash(@base, binary_path: "/nonexistent/graphlaw_host")

      assert error.code == :graphlaw_host_not_built
      assert error.path == "/nonexistent/graphlaw_host"
      assert error.message =~ "cargo build --release"
    end

    test "a missing wasm artifact is a typed refusal, not a crash" do
      # `/bin/sh` really exists, so the binary check passes and the wasm check
      # is the one that fires -- and no subprocess is ever spawned, because the
      # refusal happens before that.
      assert {:error, error} =
               WasmtimeRuntime.graph_hash(@base,
                 binary_path: "/bin/sh",
                 wasm_path: "/nonexistent/graphlaw.wasm"
               )

      assert error.code == :graphlaw_wasm_missing
    end

    test "available?/1 reports real on-disk state as the Runtime behaviour shape" do
      assert {:error, %{code: :graphlaw_host_not_built}} =
               WasmtimeRuntime.available?(binary_path: "/nonexistent/graphlaw_host")

      assert {:error, %{code: :graphlaw_wasm_missing}} =
               WasmtimeRuntime.available?(
                 binary_path: "/bin/sh",
                 wasm_path: "/nonexistent/graphlaw.wasm"
               )
    end
  end

  describe "AshA2A.GraphLaw.Runtime identity (no subprocess)" do
    test "declares the Runtime behaviour" do
      behaviours = WasmtimeRuntime.module_info(:attributes) |> Keyword.get_values(:behaviour)
      assert Runtime in List.flatten(behaviours)
    end

    test "is a distinct {host_id, engine_id} from both court default runtimes" do
      assert Runtime.identity(WasmtimeRuntime) == {"Native/graphlaw_host", "wasmtime"}
      assert Runtime.identity(WasmtimeRuntime) != Runtime.identity(WasmexSession)
      assert Runtime.identity(WasmtimeRuntime) != Runtime.identity(RuntimeB)
    end

    test "open/1 over an unbuilt host is the typed refusal, not a session" do
      assert {:error, %{code: :graphlaw_host_not_built}} =
               WasmtimeRuntime.open(binary_path: "/nonexistent/graphlaw_host")
    end
  end

  if AshA2A.GraphLaw.WasmtimeRuntime.available?() == :ok do
    describe "AshA2A.GraphLaw.Runtime callbacks over the native host" do
      test "open/call/close drive the real host and return verbatim wasm strings" do
        assert {:ok, %{session: session, wasm_digest: digest}} = WasmtimeRuntime.open()

        try do
          # The host-reported digest of the bytes it compiled, equal to the
          # BEAM's own digest of the same file via the behaviour's helper.
          assert digest == @vendored_wasm_sha256
          assert digest == Runtime.bytes_digest(File.read!(WasmtimeRuntime.wasm_path()))

          assert {:ok, version} = WasmtimeRuntime.call(session, :graphlaw_version, [])
          assert version =~ "praxis-graphlaw v"
          assert {:ok, @base_hash} = WasmtimeRuntime.call(session, :graph_hash, [@base])
          assert {:ok, @blake3_abc} = WasmtimeRuntime.call(session, :blake3_hex, ["abc"])
        after
          assert :ok = WasmtimeRuntime.close(session)
        end
      end

      test "call/3 refuses a wrong arity and an unknown function with typed errors" do
        assert {:ok, %{session: session}} = WasmtimeRuntime.open()

        assert {:error, %{code: :graphlaw_arity_mismatch, expected: 1, got: 0}} =
                 WasmtimeRuntime.call(session, :graph_hash, [])

        assert {:error, %{code: :graphlaw_unsupported_function, function: :no_such_function}} =
                 WasmtimeRuntime.call(session, :no_such_function, [])

        assert :ok = WasmtimeRuntime.close(session)
      end

      test "a session replays its call sequence, so instance-state-dependent answers match" do
        # v006's blank-node graph_hash depends on the wasm instance's state, not
        # only on the graph: one live instance answers a deterministic sequence
        # of different digests. A session must reproduce that sequence, not the
        # first digest every time (which is what a fresh instance per call gives).
        # This pins the same open praxis-graphlaw v26.7.5 defect that
        # test/ash_a2a/sa2a_conformance_test.exs pins; update both together.
        [v006] = v006_vectors()
        assert {:ok, %{session: session}} = WasmtimeRuntime.open()

        sequence =
          try do
            for _ <- 1..3 do
              assert {:ok, digest} = WasmtimeRuntime.call(session, :graph_hash, [v006.base])
              digest
            end
          after
            WasmtimeRuntime.close(session)
          end

        assert {:ok, fresh} = WasmtimeRuntime.graph_hash(v006.base)
        assert hd(sequence) == fresh.value
        assert length(Enum.uniq(sequence)) > 1

        # The same three calls issued in ONE real host process, independently.
        assert {:ok, batch} =
                 WasmtimeRuntime.batch(List.duplicate({"graph_hash", [v006.base]}, 3))

        assert sequence == Enum.map(batch.results, fn {:ok, r} -> r.value end)
      end

      test "the SA2A court accepts it as a runtime and it agrees with the in-BEAM host" do
        wasm = WasmtimeRuntime.wasm_path()

        case WasmexSession.available?(wasm_path: wasm) do
          :ok ->
            # One-vector corpus (the instance-state-dependent v006) copied from
            # the real corpus, so the court runs in seconds rather than a minute.
            dir =
              Path.join(System.tmp_dir!(), "sa2a_wasmtime_#{System.unique_integer([:positive])}")

            File.mkdir_p!(dir)

            try do
              File.cp_r!(
                Path.join(AshA2A.SA2A.Vector.corpus_dir(), "v006_blank_nodes"),
                Path.join(dir, "v006_blank_nodes")
              )

              assert {:error, %{"assertions" => assertions} = receipt} =
                       AshA2A.SA2A.Conformance.run(
                         runtime_a: WasmexSession,
                         runtime_b: WasmtimeRuntime,
                         wasm_path: wasm,
                         corpus_dir: dir
                       )

              assert receipt["runtime_a"]["wasm_digest"] == @vendored_wasm_sha256
              assert receipt["runtime_b"]["wasm_digest"] == @vendored_wasm_sha256

              for name <-
                    ~w(same_wasm same_admission same_output_semantics same_evidence_identity) do
                assert assertions[name]["computed"], "#{name} not computed"
                assert assertions[name]["value"], "#{name} diverged: #{inspect(assertions[name])}"
              end

              # The open v006 falsifier fires identically in both hosts: the
              # unstable digests agree digit-for-digit across the two runtimes.
              identity = assertions["same_input_identity"]
              assert identity["computed"]
              refute identity["value"]

              by_runtime = Map.new(identity["divergences"], &{&1["runtime"], &1})

              assert Map.keys(by_runtime) |> Enum.sort() == [
                       "BEAM/Wasmex",
                       "Native/graphlaw_host"
                     ]

              assert Map.take(by_runtime["BEAM/Wasmex"], ["first", "repeat"]) ==
                       Map.take(by_runtime["Native/graphlaw_host"], ["first", "repeat"])
            after
              File.rm_rf!(dir)
            end

          {:error, reason} ->
            IO.puts("skipped: in-BEAM runtime unavailable: #{inspect(reason)}")
        end
      end

      test "the SA2A court refuses a relabelled native host before any vector runs (S126)" do
        # Both delegates really open, call and close the real native host; only
        # their caller-controlled labels differ. A whitespace-only relabel is
        # refused on the normalized label, an entirely different label on the
        # identity observed from the open sessions (the same session resource
        # is started by WasmtimeRuntime itself, whatever the module says).
        assert {:error, padded} =
                 AshA2A.SA2A.Conformance.run(
                   runtime_a: WasmtimeRuntime,
                   runtime_b: __MODULE__.PaddedNativeRuntime
                 )

        assert padded.code == :sa2a_identical_runtimes
        assert padded.basis == :label

        assert Runtime.identity(__MODULE__.PaddedNativeRuntime) !=
                 Runtime.identity(WasmtimeRuntime)

        assert {:error, relabelled} =
                 AshA2A.SA2A.Conformance.run(
                   runtime_a: WasmtimeRuntime,
                   runtime_b: __MODULE__.RelabelledNativeRuntime
                 )

        assert relabelled.code == :sa2a_identical_runtimes
        assert relabelled.basis == :observed_executable

        assert [%{"engine_module" => "AshA2A.GraphLaw.WasmtimeRuntime"}] =
                 relabelled.observed_identity
      end
    end

    describe "the native host executes the vendored artifact under Wasmtime" do
      test "reports the engine version out of the wasm itself" do
        assert {:ok, result} = WasmtimeRuntime.graphlaw_version()
        assert result.value =~ "praxis-graphlaw"
        assert result.runtime == "wasmtime"
      end

      test "every result carries cross-checked artifact identity" do
        assert {:ok, result} = WasmtimeRuntime.graph_hash(@base)
        assert {:ok, expected} = WasmtimeRuntime.wasm_digest()

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
        assert {:ok, %{value: @base_hash}} = WasmtimeRuntime.graph_hash(@base)
      end

      test "graph_hash/2 is invariant to prefix label and triple order" do
        assert {:ok, %{value: base}} = WasmtimeRuntime.graph_hash(@base)
        assert {:ok, %{value: reordered}} = WasmtimeRuntime.graph_hash(@reordered)

        assert base == reordered
        assert base == @base_hash
      end

      test "graph_hash/2 separates a graph that differs by one term" do
        assert {:ok, %{value: base}} = WasmtimeRuntime.graph_hash(@base)
        assert {:ok, %{value: different}} = WasmtimeRuntime.graph_hash(@different)

        refute base == different
        assert different == @different_hash
      end

      test "blake3_hex/2 reproduces the published BLAKE3 vector for \"abc\"" do
        assert {:ok, %{value: @blake3_abc}} = WasmtimeRuntime.blake3_hex("abc")
      end

      test "run_hooks/3 returns the real admission JSON from the engine" do
        event = """
        @prefix ex: <http://example.org/> .
        ex:c ex:p ex:d .
        """

        assert {:ok, result} = WasmtimeRuntime.run_hooks(@base, event)
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

        assert {:ok, batch} = WasmtimeRuntime.batch(jobs)
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
                 WasmtimeRuntime.batch([
                   {"graph_hash", [@base]},
                   {"no_such_function", []}
                 ])

        assert [{:ok, %{value: @base_hash}}, {:error, bad}] = batch.results
        assert bad.code == :unsupported_fn
        assert bad.message =~ "no_such_function"
      end

      test "wrong arity is refused by the host rather than trapping the module" do
        assert {:ok, batch} = WasmtimeRuntime.batch([{"graph_hash", []}])
        assert [{:error, bad}] = batch.results
        assert bad.code == :bad_arity
      end
    end

    describe "the finite conformance suite, driven from priv/graphlaw/conformance_vectors.json" do
      test "every recorded vector reproduces exactly under the native Wasmtime host" do
        assert {:ok, doc} = ConformanceVectors.load()
        assert {:ok, jobs} = ConformanceVectors.jobs()
        assert {:ok, batch} = WasmtimeRuntime.batch(jobs)

        # Same artifact the expectations were recorded against -- otherwise
        # agreement would prove nothing about host independence.
        assert batch.wasm_sha256 == doc["wasm_sha256"]
        assert batch.wasm_bytes == doc["wasm_bytes"]

        pairs = Enum.zip(doc["vectors"], batch.results)
        assert length(pairs) == length(doc["vectors"])

        for {vector, result} <- pairs do
          assert {:ok, %{value: value}} = result

          assert value == vector["expect"],
                 "vector #{vector["id"]} diverged under WasmtimeRuntime"
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
          assert {:ok, %{value: value}} = WasmtimeRuntime.graph_hash(junk)
          # A 64-char lowercase hex digest, not an `{"error": ...}` object.
          assert value =~ ~r/\A[0-9a-f]{64}\z/, "unexpected result for #{inspect(junk)}"
        end
      end

      test "input the parser recovers nothing from yields the empty-graph digest" do
        for empty_equivalent <- ["@@@ bad", "<http://a> <http://b"] do
          assert {:ok, %{value: @empty_graph_hash}} = WasmtimeRuntime.graph_hash(empty_equivalent)
        end
      end

      test "a lenient parse is still deterministic across separate host processes" do
        junk = "this is not turtle <<<"
        assert {:ok, %{value: first}} = WasmtimeRuntime.graph_hash(junk)
        assert {:ok, %{value: second}} = WasmtimeRuntime.graph_hash(junk)

        # Two independent subprocesses, two independent wasm instantiations.
        assert first == second
        refute first == @empty_graph_hash
      end

      test "the empty-graph digest is BLAKE3 of the empty canonical N-Quads form" do
        assert {:ok, %{value: @empty_graph_hash}} = WasmtimeRuntime.graph_hash("")
        assert {:ok, %{value: @empty_graph_hash}} = WasmtimeRuntime.blake3_hex("")
      end

      test "a non-wasm file is refused at compile time with artifact identity intact" do
        path =
          Path.join(System.tmp_dir!(), "ash_a2a_not_a_wasm_#{System.unique_integer([:positive])}")

        File.write!(path, "definitely not webassembly")

        try do
          assert {:error, error} = WasmtimeRuntime.graph_hash(@base, wasm_path: path)
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
                 WasmtimeRuntime.graph_hash(@base, timeout: 1)
      end
    end

    defp v006_vectors do
      {:ok, vectors} = AshA2A.SA2A.Vector.load_all()
      Enum.filter(vectors, &(&1.id == "v006_blank_nodes"))
    end
  else
    test "SKIPPED: graphlaw_host is not built, so WasmtimeRuntime was not executed" do
      IO.warn("""
      WasmtimeRuntime wasm-execution tests were SKIPPED because the native host is \
      not built at #{WasmtimeRuntime.binary_path()}.

      These tests are never replaced by a mock or a stub. Build the real host \
      and re-run:

          cd native/graphlaw_host && cargo build --release
      """)

      assert {:error, %{code: :graphlaw_host_not_built}} = WasmtimeRuntime.available?()
    end
  end

  defmodule PaddedNativeRuntime do
    @moduledoc """
    A real runtime that IS `AshA2A.GraphLaw.WasmtimeRuntime` (every call runs
    the real native host) whose host id carries one trailing space -- the
    one-space relabel RFC-SA2A-002 S126 refuses. Records no interaction.
    """
    @behaviour AshA2A.GraphLaw.Runtime
    alias AshA2A.GraphLaw.WasmtimeRuntime

    @impl true
    def host_id, do: WasmtimeRuntime.host_id() <> " "
    @impl true
    def engine_id, do: WasmtimeRuntime.engine_id()
    @impl true
    def available?(opts \\ []), do: WasmtimeRuntime.available?(opts)
    @impl true
    def open(opts \\ []), do: WasmtimeRuntime.open(opts)
    @impl true
    def call(session, fun, args), do: WasmtimeRuntime.call(session, fun, args)
    @impl true
    def close(session), do: WasmtimeRuntime.close(session)
  end

  defmodule RelabelledNativeRuntime do
    @moduledoc """
    A real runtime that IS `AshA2A.GraphLaw.WasmtimeRuntime` under entirely
    different caller-controlled labels (`"WASI/StandaloneHost"`, `"wasm3"`).
    Only identity observed from the open session (S126) tells it apart.
    """
    @behaviour AshA2A.GraphLaw.Runtime
    alias AshA2A.GraphLaw.WasmtimeRuntime

    @impl true
    def host_id, do: "WASI/StandaloneHost"
    @impl true
    def engine_id, do: "wasm3"
    @impl true
    def available?(opts \\ []), do: WasmtimeRuntime.available?(opts)
    @impl true
    def open(opts \\ []), do: WasmtimeRuntime.open(opts)
    @impl true
    def call(session, fun, args), do: WasmtimeRuntime.call(session, fun, args)
    @impl true
    def close(session), do: WasmtimeRuntime.close(session)
  end
end
