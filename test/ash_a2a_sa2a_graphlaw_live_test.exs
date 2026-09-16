defmodule AshA2ASA2AGraphlawLiveTest do
  @moduledoc """
  Live re-verification of the SA2A conformance corpus against the REAL pinned
  GraphLaw wasm, through a REAL `node` subprocess.

  Chicago-school throughout: a real OS subprocess, the real 3.2 MB wasm
  artifact, the real corpus files on disk, and assertions on real returned
  digests and statuses. Nothing is mocked -- in particular the engine is never
  stubbed, because a fabricated engine answer would defeat the only thing this
  corpus exists to establish.

  On a machine without `node` or without the praxis wasm checkout, these tests
  **skip visibly** with a named reason rather than silently substituting a
  double. `AshA2ASA2ACorpusTest` still holds there: it asserts over the recorded
  measurements and the real file digests, which need no engine.
  """
  use ExUnit.Case, async: true

  alias AshA2A.SA2A.{Corpus, Graphlaw}
  alias AshA2A.SA2A.Corpus.Vector

  @moduletag :graphlaw

  setup_all do
    corpus = Corpus.load!()

    # One real subprocess run for the whole module: the driver measures every
    # vector in one pass, so this is one real engine execution, not one per test.
    case Graphlaw.measure(corpus.dir) do
      {:ok, live} ->
        {:ok, corpus: corpus, live: live}

      {:error, err} ->
        # Not a silent skip: `test_helper.exs` already excludes this whole module
        # with a printed reason when the engine is unavailable, so reaching here
        # means the engine WAS available and the real run genuinely failed.
        raise "SA2A live graphlaw run failed: #{inspect(err)}"
    end
  end

  describe "the pinned engine is the engine the corpus was measured against" do
    test "the running wasm's real sha256 and version match the manifest", ctx do
      live = ctx.live
      engine = Corpus.engine(ctx.corpus)

      assert live["wasm_sha256"] == engine["wasm_sha256"]
      assert live["wasm_bytes"] == engine["wasm_bytes"]
      assert live["graphlaw_version"] == engine["graphlaw_version"]
    end

    test "the running wasm computes the published BLAKE3 vector for \"abc\"", ctx do
      assert ctx.live["blake3_abc"] ==
               "6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85"
    end
  end

  describe "every recorded expectation still holds against a real engine run" do
    test "every vector's recorded graph and law-graph digests are reproduced live", ctx do
      live = ctx.live

      for v <- Corpus.vectors(ctx.corpus) do
        measured = live["vectors"][v.name]
        assert measured, "no live measurement for #{v.name}"
        assert measured["graph_hash"] == v.graph_digest, "graph digest drift in #{v.name}"
        assert measured["law_graph_hash"] == v.law_graph_digest, "law digest drift in #{v.name}"
      end
    end

    test "every vector's recorded dialect statuses are reproduced live", ctx do
      live = ctx.live

      for v <- Corpus.vectors(ctx.corpus) do
        assert live["vectors"][v.name]["dialects"] == v.measured["dialects"],
               "dialect status drift in #{v.name}"
      end
    end

    test "the S15 severity partition is reproduced live and still decides admission", ctx do
      live = ctx.live

      for v <- Corpus.vectors(ctx.corpus), v.class =~ "shacl" or v.class == "positive_baseline" do
        partition = live["vectors"][v.name]["shacl_by_severity_partition"]

        assert partition == Vector.shacl_partition(v), "partition drift in #{v.name}"

        assert Vector.admission_from_severity(partition["violations_only"]["status"]) ==
                 v.expected_admission,
               "live S15 derivation disagrees with the sidecar for #{v.name}"
      end
    end

    test "the warning-only vector really admits while graphlaw really refuses", ctx do
      m = ctx.live["vectors"]["shacl_warning_only"]

      assert m["dialects"]["SHACL"] == "REFUSED"
      assert m["shacl_by_severity_partition"]["violations_only"]["status"] == "ADMITTED"

      assert Vector.severity_class(
               m["shacl_by_severity_partition"]["violations_only"]["status"],
               m["shacl_by_severity_partition"]["full"]["status"]
             ) == :warning_only

      assert Corpus.fetch_vector!(ctx.corpus, "shacl_warning_only").expected_admission ==
               :admitted
    end

    test "replay verification is byte-identical on every vector", ctx do
      for {name, m} <- ctx.live["vectors"] do
        assert m["replay"]["status"] == "ADMITTED", "replay not admitted for #{name}"
        assert m["replay"]["first_hash"] == m["replay"]["second_hash"], "replay drift in #{name}"
      end
    end
  end

  describe "the two RFC requirements the pinned engine does NOT meet" do
    test "S12 blank-node isomorphism still FAILS live, exactly as recorded", ctx do
      live = ctx.live
      iso = live["vectors"]["base_bnode_relabelled"]["graph_hash"]
      base = live["vectors"]["base"]["graph_hash"]

      # The RFC requires these to be equal. They are not. The corpus says so.
      refute iso == base

      assert Corpus.fetch_vector!(ctx.corpus, "base_bnode_relabelled").conformance ==
               :failing_on_pinned_engine
    end

    test "graph-declared hooks still never register live, exactly as recorded", ctx do
      for {name, m} <- ctx.live["vectors"] do
        assert m["run_hooks"]["status"] == "ADMITTED"
        assert m["run_hooks"]["schedule"] == [], "unexpected live hook schedule for #{name}"
      end

      deferral =
        ctx.corpus
        |> Corpus.deferred()
        |> Enum.find(&(&1["id"] == "hooks_never_register_through_wasm_run_hooks"))

      assert deferral["status"] == "BLOCKED_ON_PINNED_ENGINE"
    end
  end

  describe "error typing at the native boundary" do
    test "a missing wasm is a typed refusal, not a crash", %{corpus: corpus} do
      assert {:error, %{code: :sa2a_graphlaw_unavailable, detail: :wasm_not_built}} =
               Graphlaw.measure(corpus.dir,
                 wasm_path:
                   Path.join(
                     System.tmp_dir!(),
                     "no_such_graphlaw_#{:erlang.unique_integer([:positive])}.wasm"
                   )
               )
    end

    test "a missing corpus directory is a typed refusal from the real driver", _ctx do
      missing =
        Path.join(System.tmp_dir!(), "no_such_corpus_#{:erlang.unique_integer([:positive])}")

      assert {:error, %{code: :sa2a_graphlaw_driver_error, detail: detail, exit: exit_code}} =
               Graphlaw.measure(missing)

      assert detail =~ "MANIFEST.json not found"
      assert exit_code == 4
    end
  end
end
