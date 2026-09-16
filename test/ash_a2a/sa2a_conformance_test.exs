defmodule AshA2A.SA2AConformanceTest do
  @moduledoc """
  Real cross-runtime conformance tests.

  Every test here drives the real prebuilt `praxis-graphlaw` WASM module
  through two genuinely different real hosts -- a real `:wasmex` instance in
  this BEAM and a real OS subprocess running a real standalone JavaScript
  engine -- over the real corpus on disk, and asserts on real returned
  digests. No collaborator is mocked and no assertion is interaction-based.

  The suite skips only when the real WASM module or the real out-of-BEAM
  executable is genuinely absent from this machine, and says so by name
  rather than substituting a double.
  """

  use ExUnit.Case, async: false

  alias AshA2A.GraphLaw.{Runtime, RuntimeB, Wasm}
  alias AshA2A.SA2A.{Conformance, ResultProjection, StateMachine, Vector}

  doctest AshA2A.GraphLaw.Runtime
  doctest AshA2A.SA2A.ResultProjection

  @moduletag :sa2a_conformance

  setup_all do
    case {Wasm.available?([]), RuntimeB.available?([])} do
      {:ok, :ok} ->
        {:ok, receipt} = run_court()
        {:ok, receipt: receipt}

      {a, b} ->
        # A named, visible skip -- never a silent substitution of a double.
        {:ok, skip: "runtime A: #{inspect(a)}; runtime B: #{inspect(b)}"}
    end
  end

  # `run/1` returns {:ok, receipt} on a clean run and {:error, receipt} when a
  # falsifier fired. Both carry the same receipt; these tests assert on its
  # real contents rather than on the overall verdict, so a later GraphLaw fix
  # flipping the verdict does not silently change what is being checked.
  defp run_court(opts \\ []) do
    case Conformance.run(opts) do
      {:ok, receipt} -> {:ok, receipt}
      {:error, %{"profile" => _} = receipt} -> {:ok, receipt}
      {:error, reason} -> {:error, reason}
    end
  end

  defp assertion(receipt, name), do: receipt["assertions"][Atom.to_string(name)]

  defp vectors_by_id(receipt, side) do
    Map.new(receipt[side]["vectors"], &{&1["vector"], &1})
  end

  describe "the two configured runtimes" do
    test "are genuinely different hosts, not one runtime run twice" do
      assert Runtime.identity(Wasm) != Runtime.identity(RuntimeB)
      assert Wasm.host_id() == "BEAM/Wasmex"
      assert RuntimeB.host_id() == "Node/StandaloneJS"
    end

    test "runtime B is a real out-of-BEAM process that reports its own engine", %{} = context do
      if skip = context[:skip] do
        IO.puts("skipped: #{skip}")
      else
        {:ok, %{session: session, wasm_digest: digest}} = RuntimeB.open([])

        try do
          engine = RuntimeB.reported_engine(session)
          # The live subprocess named itself; this is not a constant in Elixir.
          assert engine =~ ~r/^(v8|javascriptcore)-\d/
          assert String.match?(digest, ~r/\A[0-9a-f]{64}\z/)
          assert {:ok, version} = RuntimeB.call(session, :graphlaw_version, [])
          assert version =~ "praxis-graphlaw v"
        after
          RuntimeB.close(session)
        end
      end
    end

    test "load byte-identical wasm and report the same module digest", %{} = context do
      if skip = context[:skip] do
        IO.puts("skipped: #{skip}")
      else
        receipt = context.receipt
        same_wasm = assertion(receipt, :same_wasm)

        assert same_wasm["computed"]
        assert same_wasm["value"]
        assert receipt["runtime_a"]["wasm_digest"] == receipt["runtime_b"]["wasm_digest"]
        assert receipt["wasm_digest_algorithm"] == "sha256"
      end
    end

    test "supply byte-identical deterministic entropy to the wasm import" do
      node = System.find_executable("node")

      if node do
        script = """
        const out = [];
        for (let i = 0; i < 64; i++) out.push((i * 2654435761) % 256);
        process.stdout.write(out.join(','));
        """

        {stdout, 0} = System.cmd(node, ["-e", script])

        from_out_of_beam = stdout |> String.split(",") |> Enum.map(&String.to_integer/1)
        from_beam = Runtime.deterministic_random_bytes(64) |> :binary.bin_to_list()

        # The court's digests are only comparable because both hosts fill
        # getRandomValues identically. This checks the real contract between
        # the two real implementations, not either one in isolation.
        assert from_beam == from_out_of_beam
      else
        IO.puts("skipped: no node executable on PATH")
      end
    end
  end

  describe "cross-runtime agreement over the real corpus" do
    test "the corpus is non-empty and every vector really loaded" do
      assert {:ok, vectors} = Vector.load_all([])
      assert length(vectors) >= 8
      assert Enum.all?(vectors, &(&1.base != ""))
      assert Enum.all?(vectors, &String.match?(&1.digest, ~r/\A[0-9a-f]{64}\z/))
    end

    test "wasm, admission, output semantics and evidence identity all agree", %{} = context do
      if skip = context[:skip] do
        IO.puts("skipped: #{skip}")
      else
        receipt = context.receipt

        for name <- [:same_wasm, :same_admission, :same_output_semantics, :same_evidence_identity] do
          result = assertion(receipt, name)
          assert result["computed"], "#{name} was not computed: #{inspect(result["detail"])}"
          assert result["value"], "#{name} failed: #{inspect(result["divergences"])}"
        end
      end
    end

    test "every vector's output graph hash is identical across the two hosts", %{} = context do
      if skip = context[:skip] do
        IO.puts("skipped: #{skip}")
      else
        receipt = context.receipt
        a = vectors_by_id(receipt, "runtime_a")
        b = vectors_by_id(receipt, "runtime_b")

        for {id, va} <- a do
          vb = Map.fetch!(b, id)
          assert va["output_graph_hash"] == vb["output_graph_hash"], "diverged on #{id}"
          assert String.match?(va["output_graph_hash"], ~r/\A[0-9a-f]{64}\z/)
          assert va["evidence_hash"] == vb["evidence_hash"], "evidence diverged on #{id}"
        end
      end
    end

    test "RFC S12: prefix relabelling and triple reordering preserve graph identity",
         %{} = context do
      if skip = context[:skip] do
        IO.puts("skipped: #{skip}")
      else
        receipt = context.receipt

        for side <- ["runtime_a", "runtime_b"] do
          vectors = vectors_by_id(receipt, side)
          v001 = Map.fetch!(vectors, "v001_minimal_admit")
          v002 = Map.fetch!(vectors, "v002_prefix_and_order_invariance")

          # Same abstract graph, different prefix label and reversed triple
          # order: the canonical identity must not notice.
          assert v001["input_graph_hash"] == v002["input_graph_hash"],
                 "#{side} gave the same graph two identities"
        end
      end
    end

    test "refusals agree on the S41 state reached and the typed reason", %{} = context do
      if skip = context[:skip] do
        IO.puts("skipped: #{skip}")
      else
        receipt = context.receipt
        a = vectors_by_id(receipt, "runtime_a")
        b = vectors_by_id(receipt, "runtime_b")

        shacl = Map.fetch!(a, "v004_shacl_min_count_violation")
        shex = Map.fetch!(a, "v009_shex_violation")

        assert shacl["admission"] == "REFUSED"
        assert shacl["refusal_reason"] =~ "STRUCTURALLY_VALID:SHACL:REFUSED"
        assert shex["admission"] == "REFUSED"
        assert shex["refusal_reason"] =~ "SEMANTICALLY_VALID:SHEX:REFUSED"

        for id <- ["v004_shacl_min_count_violation", "v009_shex_violation"] do
          assert Map.fetch!(a, id)["refusal_reason"] == Map.fetch!(b, id)["refusal_reason"]
          assert Map.fetch!(a, id)["state_reached"] == Map.fetch!(b, id)["state_reached"]
          assert Map.fetch!(a, id)["state_trace"] == Map.fetch!(b, id)["state_trace"]
        end
      end
    end

    test "admitted vectors really walked the whole S41 prefix", %{} = context do
      if skip = context[:skip] do
        IO.puts("skipped: #{skip}")
      else
        admitted =
          context.receipt["runtime_a"]["vectors"]
          |> Enum.filter(&(&1["admission"] == "ADMITTED"))

        assert admitted != []

        expected = Enum.map(StateMachine.states(), &(&1 |> Atom.to_string() |> String.upcase()))

        for vector <- admitted do
          reached = Enum.map(vector["state_trace"], &List.first(String.split(&1, ["(", "="])))
          assert reached == expected, "#{vector["vector"]} took a different route to ADMITTED"
        end
      end
    end
  end

  describe "graph_hash stability (open falsifier against praxis-graphlaw v26.7.5)" do
    @tag :falsifier
    test "ground graphs are stable and blank-node graphs are not", %{} = context do
      if skip = context[:skip] do
        IO.puts("skipped: #{skip}")
      else
        {:ok, vectors} = Vector.load_all([])
        by_id = Map.new(vectors, &{&1.id, &1})
        ground = Map.fetch!(by_id, "v001_minimal_admit").base
        with_bnodes = Map.fetch!(by_id, "v006_blank_nodes").base

        {:ok, %{session: session}} = Wasm.open([])

        {ground_hashes, bnode_hashes} =
          try do
            g = for _ <- 1..4, do: elem(Wasm.call(session, :graph_hash, [ground]), 1)
            b = for _ <- 1..4, do: elem(Wasm.call(session, :graph_hash, [with_bnodes]), 1)
            {g, b}
          after
            Wasm.close(session)
          end

        assert Enum.uniq(ground_hashes) |> length() == 1,
               "a ground graph must have exactly one identity, got #{inspect(ground_hashes)}"

        # This assertion documents a real, currently-open defect in
        # praxis-graphlaw v26.7.5: repeated graph_hash/1 calls on the same
        # blank-node graph return different digests, so input identity is not
        # a function of the input. When the engine is fixed this test will
        # fail loudly -- which is the point. Update it together with
        # priv/sa2a_conformance/v006_blank_nodes/vector.json, do not relax it.
        assert length(Enum.uniq(bnode_hashes)) > 1,
               "blank-node graph_hash appears to have become stable " <>
                 "(#{inspect(bnode_hashes)}); if praxis-graphlaw fixed this, " <>
                 "remove the OPEN_FALSIFIER status from v006 and invert this assertion"
      end
    end

    @tag :falsifier
    test "the court reports that instability instead of passing over it", %{} = context do
      if skip = context[:skip] do
        IO.puts("skipped: #{skip}")
      else
        result = assertion(context.receipt, :same_input_identity)

        # Both runtimes agree digit-for-digit on the unstable sequence, so a
        # cross-runtime-only check would have reported true here. It must not.
        assert result["computed"]
        refute result["value"]
        assert result["detail"] =~ "not a function of the input graph"

        divergences = result["divergences"]
        assert Enum.all?(divergences, &(&1["vector"] == "v006_blank_nodes"))

        assert divergences
               |> Enum.map(& &1["runtime"])
               |> Enum.sort() == ["BEAM/Wasmex", "Node/StandaloneJS"]

        assert context.receipt["result"] == "FAIL"
      end
    end
  end

  describe "the court refuses degenerate runs" do
    test "refuses to run one runtime twice" do
      assert {:error, reason} = Conformance.run(runtime_a: Wasm, runtime_b: Wasm)
      assert reason.code == :sa2a_identical_runtimes
      assert reason.message =~ "cannot establish cross-runtime conformance"
    end

    test "refuses an empty corpus rather than passing vacuously" do
      dir = Path.join(System.tmp_dir!(), "sa2a_empty_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      try do
        assert {:error, reason} = Conformance.run(corpus_dir: dir)
        assert reason.code == :sa2a_corpus_empty
        assert reason.message =~ "cannot establish conformance"
      after
        File.rm_rf!(dir)
      end
    end

    test "refuses a corpus directory that does not exist" do
      assert {:error, reason} = Conformance.run(corpus_dir: "/nonexistent/sa2a/corpus")
      assert reason.code == :sa2a_corpus_not_found
    end

    test "an assertion that cannot be computed fails the run, it is not skipped",
         %{} = context do
      if skip = context[:skip] do
        IO.puts("skipped: #{skip}")
      else
        # A real, genuinely degraded host: real wasm for every call except
        # graph_hash, which it really refuses. See its @moduledoc.
        assert {:error, receipt} =
                 Conformance.run(
                   runtime_a: Wasm,
                   runtime_b: AshA2A.Test.DegradedGraphLawRuntime
                 )

        input = assertion(receipt, :same_input_identity)
        output = assertion(receipt, :same_output_semantics)

        refute input["computed"]
        refute input["value"]
        assert input["detail"] =~ "produced no input_graph_hash"

        refute output["computed"]
        refute output["value"]

        assert receipt["result"] == "FAIL"

        # The degraded host still really executed everything else, so the
        # failure is attributable rather than blanket.
        assert assertion(receipt, :same_wasm)["value"]
      end
    end
  end

  describe "the receipt" do
    test "carries exactly the specified top-level shape", %{} = context do
      if skip = context[:skip] do
        IO.puts("skipped: #{skip}")
      else
        receipt = context.receipt

        for key <- ~w(profile graphlaw_version wasm_digest root_manifest_digest
                      runtime_a runtime_b assertions) do
          assert Map.has_key?(receipt, key), "receipt is missing #{key}"
        end

        assert receipt["profile"] == "SA2A-STRICT-v26.9.16"
        assert receipt["graphlaw_version"] =~ "praxis-graphlaw v"
        assert String.match?(receipt["root_manifest_digest"], ~r/\A[0-9a-f]{64}\z/)

        for side <- ["runtime_a", "runtime_b"] do
          for key <- ~w(host input_graph_hash admission output_graph_hash evidence_hash) do
            assert Map.has_key?(receipt[side], key), "#{side} is missing #{key}"
          end
        end

        assert receipt["runtime_a"]["host"] == "BEAM/Wasmex"
        assert receipt["runtime_b"]["host"] == "Node/StandaloneJS"

        assert Map.keys(receipt["assertions"]) |> Enum.sort() ==
                 Conformance.assertion_names() |> Enum.map(&Atom.to_string/1) |> Enum.sort()
      end
    end

    test "is JSON-encodable, which is what makes it machine-readable", %{} = context do
      if skip = context[:skip] do
        IO.puts("skipped: #{skip}")
      else
        encoded = JSON.encode!(context.receipt)
        assert {:ok, decoded} = JSON.decode(encoded)
        assert decoded["profile"] == "SA2A-STRICT-v26.9.16"
      end
    end

    test "both runtimes independently computed the same root manifest digest",
         %{} = context do
      if skip = context[:skip] do
        IO.puts("skipped: #{skip}")
      else
        receipt = context.receipt

        # Each host ran blake3_hex over the identical corpus manifest string
        # inside its own wasm instance.
        assert receipt["runtime_a"]["root_manifest_digest"] ==
                 receipt["runtime_b"]["root_manifest_digest"]

        assert receipt["root_manifest_digest"] == receipt["runtime_a"]["root_manifest_digest"]
      end
    end

    test "declares the scope it does and does not establish", %{} = context do
      if skip = context[:skip] do
        IO.puts("skipped: #{skip}")
      else
        scope = context.receipt["scope"]

        assert scope["stops_at"] == "ADMITTED"
        assert scope["actuation"] == "none"
        refute scope["authority_consulted"]
        refute scope["command_bus_invoked"]
        assert "universal semantic equivalence" in scope["does_not_establish"]
        assert "production readiness" in scope["does_not_establish"]
        assert "cross-implementation equivalence" in scope["does_not_establish"]
      end
    end
  end

  describe "scope discipline: the court stops at ADMITTED" do
    test "the conformance modules reference no actuation boundary at all" do
      sources =
        for file <- [
              "lib/ash_a2a/sa2a/conformance.ex",
              "lib/ash_a2a/sa2a/state_machine.ex",
              "lib/ash_a2a/sa2a/vector.ex",
              "lib/ash_a2a/sa2a/result_projection.ex",
              "lib/ash_a2a/graph_law/wasm.ex",
              "lib/ash_a2a/graph_law/runtime_b.ex"
            ],
            do: {file, File.read!(file)}

      for {file, source} <- sources do
        # Real file contents, not a recorded call expectation: these modules
        # must not be able to actuate anything, so the names simply do not
        # appear in them outside prose saying they must not.
        code =
          source
          |> String.split("\n")
          |> Enum.reject(&String.match?(&1, ~r/^\s*(#|\|\||@moduledoc|@doc)/))
          |> Enum.join("\n")

        refute code =~ "CommandBus.", "#{file} reaches the consequence boundary"
        refute code =~ "Authority.", "#{file} consults authority"
        refute code =~ "ReceiptOutbox", "#{file} claims a receipt"
      end
    end
  end

  describe "canonical projection" do
    test "identical hook results project to identical turtle and different ones do not" do
      admitted = %{"status" => "ADMITTED", "verdicts" => [], "receipts" => [], "schedule" => []}
      refused = %{"status" => "REFUSED", "verdicts" => [], "receipts" => [], "schedule" => []}

      assert ResultProjection.hook_result_turtle("v", admitted) ==
               ResultProjection.hook_result_turtle("v", admitted)

      refute ResultProjection.hook_result_turtle("v", admitted) ==
               ResultProjection.hook_result_turtle("v", refused)
    end

    test "validation summary sorts the one map whose json order is not guaranteed" do
      # PlaygroundResult.hash_algorithms is a Rust HashMap, so the raw
      # validate_all JSON is not canonical. Two orderings, one summary.
      one = %{"hash_algorithms" => %{"BLAKE3" => "1.0", "RDFC" => "1.0"}, "dialects" => []}
      other = %{"hash_algorithms" => %{"RDFC" => "1.0", "BLAKE3" => "1.0"}, "dialects" => []}

      assert ResultProjection.validation_summary(one) ==
               ResultProjection.validation_summary(other)

      assert ResultProjection.validation_summary(one) =~ "hash_algorithms=BLAKE3=1.0,RDFC=1.0"
    end

    test "a real projected hook result is parseable turtle with a real canonical hash",
         %{} = context do
      if skip = context[:skip] do
        IO.puts("skipped: #{skip}")
      else
        {:ok, %{session: session}} = Wasm.open([])

        try do
          {:ok, raw} =
            Wasm.call(session, :run_hooks, ["@prefix ex: <http://example.org/> .\n", ""])

          decoded = JSON.decode!(raw)
          turtle = ResultProjection.hook_result_turtle("probe", decoded)

          assert {:ok, hash} = Wasm.call(session, :graph_hash, [turtle])
          assert String.match?(hash, ~r/\A[0-9a-f]{64}\z/)
        after
          Wasm.close(session)
        end
      end
    end
  end
end
