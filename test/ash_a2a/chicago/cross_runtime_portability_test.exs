defmodule AshA2A.Chicago.CrossRuntimePortabilityTest do
  @moduledoc """
  SA2A-XRUNTIME (RFC-SA2A-002 §76, §91, §125, §126), Chicago style: one real
  content-addressed GraphLaw wasm artifact executed by the real in-BEAM
  Wasmtime NIF, a real V8 subprocess and (when built) the real native
  Wasmtime binary; the real `AshA2A.SA2A.Conformance` court; real corpora and
  a real degenerate wasm artifact on disk; the real `AshA2A.Chicago.Runner`
  and a real OCEL artifact read back by the independent consumer. The only
  fault injection is environmental (an absent host executable).

  `async: false`: the observer attributes every telemetry event emitted
  between a stimulus start and stop to that falsifier, and one test changes
  the application environment.
  """

  use ExUnit.Case, async: false

  alias AshA2A.Chicago.{Query, Runner}
  alias AshA2A.Chicago.Courts.CrossRuntimePortability, as: Court
  alias AshA2A.Chicago.Fixtures.CrossRuntime, as: Fx
  alias AshA2A.GraphLaw.{RuntimeB, WasmexSession, WasmtimeRuntime}
  alias AshA2A.RuntimeIdentity.Execution
  alias AshA2A.SA2A.{Conformance, StateMachine}

  @moduletag :tmp_dir

  @expected %{
    "SA2A-XRUNTIME-001" => :positive_control_passed,
    "SA2A-XRUNTIME-002" => :positive_control_passed,
    "SA2A-XRUNTIME-003" => :falsifier_killed,
    "SA2A-XRUNTIME-004" => :falsifier_killed,
    "SA2A-XRUNTIME-005" => :falsifier_killed,
    "SA2A-XRUNTIME-006" => :falsifier_killed,
    "SA2A-XRUNTIME-007" => :falsifier_killed,
    "SA2A-XRUNTIME-008" => :falsifier_killed,
    "SA2A-XRUNTIME-009" => :positive_control_passed,
    "SA2A-XRUNTIME-010" => :measured
  }

  # Which real hosts each falsifier needs.
  @needs %{
    "SA2A-XRUNTIME-001" => [WasmexSession, RuntimeB],
    "SA2A-XRUNTIME-002" => [RuntimeB, WasmtimeRuntime],
    "SA2A-XRUNTIME-003" => [WasmexSession, RuntimeB],
    "SA2A-XRUNTIME-004" => [WasmexSession, RuntimeB],
    "SA2A-XRUNTIME-005" => [WasmexSession],
    "SA2A-XRUNTIME-006" => [WasmexSession],
    "SA2A-XRUNTIME-007" => [WasmexSession, RuntimeB],
    "SA2A-XRUNTIME-008" => [WasmexSession, RuntimeB],
    "SA2A-XRUNTIME-009" => [WasmexSession, RuntimeB],
    "SA2A-XRUNTIME-010" => [WasmexSession, RuntimeB]
  }

  defp available?(runtimes), do: Enum.all?(runtimes, &(&1.available?([]) == :ok))

  describe "the SA2A-XRUNTIME court end to end" do
    @tag timeout: 600_000
    test "every falsifier reaches its verdict and every pass is OCEL-corroborated", %{
      tmp_dir: dir
    } do
      assert Court in AshA2A.Chicago.courts_for(:core)

      assert {:ok, run} = Runner.run(courts: [Court], profile: :core, evidence_dir: dir)
      by_id = Map.new(run.results, &{&1.falsifier_id, &1})
      assert Enum.sort(Map.keys(by_id)) == Enum.sort(Map.keys(@expected))

      for {id, verdict} <- @expected do
        result = by_id[id]

        if available?(@needs[id]) do
          assert result.verdict == verdict,
                 "#{id}: #{result.verdict} -- #{result.detail} -- #{result.ocel_detail} -- " <>
                   inspect(result.evidence, limit: 20)

          assert result.ocel_corroborated? == true, "#{id}: #{result.ocel_detail}"
        else
          IO.puts("#{id} requires #{inspect(@needs[id])}: #{result.detail}")
          assert result.verdict == :blocked, "#{id}: #{result.verdict}"
        end
      end

      assert run.receipt["results"]["falsifiers_survived"] == 0

      if available?([WasmexSession, RuntimeB]) do
        # Masquerades are refused on the engine the calls executed on.
        for id <- ["SA2A-XRUNTIME-005", "SA2A-XRUNTIME-006"] do
          assert [%{"outcome" => "identical", "basis" => "executed_engine"}] =
                   by_id[id].evidence["decisions"],
                 id
        end

        # The degenerate artifact really was the one both hosts loaded, and
        # nothing it answered was computed.
        degenerate = by_id["SA2A-XRUNTIME-004"].evidence
        assert degenerate["receipt_wasm_digest"] == degenerate["degenerate_artifact_sha256"]
        assert Enum.all?(degenerate["fixtures"], &(&1["computed"] == [false, false]))

        # The malformed negative fixture is refused at PARSED by both hosts.
        [malformed] = by_id["SA2A-XRUNTIME-003"].evidence["fixture"]
        assert malformed["admission"] == ["REFUSED", "REFUSED"]

        assert malformed["refusal_reason"] == [
                 "PARSED:NOT_RDF11_TURTLE",
                 "PARSED:NOT_RDF11_TURTLE"
               ]

        b7 = by_id["SA2A-XRUNTIME-010"].measurements
        assert b7["benchmark"] == "SA2A-B7"
        [pair | _] = b7["pairs"]
        assert pair["fixture_count"] >= 10
        assert pair["admission_equivalence_count"] == pair["fixture_count"]
        assert pair["post_state_equivalence_count"] == pair["fixture_count"]
        assert pair["refusal_equivalence_count"] == pair["refused_fixture_count"]
        assert pair["input_identity_equivalence_count"] == pair["fixture_count"] - 1
        assert pair["disagreements"] == []
        assert b7["artifact_digest"] == [pair["artifact_digest"]]

        [host_a, host_b] = pair["hosts"]
        assert host_a["executed_identity_digest"] =~ ~r/\A[0-9a-f]{64}\z/
        assert host_a["executed_identity_digest"] != host_b["executed_identity_digest"]
        assert is_integer(host_a["latency_us"]) and host_a["latency_us"] > 0
        assert host_a["memory"]["engine_reported"]["wasm_linear_memory_bytes"] > 0
        assert [%{"peak_rss_bytes" => rss}] = host_b["memory"]["os_processes"]
        assert is_integer(rss) and rss > 0

        # The independent consumer answers the §126 question from disk: every
        # judged vector was preceded by a runtime-identity decision.
        assert {:ok, index} = Query.load(Path.join(dir, "ocel.json"), run.ocel.sha256)

        assert {true, _} =
                 Query.eval(
                   index,
                   "SA2A-XRUNTIME-001",
                   {:precedes, "sa2a.conformance.runtime_identity",
                    "sa2a.conformance.vector_judged", "runtime"}
                 )

        assert {true, _} =
                 Query.eval(
                   index,
                   "SA2A-XRUNTIME-005",
                   {:observed, "sa2a.conformance.runtime_identity",
                    %{"outcome" => "identical", "basis" => "executed_engine"}}
                 )
      end
    end

    @tag timeout: 300_000
    @tag :graphlaw_engine
    test "an unavailable host makes its falsifiers BLOCKED, never killed", %{tmp_dir: dir} do
      previous = Application.fetch_env(:ash_a2a, :graphlaw_runtime_b_executable)

      # Environment fault injection: the V8 host executable does not exist.
      Application.put_env(
        :ash_a2a,
        :graphlaw_runtime_b_executable,
        Path.join(dir, "no-such-js-engine")
      )

      try do
        assert {:error, %{code: :graphlaw_host_executable_not_found}} = RuntimeB.available?([])

        assert {:ok, run} =
                 Runner.run(courts: [Court], profile: :core, evidence_dir: Path.join(dir, "run"))

        for result <- run.results do
          if RuntimeB in @needs[result.falsifier_id] do
            assert result.verdict == :blocked, "#{result.falsifier_id}: #{result.verdict}"
            assert result.detail =~ "RuntimeB is unavailable"
          end
        end

        if WasmexSession.available?([]) == :ok do
          by_id = Map.new(run.results, &{&1.falsifier_id, &1})
          assert by_id["SA2A-XRUNTIME-005"].verdict == :falsifier_killed
          assert by_id["SA2A-XRUNTIME-006"].verdict == :falsifier_killed
        end

        refute run.receipt["standing"] == "CONFORMANT"
      after
        case previous do
          {:ok, value} -> Application.put_env(:ash_a2a, :graphlaw_runtime_b_executable, value)
          :error -> Application.delete_env(:ash_a2a, :graphlaw_runtime_b_executable)
        end
      end
    end
  end

  describe "execution-observed runtime identity (§126)" do
    test "real hosts execute on disjoint engines; masquerades on the engine they wrap" do
      if available?([WasmexSession, RuntimeB]) do
        engines =
          Map.new(
            [WasmexSession, RuntimeB, Fx.DecoyResourceRuntime, Fx.HiddenEngineRuntime],
            fn runtime ->
              {:ok, %{session: session}} = runtime.open([])

              try do
                assert {:ok, observation} =
                         Execution.observe(fn -> runtime.call(session, :graphlaw_version, []) end)

                {runtime, observation}
              after
                runtime.close(session)
              end
            end
          )

        assert [%{"kind" => "beam_process", "engine_application" => "wasmex"}] =
                 engines[WasmexSession].engines

        assert [%{"kind" => "os_process", "executable_sha256" => sha}] = engines[RuntimeB].engines
        assert sha =~ ~r/\A[0-9a-f]{64}\z/

        assert Execution.disjoint?(engines[WasmexSession].engines, engines[RuntimeB].engines)

        refute Execution.disjoint?(
                 engines[WasmexSession].engines,
                 engines[Fx.DecoyResourceRuntime].engines
               )

        refute Execution.disjoint?(
                 engines[WasmexSession].engines,
                 engines[Fx.HiddenEngineRuntime].engines
               )

        # The hidden engine is one hop away: observed only by expanding the Agent.
        assert engines[Fx.HiddenEngineRuntime].rounds == 2
        assert engines[Fx.HiddenEngineRuntime].expanded == 1
      else
        IO.puts("skipped: the in-BEAM and V8 hosts are not both available")
      end
    end

    test "a probe that reaches no engine is unobservable, never a guessed identity" do
      assert {:unobservable, detail} = Execution.observe(fn -> :no_engine_reached end)
      assert detail =~ "reached no engine resource"
    end

    test "the native host is identified by the executable its per-call process ran" do
      if available?([WasmtimeRuntime]) do
        {:ok, %{session: session}} = WasmtimeRuntime.open([])

        try do
          assert {:ok, %{engines: [%{"kind" => "os_process", "executable_sha256" => sha}]}} =
                   Execution.observe(fn ->
                     WasmtimeRuntime.call(session, :graphlaw_version, [])
                   end)

          assert sha ==
                   AshA2A.RuntimeIdentity.file_sha256(WasmtimeRuntime.binary_path())
        after
          WasmtimeRuntime.close(session)
        end
      else
        IO.puts("skipped: graphlaw_host is not built")
      end
    end
  end

  describe "fixtures and repaired boundaries" do
    test "the degenerate artifact is valid wasm that every available host executes to {}", %{
      tmp_dir: dir
    } do
      wasm = Fx.degenerate_wasm!(dir)

      for runtime <- [WasmexSession, RuntimeB, WasmtimeRuntime],
          runtime.available?(wasm_path: wasm) == :ok do
        assert {:ok, %{session: session, wasm_digest: digest}} = runtime.open(wasm_path: wasm)

        try do
          assert digest == AshA2A.RuntimeIdentity.file_sha256(wasm)
          assert {:ok, "{}"} = runtime.call(session, :graph_hash, ["<a> <b> <c> ."])
          assert {:ok, "{}"} = runtime.call(session, :run_hooks, ["", ""])
        after
          runtime.close(session)
        end
      end
    end

    test "PARSED requires the S12 parse when the input text is supplied" do
      hash = String.duplicate("a", 64)
      bad = "ex:alice ex:name \"Alice\" ;;; <<< not turtle"

      assert %{admission: :refused, typed_reason: "PARSED:NOT_RDF11_TURTLE"} =
               StateMachine.evaluate(hash, {:error, :unused}, {:error, :unused}, base: bad)

      # Without the text the hop keeps its previous engine-digest rule.
      assert %{typed_reason: "IDENTIFIED:" <> _} =
               StateMachine.evaluate(hash, {:error, :unused}, {:error, :unused})
    end

    test "a replay against different runtimes is refused as not comparable" do
      prior = %{
        "runtime_a" => %{"runtime_module" => inspect(WasmexSession)},
        "runtime_b" => %{"runtime_module" => inspect(RuntimeB)}
      }

      assert {:error, %{code: :sa2a_replay_subject_mismatch}} =
               Conformance.replay(prior, runtime_a: RuntimeB, runtime_b: WasmexSession)

      assert {:error, %{code: :sa2a_replay_prior_malformed}} = Conformance.replay(%{})
    end

    test "every new refusal code classifies through the introducing module" do
      mapping = AshA2A.Semantic.Refusal.mapping()

      for code <- [
            :sa2a_degenerate_result,
            :sa2a_replay_subject_mismatch,
            :sa2a_replay_prior_malformed
          ] do
        assert Map.has_key?(mapping, code), "#{code} is not classified"
      end
    end
  end
end
