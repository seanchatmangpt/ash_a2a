defmodule AshA2A.Chicago.GraphlawEngineTest do
  @moduledoc """
  Qualifies the `SA2A-ENGINE` court end to end against the vendored
  praxis-graphlaw engine, plus narrow Chicago-style tests of the pieces it
  relies on: the committed reproducers under `priv/graphlaw/defects/` (re-run
  against the real engine), the `AshA2A.GraphLaw.EngineLoad` surface guard
  over a real substituted wasm module, and `AshA2A.GraphLaw.EngineTelemetry`.

  Real collaborators only: the vendored wasm in real Wasmtime hosts, RDF.ex,
  `RuleDocument`, and a real OCEL artifact read back from disk.

  `async: false` -- the observer attributes telemetry to the active stimulus.
  """

  use ExUnit.Case, async: false

  alias AshA2A.Chicago
  alias AshA2A.Chicago.{Result, Runner, StandingReceipt}
  alias AshA2A.Chicago.Courts.GraphlawEngine
  alias AshA2A.Chicago.Fixtures.GraphlawEngine, as: F
  alias AshA2A.GraphLaw.{EngineLoad, EngineTelemetry, WasmexHost, WasmexSession}
  alias AshA2A.Semantic.Refusal

  @moduletag :tmp_dir
  @moduletag :graphlaw

  @open_defects for n <- 1..6, do: "SA2A-ENGINE-00#{n}"

  @expected %{
    "SA2A-ENGINE-001" => :falsifier_survived,
    "SA2A-ENGINE-002" => :falsifier_survived,
    "SA2A-ENGINE-003" => :falsifier_survived,
    "SA2A-ENGINE-004" => :falsifier_survived,
    "SA2A-ENGINE-005" => :falsifier_survived,
    "SA2A-ENGINE-006" => :falsifier_survived,
    "SA2A-ENGINE-007" => :positive_control_passed,
    "SA2A-ENGINE-008" => :positive_control_passed,
    "SA2A-ENGINE-009" => :positive_control_passed,
    "SA2A-ENGINE-010" => :positive_control_passed,
    "SA2A-ENGINE-011" => :positive_control_passed,
    "SA2A-ENGINE-012" => :falsifier_killed,
    "SA2A-ENGINE-013" => :falsifier_killed,
    "SA2A-ENGINE-014" => :positive_control_passed
  }

  describe "end-to-end Chicago run of SA2A-ENGINE" do
    @tag timeout: 300_000
    test "every falsifier reaches its pinned verdict, corroborated from the OCEL on disk",
         %{tmp_dir: dir} do
      assert {:ok, run} = Runner.run(courts: [GraphlawEngine], profile: :logic, evidence_dir: dir)

      declared = GraphlawEngine.falsifiers()
      by_id = Map.new(run.results, &{&1.falsifier_id, &1})
      assert map_size(by_id) == length(declared) and length(declared) == map_size(@expected)

      for falsifier <- declared do
        result = Map.fetch!(by_id, falsifier.id)

        assert result.verdict == Map.fetch!(@expected, falsifier.id),
               "#{falsifier.id}: #{result.verdict} #{inspect(result.detail)} #{inspect(result.ocel_detail)} #{inspect(result.evidence)}"

        assert result.ocel_corroborated? == true,
               "#{falsifier.id}: #{inspect(result.ocel_detail)}"

        if result.verdict in [:falsifier_killed, :positive_control_passed],
          do: assert(Result.counts_as_pass?(result))
      end

      # Open engine defects are reported, never softened.
      receipt = JSON.decode!(File.read!(Path.join(dir, "standing_receipt.json")))
      assert :ok = StandingReceipt.verify_digest(receipt)
      assert receipt["results"]["falsifiers_survived"] == 6
      assert receipt["results"]["survived_ids"] == @open_defects
      assert receipt["results"]["unresolved_ids"] == []
      assert run.ocel.dropped == 0

      # The survivals are the engine's own decisions on real stimuli, confirmed
      # independently of the engine.
      assert by_id["SA2A-ENGINE-001"].evidence["event_asserts_hooked_predicate_rdf_ex"] == true
      assert by_id["SA2A-ENGINE-003"].evidence["rdf_ex_refuses_both_inputs"] == true

      assert by_id["SA2A-ENGINE-004"].evidence["rule_document_classification"] ==
               "rule_not_range_restricted"

      assert by_id["SA2A-ENGINE-005"].evidence["observed"] == %{
               "error_code" => "graphlaw_call_trapped",
               "trap" => "all fuel consumed by WebAssembly"
             }

      for id <- ["SA2A-ENGINE-012", "SA2A-ENGINE-013"] do
        assert by_id[id].evidence["caller_crashed"] == false
        assert by_id[id].evidence["loaded"] == false
      end
    end

    test "the court is discoverable with its id, profile and complete declarations" do
      assert GraphlawEngine in Chicago.courts()
      assert {GraphlawEngine.id(), GraphlawEngine.profile()} == {"SA2A-ENGINE", :logic}
      refute GraphlawEngine in Chicago.courts_for(:core)

      for f <- GraphlawEngine.falsifiers() do
        assert String.starts_with?(f.id, "SA2A-ENGINE-")
        assert f.attempt_predicate != nil and f.outcome_predicate != nil
      end
    end
  end

  describe "reproducers under priv/graphlaw/defects" do
    setup do
      host = F.start_host()
      on_exit(fn -> F.stop_host(host) end)
      %{host: host}
    end

    test "every recorded case re-runs to the recorded observation on the pinned engine",
         %{host: host} do
      pin = F.pinned_sha256()

      for id <- F.defect_ids() do
        doc = F.reproducer(id)
        assert doc["schema"] == "ash_a2a.graphlaw.defect/v1"
        assert doc["status"] == "BLOCKED_ON_PRAXIS"
        assert doc["engine"]["sha256"] == pin
        assert doc["root_cause"] != []

        recorded = Map.new(doc["cases"], &{&1["name"], &1})

        assert Enum.sort(Map.keys(recorded)) ==
                 F.cases(id) |> Enum.map(&elem(&1, 0)) |> Enum.sort()

        for {name, _kind, function, args} = c <- F.cases(id) do
          case_doc = Map.fetch!(recorded, name)
          assert case_doc["call"] == function
          assert case_doc["args"] == args, "#{id}/#{name}: inputs drifted from the fixture"

          assert F.observation(F.run_case(host, c)) == case_doc["observed"],
                 "#{id}/#{name}: the pinned engine no longer produces the recorded output"
        end
      end
    end

    test "the praxis HEAD build was measured and did not change a defect case" do
      for id <- F.defect_ids(), case_doc <- F.reproducer(id)["cases"] do
        head = case_doc["praxis_head_build_observed"]
        assert is_map(head)

        case case_doc["observed"] do
          %{"returned" => _} -> assert head == case_doc["observed"], "#{id}/#{case_doc["name"]}"
          %{"error_code" => "graphlaw_call_trapped"} -> assert head["no_return_within_s"] == 20
        end
      end

      refresh =
        JSON.decode!(
          File.read!(Path.join([AshA2A.GraphLaw.dir(), "defects", "praxis-head-refresh.json"]))
        )

      assert refresh["decision"]["vendored_artifact"] == "KEPT"
      assert refresh["engine"]["sha256"] == F.pinned_sha256()
    end
  end

  describe "EngineLoad over a real substituted module" do
    test "the pinned surface is admitted and the praxis HEAD surface is refused", %{tmp_dir: dir} do
      assert :ok = EngineLoad.check_surface(WasmexSession.pinned_imports())
      assert EngineLoad.pinned_imports() == WasmexSession.pinned_imports()

      {path, _sha} = F.foreign_surface_wasm!(dir)
      assert {:ok, store} = Wasmex.Store.new()

      assert {:error, %{code: :graphlaw_import_surface_mismatch} = error} =
               EngineLoad.admit("test", File.read!(path), store)

      assert length(error.actual) == 6
      assert length(error.unexpected) == 4 and error.missing == []

      assert {:error, %{code: :graphlaw_wasm_invalid}} =
               EngineLoad.admit("test", "not wasm", store)

      assert Refusal.classify(:graphlaw_import_surface_mismatch) == :refused_identity
    end

    test "WasmexSession.open refuses the substituted engine without crashing its caller",
         %{tmp_dir: dir} do
      {path, _sha} = F.foreign_surface_wasm!(dir)

      assert {:returned, {:error, %{code: :graphlaw_import_surface_mismatch, path: ^path}}} =
               F.contained(fn -> WasmexSession.open(wasm_path: path) end)

      assert {:returned, {:error, %{code: :graphlaw_import_surface_mismatch}}} =
               F.contained(fn -> WasmexSession.open(wasm_path: path, fuel: 1_000) end)
    end

    test "WasmexHost starts unavailable on the substituted engine and answers with typed errors",
         %{tmp_dir: dir} do
      {path, _sha} = F.foreign_surface_wasm!(dir)
      name = Module.concat(__MODULE__, "Substituted#{System.unique_integer([:positive])}")

      assert {:returned, {false, {:error, %{code: :graphlaw_import_surface_mismatch}}}} =
               F.contained(fn ->
                 {:ok, pid} = WasmexHost.start_link(name: name, wasm_path: path)
                 reply = {WasmexHost.available?(name), WasmexHost.graph_hash("", name)}
                 GenServer.stop(pid)
                 reply
               end)
    end
  end

  describe "EngineTelemetry" do
    test "summarises the real engine's decision for run_hooks and validate_all" do
      host = F.start_host()
      handler = "graphlaw-engine-test-#{System.unique_integer([:positive])}"
      parent = self()

      :telemetry.attach(
        handler,
        EngineTelemetry.event(),
        fn _e, m, meta, _ ->
          send(parent, {:engine_call, m, meta})
        end,
        nil
      )

      try do
        assert {:ok, _} = WasmexHost.run_hooks(F.delta_hook_pack(), F.matching_event(), host)
        assert_receive {:engine_call, %{system_time: _}, hooks}
        assert hooks.function == "run_hooks" and hooks.outcome == :returned
        assert hooks.wasm_sha256 == F.pinned_sha256()
        assert {hooks.hooks_status, hooks.verdict_count} == {"ADMITTED", 0}

        doc = F.safe_rule_document()
        assert {:ok, _} = WasmexHost.validate_all(doc, "", "", "", "", host)
        assert_receive {:engine_call, _, validation}
        assert validation["datalog_status"] == "ADMITTED"
        assert validation["datalog_triples_out"] == 1
        assert validation["n3_denial_status"] == "REFUSED"
      after
        :telemetry.detach(handler)
        F.stop_host(host)
      end
    end

    test "records a trap as outcome trapped" do
      meta =
        EngineTelemetry.metadata(
          "h",
          "d",
          "validate_all",
          {:error, %{code: :graphlaw_call_trapped}}
        )

      assert {meta.outcome, meta.code} == {:trapped, :graphlaw_call_trapped}
    end
  end
end
