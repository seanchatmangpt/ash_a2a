# NOTE: 1 module(s) removed from this consolidated file because the repaired originals (kept as separate files) define the same modules; see docs/reference/test-consolidation-merge.md.
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
# SPDX-License-Identifier: MIT

# ==============================================================================
# Consolidated Test Suite: Chicago Formal Verification, Hardening, Stress & Release Courts (Part 2)
# Contains 18 original test files:
#   - test/ash_a2a/chicago/identity_gate1_test.exs
#   - test/ash_a2a/chicago/logic_sparql_test.exs
#   - test/ash_a2a/chicago/mutation_harness_test.exs
#   - test/ash_a2a/chicago/observer_qualification_test.exs
#   - test/ash_a2a/chicago/ocel_validator_test.exs
#   - test/ash_a2a/chicago/offline_replay_test.exs
#   - test/ash_a2a/chicago/plan_gates_test.exs
#   - test/ash_a2a/chicago/postcondition_test.exs
#   - test/ash_a2a/chicago/real_collaborators_test.exs
#   - test/ash_a2a/chicago/receipt_binding_attestation_test.exs
#   - test/ash_a2a/chicago/root_manifest_meta_admission_test.exs
#   - test/ash_a2a/chicago/sa2a_v26_9_17_fond_qualification_test.exs
#   - test/ash_a2a/chicago/sa2a_v26_9_17_reachability_analysis_test.exs
#   - test/ash_a2a/chicago/sa2a_v26_9_17_source_fidelity_test.exs
#   - test/ash_a2a/chicago/sa2a_v26_9_17_topology_test.exs
#   - test/ash_a2a/chicago/shex_shacl_admission_test.exs
#   - test/ash_a2a/chicago/unknown_llm_gate12_test.exs
#   - test/ash_a2a/chicago/wasm_default_resolution_test.exs
# ==============================================================================

# --- SECTION 1: Original test/ash_a2a/chicago/identity_gate1_test.exs ---
defmodule AshA2A.Chicago.IdentityGate1Test do
  @moduledoc """
  Gate 1 exact identity (RFC-SA2A-002 §5, §6, §32, §119, §120, §126),
  Chicago style: real scratch git repositories, real commits/tags/branches,
  real artifact and rule files, the real `AshA2A.Chicago.Runner`, the real
  `AshA2A.SA2A.Conformance` over the real in-BEAM Wasmtime and out-of-BEAM
  JavaScript hosts, and a real OCEL artifact read back from disk by the
  independent consumer.

  `async: false`: the observer attributes every telemetry event emitted
  between a stimulus start and stop to that falsifier.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  alias AshA2A.Chicago.{Query, Requalification, Runner, StandingReceipt, Subject}
  alias AshA2A.Chicago.Courts.ExactIdentity
  alias AshA2A.Chicago.Fixtures.Identity, as: Fx
  alias AshA2A.GraphLaw.{RuntimeB, WasmexSession}
  alias AshA2A.RuntimeIdentity
  alias AshA2A.SA2A.Conformance

  @moduletag :tmp_dir

  doctest AshA2A.RuntimeIdentity

  defp runtimes_available? do
    WasmexSession.available?([]) == :ok and RuntimeB.available?([]) == :ok
  end

  describe "the CHI-ID court end to end" do
    @tag timeout: 300_000
    @tag :graphlaw_engine
    test "every falsifier reaches its verdict and every pass is OCEL-corroborated", %{
      tmp_dir: dir
    } do
      assert ExactIdentity in AshA2A.Chicago.courts_for(:core)

      assert {:ok, run} = Runner.run(courts: [ExactIdentity], profile: :core, evidence_dir: dir)
      by_id = Map.new(run.results, &{&1.falsifier_id, &1})

      runtime_dependent = ["CHI-ID-007", "CHI-ID-009"]

      expected =
        %{
          "CHI-ID-001" => :falsifier_killed,
          "CHI-ID-002" => :falsifier_killed,
          "CHI-ID-003" => :falsifier_killed,
          "CHI-ID-004" => :falsifier_killed,
          "CHI-ID-005" => :falsifier_killed,
          "CHI-ID-006" => :falsifier_killed,
          "CHI-ID-007" => :falsifier_killed,
          "CHI-ID-008" => :positive_control_passed,
          "CHI-ID-009" => :positive_control_passed,
          "CHI-ID-010" => :falsifier_killed,
          "CHI-ID-011" => :falsifier_killed,
          "CHI-ID-012" => :positive_control_passed,
          "CHI-ID-013" => :falsifier_killed,
          "CHI-ID-014" => :positive_control_passed
        }

      assert Enum.sort(Map.keys(by_id)) == Enum.sort(Map.keys(expected))

      for {id, verdict} <- expected do
        result = by_id[id]

        if id in runtime_dependent and not runtimes_available?() do
          IO.puts("#{id} requires the real wasm + node runtimes: #{result.detail}")
          assert result.verdict == :blocked
        else
          assert result.verdict == verdict,
                 "#{id}: #{result.verdict} -- #{result.detail} -- #{result.ocel_detail} -- " <>
                   inspect(result.evidence)

          assert result.ocel_corroborated? == true, "#{id}: #{result.ocel_detail}"
        end
      end

      # The identity refusals are real, durable and name the moved field.
      for {id, name, field} <- [
            {"CHI-ID-001", "branch", "source_revision"},
            {"CHI-ID-002", "artifact", "artifact_digests"},
            {"CHI-ID-003", "manifest", "root_manifest_digest"},
            {"CHI-ID-004", "rules", "validator_digests"},
            {"CHI-ID-005", "tag", "tag_commit"}
          ] do
        receipt =
          Path.join([dir, "chi-id", name <> "-standing", "standing_receipt.json"])
          |> File.read!()
          |> JSON.decode!()

        assert receipt["standing"] == "REFUSED", id
        assert field in receipt["subject"]["verification"]["fields"], id
        assert receipt["claim"] =~ "REFUSED", id
        assert :ok = StandingReceipt.verify_digest(receipt)
      end

      # Artifact / manifest / rule-set substitution left the source revision
      # untouched: the mismatch is exactly the substituted identity.
      for {id, field} <- [
            {"CHI-ID-002", "artifact_digests"},
            {"CHI-ID-003", "root_manifest_digest"},
            {"CHI-ID-004", "validator_digests"}
          ] do
        evidence = by_id[id].evidence
        assert evidence["claimed_source_revision"] == evidence["observed_source_revision"], id
        assert evidence["verification"]["fields"] == [field], id
      end

      receipt = run.receipt
      gate1 = Enum.find(receipt["gates"], &(&1["gate"] == 1))
      assert gate1["status"] == if(runtimes_available?(), do: "PASSED", else: "OPEN")
      assert receipt["results"]["falsifiers_survived"] == 0
      assert receipt["standing"] in ["PARTIAL_ALIVE", "UNKNOWN"]

      # The independent consumer answers the §32 question from disk: every
      # REFUSED standing was preceded by the identity verification of the
      # same subject object.
      assert {:ok, index} = Query.load(Path.join(dir, "ocel.json"), run.ocel.sha256)

      assert {true, _} =
               Query.eval(
                 index,
                 "CHI-ID-005",
                 {:precedes, "chicago.subject.verified", "chicago.run.stop", "subject"}
               )
    end
  end

  describe "Subject over a real scratch release" do
    test "binds tag, CalVer, artifact, manifest, rule set and the observed emulator", %{
      tmp_dir: dir
    } do
      release = Fx.release!(dir, "subject")
      subject = Subject.capture(release.subject_opts)

      assert subject.source_revision == release.c1
      assert subject.tag == "v26.9.16"
      assert subject.tag_commit == release.c1
      assert subject.version == "26.9.16"
      assert subject.dirty? == false
      assert Map.keys(subject.artifact_digests) == ["dist/graphlaw.wasm"]
      assert subject.root_manifest_digest == Subject.file_sha256(release.manifest)
      assert map_size(subject.validator_digests) == 2
      assert String.match?(subject.runtime["emulator_sha256"], ~r/\A[0-9a-f]{64}\z/)

      assert :ok = Subject.verify(subject, Subject.capture(release.subject_opts))
      assert {:ok, ^subject} = subject |> Subject.to_map() |> Subject.from_map()
    end

    test "a moved tag breaks TagCommit = VerifiedCommit even without a prior claim", %{
      tmp_dir: dir
    } do
      release = Fx.release!(dir, "tagonly")
      c2 = Fx.move_tag!(release)
      moved = Subject.capture(release.subject_opts)

      assert moved.source_revision == release.c1
      assert moved.tag_commit == c2
      assert {:error, {:subject_mismatch, [:tag_commit]}} = Subject.verify(moved, moved)
    end

    test "verify emits the boundary telemetry with the mismatched fields", %{tmp_dir: dir} do
      release = Fx.release!(dir, "telemetry")
      claim = Subject.capture(release.subject_opts)
      Fx.alter_manifest!(release)
      observed = Subject.capture(release.subject_opts)

      handler = {__MODULE__, make_ref()}
      parent = self()

      :telemetry.attach(
        handler,
        Subject.verified_event(),
        fn _event, _m, meta, _ -> send(parent, {:verified, meta}) end,
        nil
      )

      try do
        assert {:mismatch, claimed_identity, [:root_manifest_digest]} =
                 Subject.verify_claim(claim, observed)

        assert claimed_identity == Subject.digest(claim)
        assert_received {:verified, %{outcome: :mismatch, fields: [:root_manifest_digest]}}

        # A tampered JSON claim is refused as unreadable, never ignored.
        tampered =
          claim |> Subject.to_map() |> Map.put("identity", String.duplicate("0", 64))

        assert {:mismatch, nil, [:claimed_subject]} = Subject.verify_claim(tampered, observed)
        assert :not_claimed = Subject.verify_claim(nil, observed)
      after
        :telemetry.detach(handler)
      end
    end
  end

  describe "Runner :claimed_subject hook" do
    test "a matching claim keeps computed standing; a stale claim is REFUSED before issue", %{
      tmp_dir: dir
    } do
      release = Fx.release!(dir, "runner")
      claim = Subject.capture(release.subject_opts)

      assert {:ok, ok_run} =
               Runner.run(
                 courts: [],
                 claimed_subject: Subject.to_map(claim),
                 subject_opts: release.subject_opts,
                 evidence_dir: Path.join(dir, "match")
               )

      assert ok_run.receipt["standing"] == "UNKNOWN"
      assert ok_run.receipt["subject"]["verification"]["outcome"] == "match"

      Fx.advance_branch!(release)

      assert {:ok, stale_run} =
               Runner.run(
                 courts: [],
                 claimed_subject: claim,
                 subject_opts: release.subject_opts,
                 evidence_dir: Path.join(dir, "stale")
               )

      assert stale_run.receipt["standing"] == "REFUSED"
      assert "source_revision" in stale_run.receipt["subject"]["verification"]["fields"]
      assert stale_run.receipt["claim"] =~ "SA2A-CORE REFUSED"

      assert {:ok, unclaimed} =
               Runner.run(
                 courts: [],
                 subject_opts: release.subject_opts,
                 evidence_dir: Path.join(dir, "unclaimed")
               )

      assert unclaimed.receipt["subject"]["verification"]["outcome"] == "not_claimed"
    end
  end

  describe "Requalification (§119, §120)" do
    test "maps changed identity fields to dependent gates, fail closed on unknown fields" do
      assert Requalification.gates_for_fields([]) == []
      assert Requalification.gates_for_fields(["tag"]) == [1]
      assert Requalification.gates_for_fields(["validator_digests"]) == [1, 2, 5, 12]
      assert Requalification.gates_for_fields(["root_manifest_digest"]) == [1, 2, 5, 9, 10, 11]
      assert Requalification.gates_for_fields(["source_revision"]) == Enum.to_list(1..12)
      assert Requalification.gates_for_fields(["something_new"]) == Enum.to_list(1..12)
    end

    test "version ordering never changes the requalification set", %{tmp_dir: dir} do
      release = Fx.release!(dir, "order")
      base = Subject.capture(release.subject_opts)
      newer = %{base | version: "26.9.17"}
      older = %{base | version: "26.9.15"}

      assert Requalification.dependent_gates(base, newer) == [1]
      assert Requalification.dependent_gates(base, older) == [1]
      assert Requalification.dependent_gates(base, base) == []
      assert Requalification.changed_fields(base, newer) == ["version"]
    end

    test "a tampered prior receipt is never reused", %{tmp_dir: dir} do
      release = Fx.release!(dir, "tamper")

      {:ok, run} =
        Runner.run(courts: [], subject_opts: release.subject_opts, evidence_dir: dir)

      receipt = JSON.decode!(File.read!(Path.join(dir, "standing_receipt.json")))
      subject = Subject.capture(release.subject_opts)

      assert {:reuse, "UNKNOWN"} = Requalification.decide(receipt, subject)
      assert run.receipt["receipt_digest"] == receipt["receipt_digest"]

      tampered = Map.put(receipt, "standing", "CONFORMANT")

      assert {:requalify, %{fields: ["receipt_digest"], gates: gates}} =
               Requalification.decide(tampered, subject)

      assert gates == Enum.to_list(1..12)
    end
  end

  describe "SA2A runtime identity (§126)" do
    test "label keys collapse whitespace, case, width and zero-width variants only" do
      key = RuntimeIdentity.label_key("BEAM/Wasmex")

      for variant <- [
            "BEAM/Wasmex ",
            " beam/wasmex",
            "BEAM /\tWASMEX",
            "ＢＥＡＭ/Wasmex",
            "BEAM/​Wasmex"
          ] do
        assert RuntimeIdentity.label_key(variant) == key, inspect(variant)
      end

      refute RuntimeIdentity.label_key("BEAM/Wasmex(degraded)") == key
      refute RuntimeIdentity.label_key("Node/StandaloneJS") == key
    end

    test "the padded host label is refused as degenerate before any runtime opens" do
      assert {:error, reason} =
               Conformance.run(runtime_a: WasmexSession, runtime_b: Fx.PaddedHostRuntime)

      assert reason.code == :sa2a_identical_runtimes
      assert reason.basis == :label
    end

    test "observed identity separates the in-BEAM and out-of-BEAM hosts and joins relabelled ones" do
      if runtimes_available?() do
        {:ok, %{session: wasmex}} = WasmexSession.open([])
        {:ok, %{session: relabelled}} = Fx.RelabelledHostRuntime.open([])
        {:ok, %{session: node}} = RuntimeB.open([])

        try do
          assert {:ok, [%{"kind" => "beam_process"} = beam]} =
                   RuntimeIdentity.observe_session(wasmex)

          assert beam["engine_application"] == "wasmex"
          assert {:ok, [%{"kind" => "os_process"}]} = RuntimeIdentity.observe_session(node)

          assert RuntimeIdentity.observe_session(wasmex) ==
                   RuntimeIdentity.observe_session(relabelled)

          refute RuntimeIdentity.observe_session(wasmex) == RuntimeIdentity.observe_session(node)
          assert {:unobservable, _} = RuntimeIdentity.observe_session(%{no: :resources})
        after
          WasmexSession.close(wasmex)
          Fx.RelabelledHostRuntime.close(relabelled)
          RuntimeB.close(node)
        end
      else
        IO.puts("skipped: real wasm/node runtimes unavailable")
      end
    end
  end
end

# --- SECTION 2: Original test/ash_a2a/chicago/logic_sparql_test.exs ---
defmodule AshA2A.Chicago.LogicSparqlTest do
  @moduledoc """
  SA2A-LOGIC and SA2A-SPARQL courts end to end, plus narrow Chicago-style unit
  tests for the boundaries they qualify: `AshA2A.Semantic.LogicClosure` (real
  vendored praxis-graphlaw wasm in Wasmtime), its `RuleDocument` recogniser,
  the bounded `AshA2A.GraphLaw.WasmexSession`, and the repaired
  `AshA2A.Semantic.FalsifierSuite.check_update/2`.

  `async: false`: the observer attributes every telemetry event between a
  stimulus start and stop to that falsifier, and the unit tests below attach
  their own telemetry handlers to the same boundary events.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  alias AshA2A.Chicago.Courts.{SafeLogic, SparqlFalsifiers}
  alias AshA2A.Chicago.Fixtures.LogicSparql, as: F
  alias AshA2A.Chicago.{Result, Runner, StandingReceipt}
  alias AshA2A.GraphLaw.WasmexSession
  alias AshA2A.Semantic.{FalsifierSuite, LogicClosure, Refusal}
  alias AshA2A.Semantic.LogicClosure.{Program, RuleDocument}

  @moduletag :tmp_dir

  describe "the courts over the real SUT" do
    @tag :graphlaw
    @tag timeout: 600_000
    test "every falsifier reaches its final verdict and every pass is OCEL-corroborated",
         %{tmp_dir: dir} do
      assert {:ok, run} =
               Runner.run(
                 courts: [SafeLogic, SparqlFalsifiers],
                 profile: :logic,
                 evidence_dir: dir
               )

      declared = Enum.flat_map([SafeLogic, SparqlFalsifiers], & &1.falsifiers())
      by_id = Map.new(run.results, &{&1.falsifier_id, &1})

      assert map_size(by_id) == length(declared) and length(declared) == 43

      for falsifier <- declared do
        result = Map.fetch!(by_id, falsifier.id)

        expected =
          case falsifier.kind do
            :negative -> :falsifier_killed
            :positive_control -> :positive_control_passed
            :measurement -> :measured
          end

        assert result.verdict == expected,
               "#{falsifier.id}: #{result.verdict} #{inspect(result.detail)} #{inspect(result.ocel_detail)} #{inspect(result.evidence)}"

        assert result.ocel_corroborated? == true,
               "#{falsifier.id}: #{inspect(result.ocel_detail)}"

        assert Result.counts_as_pass?(result)
      end

      receipt = JSON.decode!(File.read!(Path.join(dir, "standing_receipt.json")))
      assert :ok = StandingReceipt.verify_digest(receipt)
      assert receipt["results"]["falsifiers_survived"] == 0
      assert receipt["results"]["survived_ids"] == []
      assert receipt["results"]["unresolved_ids"] == []
      assert receipt["results"]["measured"] == 3
      assert run.ocel.dropped == 0

      # B2 records are real, terminating runs with deterministic fuel.
      for id <- ["SA2A-LOGIC-023", "SA2A-LOGIC-024", "SA2A-LOGIC-025"] do
        m = by_id[id].measurements
        assert m["benchmark_id"] == "SA2A-B2"
        assert m["fuel_deterministic"] == true
        assert m["digest_stable"] == true
        assert m["fact_count_after"] == m["fact_count_before"] + m["derived_count"]
        assert m["fuel_consumed"] < m["fuel_budget"]
        assert is_integer(m["wall_us_p95"]) and is_integer(m["peak_linear_memory_bytes"])
      end

      assert by_id["SA2A-LOGIC-024"].measurements["derived_count"] == F.chain_derived(40)
      assert by_id["SA2A-LOGIC-025"].measurements["derived_count"] == F.chain_derived(90)
      assert by_id["SA2A-LOGIC-014"].evidence["network_connections_during_closure"] == 0
      assert by_id["SA2A-LOGIC-018"].evidence["row_present"] == false
      assert by_id["SA2A-LOGIC-019"].evidence["row_present"] == true
    end

    test "both courts are discoverable with their assigned ids and profiles" do
      courts = AshA2A.Chicago.courts()
      assert SafeLogic in courts and SparqlFalsifiers in courts
      assert {SafeLogic.id(), SafeLogic.profile()} == {"SA2A-LOGIC", :logic}
      assert {SparqlFalsifiers.id(), SparqlFalsifiers.profile()} == {"SA2A-SPARQL", :core}
      refute SafeLogic in AshA2A.Chicago.courts_for(:core)

      for court <- [SafeLogic, SparqlFalsifiers], f <- court.falsifiers() do
        assert String.starts_with?(f.id, court.id() <> "-")
        assert f.attempt_predicate != nil
        assert f.kind == :measurement or f.outcome_predicate != nil
      end
    end
  end

  describe "LogicClosure over the real engine" do
    setup do
      admitted = LogicClosure.admitted_rule_set([F.transitive_rules(), F.unsafe_rules()])
      {:ok, opts: [admitted_rules: admitted], events: capture_closure_events()}
    end

    test "an admitted safe program closes to its least fixpoint as a candidate", %{opts: opts} do
      program = %Program{facts: F.chain_facts(6), rules: F.transitive_rules()}
      assert {:ok, closure} = LogicClosure.close(program, opts)

      assert closure.derived_count == F.chain_derived(6)
      assert closure.fact_count_before == 5
      assert closure.fact_count_after == 5 + F.chain_derived(6)
      assert {closure.standing, closure.authority} == {:candidate, :none}
      assert closure.fuel_consumed > 0 and closure.fuel_consumed < closure.fuel_budget

      assert closure.wasm_digest ==
               AshA2A.GraphLaw.Manifest.sha256_hex(File.read!(AshA2A.GraphLaw.wasm_path()))
    end

    test "entailment is decided by the engine over the closure", %{opts: opts} do
      program = %Program{facts: F.chain_facts(4), rules: F.transitive_rules()}
      ns = F.ns()

      assert {:ok, true} =
               LogicClosure.entails?(
                 program,
                 "<#{ns}n1> <#{ns}edge> ?o . ?o <http://www.w3.org/2000/10/swap/log#equalTo> <#{ns}n4>",
                 opts
               )

      assert {:ok, false} = LogicClosure.entails?(program, "<#{ns}n4> <#{ns}edge> ?o", opts)

      assert {:error, %{code: :refused_entailment_witness}} =
               LogicClosure.entails?(program, "<#{ns}n1> <#{ns}edge> <#{ns}n2>", opts)
    end

    test "replay agrees across fact order and refuses a different subject", %{opts: opts} do
      program = %Program{facts: F.chain_facts(8), rules: F.transitive_rules()}
      {:ok, closure} = LogicClosure.close(program, opts)

      assert {:ok, again} =
               LogicClosure.replay(closure, %{program | facts: F.chain_facts(8, :reverse)}, opts)

      assert again.closure_digest == closure.closure_digest

      assert {:error, %{code: :refused_replay_subject_mismatch, field: :facts_canonical_hash}} =
               LogicClosure.replay(closure, %{program | facts: F.chain_facts(9)}, opts)
    end

    test "gates refuse before the engine runs", %{opts: opts, events: events} do
      program = %Program{facts: F.chain_facts(4), rules: F.unsafe_rules()}

      assert {:error, %{code: :refused_rule_not_range_restricted, stage: :rule_shape}} =
               LogicClosure.close(program, opts)

      assert {:error, %{code: :refused_unadmitted_rule}} =
               LogicClosure.close(%{program | rules: F.existential_rules()}, opts)

      assert {:error, %{code: :refused_facts_not_plain_rdf}} =
               LogicClosure.close(
                 %Program{facts: F.smuggled_facts(:implication), rules: F.transitive_rules()},
                 opts
               )

      seen = events.()
      assert Enum.count(seen, &(&1.event == :stop and &1.meta.outcome == :refused)) == 3
      refute Enum.any?(seen, &(&1.event == :engine))
    end

    test "unbounded term creation is refused by the deterministic fuel bound", %{events: events} do
      program = %Program{facts: F.unbounded_sum_facts(), rules: F.unbounded_sum_rules()}

      opts = [
        admitted_rules: LogicClosure.admitted_rule_set([F.unbounded_sum_rules()]),
        fuel: 50_000_000
      ]

      assert {:error, %{code: :refused_closure_bound_exceeded, bound: :fuel}} =
               LogicClosure.close(program, opts)

      assert [%{meta: %{outcome: :bound_exceeded, fuel_consumed: 50_000_000}}] =
               Enum.filter(events.(), &(&1.event == :engine))
    end

    test "every new refusal code is classified without editing the Refusal table" do
      for {code, class} <- LogicClosure.__sa2a_refusal_codes__() do
        assert Refusal.classify(code) == class
      end
    end
  end

  describe "RuleDocument recogniser" do
    @p "@prefix e: <http://e/> .\n"

    test "admits range-restricted, function-free rules with pure builtins" do
      doc =
        @p <>
          "@prefix math: <http://www.w3.org/2000/10/swap/math#> .\n" <>
          "{ ?x e:n ?n . (?n 1) math:sum ?m } => { ?x e:m ?m } .\n" <>
          "{ ?x e:p ?y } => false .\n{ ?x e:q ?y } <= { ?y e:p ?x } ."

      assert {:ok, %{rules: [%{kind: :forward}, %{kind: :denial}, %{kind: :backward}]}} =
               RuleDocument.check(doc)
    end

    test "refuses unsafe, existential, list and formula heads" do
      for {body, code} <- [
            {"{ ?x e:p ?y } => { ?x e:q ?w } .", :rule_not_range_restricted},
            {"{ ?x e:p ?y } => { ?x e:q [ e:r ?y ] } .", :rule_not_function_free},
            {"{ ?x e:p ?y } => { ?x e:q _:b } .", :rule_not_function_free},
            {"{ ?x e:p ?y } => { ?x e:q (?y) } .", :rule_not_function_free},
            {"{ ?x e:p ?y } => { ?x e:says { ?y e:p ?x } } .", :rule_not_function_free}
          ] do
        assert {:error, %{code: ^code}} = RuleDocument.check(@p <> body), body
      end
    end

    test "refuses side-effecting builtins in every spelling and hook vocabulary" do
      for doc <- [
            "@prefix log: <http://www.w3.org/2000/10/swap/log#> .\n{ ?u log:semantics ?f } => { ?u e:f ?f } .",
            "@prefix x: <http://www.w3.org/2000/10/swap/log#> .\n{ ?u x:outputString ?f } => { ?u e:f ?f } .",
            "{ ?u <http://www.w3.org/2000/10/swap/os#environ> ?f } => { ?u e:f ?f } .",
            "{ ?u <http://www.w3.org/2000/10/swap/log#conclusion> ?f } => { ?u e:f ?f } ."
          ] do
        assert {:error, %{code: :unadmitted_builtin}} = RuleDocument.check(@p <> doc), doc
      end

      assert {:error, %{code: :hook_in_rule_document}} =
               RuleDocument.check(
                 @p <>
                   "{ ?h a <http://seanchatmangpt.github.io/praxis/kh#Hook> } => { ?h e:ok ?h } ."
               )
    end

    test "refuses what it cannot classify instead of guessing" do
      for doc <- [
            "@base <http://e/> .\n{ ?x <p> ?y } => { ?x <q> ?y } .",
            "PREFIX e: <http://e/>\n{ ?x e:p ?y } => { ?x e:q ?y } .",
            "{ ?x <p> ?y } => { ?x <http://e/q> ?y } .",
            "{ ?x z:p ?y } => { ?x z:q ?y } .",
            @p <> "@prefix e: <http://other/> .\n{ ?x e:p ?y } => { ?x e:q ?y } .",
            @p <> "e:a e:p e:b .",
            @p <> "{ ?x <http://e/\\u0070> ?y } => { ?x e:q ?y } .",
            @p <> "{ ?x e:p ?y } => { ?x e:q ?y }"
          ] do
        assert {:error, %{code: :rule_document_unclassifiable}} = RuleDocument.check(doc), doc
      end
    end
  end

  describe "bounded WasmexSession" do
    test "reports the pinned import surface and traps when fuel runs out" do
      {:ok, %{session: session}} =
        WasmexSession.open(wasm_path: AshA2A.GraphLaw.wasm_path(), fuel: 1_000_000_000)

      try do
        assert session.module_imports == WasmexSession.pinned_imports()

        assert {:ok, hash} =
                 WasmexSession.call(session, :graph_hash, ["<urn:a> <urn:b> <urn:c> ."])

        assert byte_size(hash) == 64
        assert WasmexSession.fuel_remaining(session) < 1_000_000_000

        :ok = Wasmex.StoreOrCaller.set_fuel(session.store, 1_000)

        # The trap lands in the export or in an ABI setup call sharing its fuel.
        assert {:error, %{code: code} = error} =
                 WasmexSession.call(session, :graph_hash, ["<urn:a> <urn:b> <urn:c> ."])

        assert code in [:graphlaw_call_trapped, :graphlaw_call_raised]
        assert inspect(error) =~ "fuel"
      after
        WasmexSession.close(session)
      end
    end
  end

  describe "check_update/2 repairs (SA2A-SPARQL-011..015, 018)" do
    setup do
      {:ok, graph: F.update_classification(), events: capture_update_events()}
    end

    test "every court-found bypass is now refused", %{graph: graph} do
      for attack <- [
            :escaped_keyword,
            :escaped_default_operand,
            :mixed_quad_data,
            :mixed_modify_template,
            :with_scope_leak,
            :long_literal_desync
          ] do
        assert {:error, %{code: :refused_sparql_update_on_canonical}} =
                 FalsifierSuite.check_update(graph, F.update(attack)),
               "#{attack} was admitted"
      end
    end

    test "staging-only updates stay admitted, including escaped and multi-block forms", %{
      graph: graph
    } do
      staging = F.staging_graph()

      for update <- [
            F.update(:staging_insert_data),
            F.update(:staging_modify_with),
            "\\u0049NSERT DATA { GRAPH <#{staging}> { <urn:a> <urn:b> <urn:c> } }",
            "INSERT DATA { GRAPH <#{staging}> { <urn:a> <urn:b> <urn:c> } . GRAPH <#{staging}> { <urn:d> <urn:e> \"}{\" } }",
            ~s(INSERT DATA { GRAPH <#{staging}> { <urn:a> <urn:b> """x" { "y""" } }),
            "INSERT DATA { GRAPH <#{staging}> { <urn:a> <urn:b> <urn:c> } } ; DROP SILENT GRAPH <#{staging}>",
            "WITH <#{staging}> DELETE { ?s ?p ?o } WHERE { ?s ?p ?o FILTER(?o < 5) } ; WITH <#{staging}> INSERT { ?s ?p 1 } WHERE { ?s ?p ?o }"
          ] do
        assert :ok = FalsifierSuite.check_update(graph, update), update
      end
    end

    test "a comparison operator cannot turn comments into structure", %{graph: graph} do
      staging = F.staging_graph()

      update =
        "WITH <#{staging}> DELETE { ?s ?p ?o } WHERE { ?s ?p ?o FILTER(?o < 5) # {\n} ; INSERT { ?s ?p ?o } WHERE { } # }"

      assert {:error, %{code: :refused_sparql_update_on_canonical}} =
               FalsifierSuite.check_update(graph, update)
    end

    test "the decision is emitted at the boundary", %{graph: graph, events: events} do
      FalsifierSuite.check_update(graph, F.update(:escaped_keyword))
      FalsifierSuite.check_update(graph, F.update(:staging_insert_data))

      assert [
               %{outcome: :refused, mutating: true, form: "INSERT DATA"},
               %{outcome: :admitted, mutating: true}
             ] = events.()
    end
  end

  # --- real telemetry collectors ---------------------------------------------

  defp capture_closure_events do
    capture(for(e <- [:start, :decision, :engine, :stop], do: [:ash_a2a, :logic, :closure, e]), fn
      [:ash_a2a, :logic, :closure, event], meta -> %{event: event, meta: meta}
    end)
  end

  defp capture_update_events do
    capture([[:ash_a2a, :semantic, :sparql_update, :decision]], fn _event, meta -> meta end)
  end

  defp capture(events, shape) do
    ref = make_ref()
    handler = {__MODULE__, ref}
    config = %{parent: self(), ref: ref, shape: shape}

    :ok = :telemetry.attach_many(handler, events, &__MODULE__.forward_event/4, config)
    on_exit(fn -> :telemetry.detach(handler) end)

    fn -> collect(ref, []) end
  end

  @doc false
  def forward_event(event, _measurements, meta, %{parent: parent, ref: ref, shape: shape}) do
    if self() == parent, do: send(parent, {ref, shape.(event, meta)})
  end

  defp collect(ref, acc) do
    receive do
      {^ref, item} -> collect(ref, [item | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end

# --- SECTION 3: Original test/ash_a2a/chicago/mutation_harness_test.exs ---

# --- SECTION 4: Original test/ash_a2a/chicago/observer_qualification_test.exs ---
defmodule AshA2A.Chicago.ObserverQualificationTest do
  @moduledoc """
  RFC-SA2A-002 §19, §20, §107, §108, §138, §139: process observer
  qualification, Chicago style. The court runs through the real
  `AshA2A.Chicago.Runner`; the narrow tests exercise the real observer,
  journal, mapping validation, independent consumer and standing function
  with real processes, real files and real telemetry -- no doubles.

  `async: false`: observers attach global telemetry handlers and attribute by
  stimulus interval.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  alias AshA2A.Chicago.{Observer, Query, Result, Runner, StandingReceipt, Subject}
  alias AshA2A.Chicago.Courts.ObserverQualification
  alias AshA2A.Chicago.Fixtures.ObserverQualification, as: Fx
  alias AshA2A.Chicago.Observer.{Journal, NonAuthority}
  alias AshA2A.Chicago.Ocel.{Mapping, SutEvents, SutMappings}

  @moduletag :tmp_dir
  @moduletag timeout: 300_000

  describe "SA2A-OCEL-OBSERVER through the real Runner" do
    test "every falsifier is killed, every control passes, all corroborated by the independent consumer",
         %{tmp_dir: dir} do
      assert {:ok, run} =
               Runner.run(courts: [ObserverQualification], profile: :core, evidence_dir: dir)

      by_id = Map.new(run.results, &{&1.falsifier_id, &1})
      assert map_size(by_id) == 14

      for n <- 1..9 do
        id = "SA2A-OCEL-OBSERVER-" <> String.pad_leading("#{n}", 3, "0")
        result = Map.fetch!(by_id, id)

        assert result.verdict == :falsifier_killed,
               "#{id}: #{result.verdict} #{inspect(result.evidence)} #{result.ocel_detail}"

        assert result.attempt_observed? == true, id
        assert result.ocel_corroborated? == true, "#{id}: #{result.ocel_detail}"
      end

      for n <- 10..14 do
        id = "SA2A-OCEL-OBSERVER-0" <> Integer.to_string(n)
        result = Map.fetch!(by_id, id)

        assert result.verdict == :positive_control_passed,
               "#{id}: #{result.verdict} #{inspect(result.evidence)} #{result.ocel_detail}"

        assert result.ocel_corroborated? == true, "#{id}: #{result.ocel_detail}"
      end

      # The run's own observer stayed whole while the court disturbed others.
      assert run.ocel.dropped == 0
      assert run.ocel.gaps == 0

      receipt = JSON.decode!(File.read!(Path.join(dir, "standing_receipt.json")))
      assert :ok = StandingReceipt.verify_digest(receipt)
      assert receipt["evidence"]["ocel_dropped_records"] == 0
      assert receipt["evidence"]["ocel_gaps"] == 0
      assert receipt["results"]["falsifiers_killed"] == 9
      assert receipt["results"]["positive_controls_passed"] == 5
      # Core gates 1-3 are not this court's: honest PARTIAL_ALIVE.
      assert receipt["standing"] == "PARTIAL_ALIVE"

      # The observer outage evidence is on disk, not in memory.
      killed =
        JSON.decode!(
          File.read!(
            Path.join([dir, "observer_qualification", "001-killed", "standing_receipt.json"])
          )
        )

      assert killed["evidence"]["ocel_dropped_records"] > 0
      assert killed["evidence"]["ocel_gaps"] >= 1
      refute killed["standing"] == "CONFORMANT"
    end
  end

  describe "standing" do
    test "CONFORMANT is reachable only with zero dropped records and zero observer gaps" do
      [f | _] = ObserverQualification.falsifiers()

      results =
        for gate <- 1..3 do
          %{
            Result.negative(f, attempt_observed?: true, forbidden_outcome_observed?: false)
            | gate: gate,
              ocel_corroborated?: true
          }
        end

      input = fn ocel ->
        %{
          profile: :core,
          subject: Subject.capture(),
          courts: [ObserverQualification],
          falsifiers: ObserverQualification.falsifiers(),
          results: results,
          ocel:
            Map.merge(
              %{sha256: "0", bytes: 1, events: 1, objects: 1, mapping_digest: "m"},
              ocel
            ),
          ocel_validation: %{status: :valid, validator: "independent", report: %{}},
          run_id: "standing-unit"
        }
      end

      assert StandingReceipt.build(input.(%{dropped: 0, gaps: 0}))["standing"] == "CONFORMANT"
      refute StandingReceipt.build(input.(%{dropped: 1, gaps: 0}))["standing"] == "CONFORMANT"
      refute StandingReceipt.build(input.(%{dropped: 0, gaps: 1}))["standing"] == "CONFORMANT"
    end
  end

  describe "observer" do
    test "a killed observer is replaced by a recovery incarnation that restores the journal and records the gap",
         %{tmp_dir: dir} do
      run_id = "unit-recovery-#{System.unique_integer([:positive])}"

      opts = [
        run_id: run_id,
        mappings: [Fx.probe_mapping()],
        journal: Observer.journal_path(dir, run_id),
        delivery_timeout_ms: 500
      ]

      {:ok, first} = Observer.start(opts)
      for i <- 1..3, do: Fx.probe(%{probe_id: "p#{i}", i: i})
      ref = Process.monitor(first)
      Process.exit(first, :kill)
      assert_receive {:DOWN, ^ref, :process, _, :killed}
      for i <- 4..5, do: Fx.probe(%{probe_id: "p#{i}", i: i})

      second = Observer.ensure_running(first, opts)
      refute second == first
      assert Observer.ensure_running(second, opts) == second

      stats = Observer.stats(second)
      assert stats.incarnation == 2
      assert stats.gaps == 1
      assert stats.dropped == 2
      assert stats.harvested_handlers == 1

      {:ok, flush} = Observer.flush(second, dir)
      Observer.stop_run(run_id)

      doc = JSON.decode!(File.read!(flush.path))
      assert Enum.count(doc["events"], &(&1["type"] == "fixture.probe")) == 3
      assert Enum.count(doc["events"], &(&1["type"] == "chicago.observer.gap")) == 1
      assert flush.gaps == 1 and flush.dropped == 2

      assert [] ==
               :telemetry.list_handlers([])
               |> Enum.filter(&match?(%{id: {Observer, ^run_id, _, _}}, &1))
    end

    test "attribution follows chicago_seq intervals, not delivery order" do
      start = %{seq: 10, activity: "chicago.stimulus.start", falsifier_id: "F", court_id: "C"}
      stop = %{seq: 20, activity: "chicago.stimulus.stop", falsifier_id: "F", court_id: "C"}
      before = %{seq: 5, activity: "x", falsifier_id: nil, court_id: nil}
      inside = %{seq: 15, activity: "x", falsifier_id: nil, court_id: nil}
      gap = %{seq: 12, activity: "chicago.observer.gap", falsifier_id: nil, court_id: nil}

      # Arrival order: start, the pre-stimulus record, inside, stop.
      arrived = [start, before, inside, stop]

      attributed =
        arrived |> Enum.sort_by(& &1.seq) |> Observer.attribute() |> Map.new(&{&1.seq, &1})

      assert attributed[5].falsifier_id == nil
      assert attributed[15].falsifier_id == "F"

      # A gap closes the interval: the stop may have been lost.
      after_gap = [start, gap, inside, stop] |> Enum.sort_by(& &1.seq) |> Observer.attribute()
      assert Enum.find(after_gap, &(&1.seq == 15)).falsifier_id == nil
    end

    test "observers watching each other's boundary events while both are dead do not recurse" do
      ids = for n <- 1..2, do: "unit-mutual-#{n}-#{System.unique_integer([:positive])}"

      pids =
        for run_id <- ids do
          {:ok, pid} =
            Observer.start(
              run_id: run_id,
              mappings: [Fx.probe_mapping()],
              watch_events: Observer.boundary_events(),
              delivery_timeout_ms: 100
            )

          pid
        end

      for pid <- pids do
        ref = Process.monitor(pid)
        Process.exit(pid, :kill)
        assert_receive {:DOWN, ^ref, :process, _, _}
      end

      task = Task.async(fn -> Fx.probe(%{probe_id: "loop-1"}) end)
      assert :ok = Task.await(task, 5_000)

      drops =
        []
        |> :telemetry.list_handlers()
        |> Enum.uniq_by(& &1.id)
        |> Enum.filter(fn %{id: id} -> match?({Observer, _, _, _}, id) and elem(id, 1) in ids end)
        |> Enum.map(&:counters.get(&1.config.counters, 1))

      # Each dead observer: the probe, plus the other observer's single
      # `dropped` boundary event -- which is never re-emitted.
      assert drops == [2, 2]
      Enum.each(ids, &Observer.stop_run/1)
    end

    test "unmapped watched telemetry becomes a typed chicago.unmapped event", %{tmp_dir: dir} do
      run_id = "unit-unmapped-#{System.unique_integer([:positive])}"
      event = Fx.event(:unit_unmapped)
      {:ok, pid} = Observer.start(run_id: run_id, watch_events: [event])
      Fx.emit(event, %{n: 1}, %{kind: :novel, pid: self()})
      {:ok, flush} = Observer.flush(pid, dir)
      Observer.stop_run(run_id)

      assert flush.unmapped == 1
      doc = JSON.decode!(File.read!(flush.path))
      [unmapped] = Enum.filter(doc["events"], &(&1["type"] == "chicago.unmapped"))
      attrs = Map.new(unmapped["attributes"], &{&1["name"], &1["value"]})
      assert attrs["telemetry_event"] == Enum.join(event, ".")
      assert attrs["meta.kind"] == "novel"
      assert attrs["measure.n"] == 1
      refute Map.has_key?(attrs, "meta.pid")
    end
  end

  describe "mapping reference validation" do
    test "absent ids are skipped, malformed and reserved references are rejected, unusual valid ones kept" do
      assert :absent = Mapping.validate_ref({"widget", nil, "q"})
      assert {:ok, {"widget", "42", "q"}} = Mapping.validate_ref({"widget", 42, "q"})
      assert {:ok, {"nebula", "a:b", "q"}} = Mapping.validate_ref({:nebula, "a:b", :q})

      assert {:ok, {"principal", "p-1", "actor"}} =
               Mapping.validate_ref({"principal", AshA2A.Identity.principal("p-1"), "actor"})

      assert {:rejected, :malformed_id, "widget"} = Mapping.validate_ref({"widget", "", "q"})

      assert {:rejected, :malformed_id, "widget"} =
               Mapping.validate_ref({"widget", <<0xFF>>, "q"})

      assert {:rejected, :malformed_id, "widget"} = Mapping.validate_ref({"widget", %{a: 1}, "q"})
      assert {:rejected, :malformed_type, nil} = Mapping.validate_ref({"command:a", "b", "q"})
      assert {:rejected, :malformed_type, nil} = Mapping.validate_ref({42, "b", "q"})

      assert {:rejected, :reserved_type, "falsifier"} =
               Mapping.validate_ref({"falsifier", "F", "q"})

      assert {:rejected, :malformed_qualifier, "widget"} =
               Mapping.validate_ref({"widget", "w", 1})

      assert {:rejected, :malformed_shape, nil} = Mapping.validate_ref({:only, :two})
    end
  end

  describe "journal" do
    test "restores verified lines and counts corrupt, torn and duplicate lines", %{tmp_dir: dir} do
      path = Path.join(dir, "unit-journal.jsonl")
      {:ok, j} = Journal.open(path, :every_record)
      {:ok, j} = Journal.append(j, %{"kind" => "header", "run_id" => "r", "incarnation" => 1})

      record = fn seq ->
        %{
          seq: seq,
          event: [:ash_a2a, :unit],
          activity: "unit",
          time_us: 1,
          attributes: %{"f" => 1.5, "s" => "v"},
          objects: [{"t", "id", "q"}],
          falsifier_id: nil,
          court_id: nil,
          run_id: nil
        }
      end

      {:ok, j} = Journal.append(j, Journal.record_entry(record.(1)))
      {:ok, j} = Journal.append(j, Journal.record_entry(record.(2)))
      {:ok, j} = Journal.append(j, Journal.record_entry(record.(2)))
      :ok = Journal.close(j)

      bytes = File.read!(path)
      tampered = String.replace(bytes, ~s("s":"v"), ~s("s":"w"), global: false)
      File.write!(path, tampered <> ~s({"kind":"rec))

      assert {:ok, recovered} = Journal.recover(path)
      assert recovered.run_ids == ["r"]
      assert recovered.incarnations == 1
      assert Enum.map(recovered.records, & &1.seq) == [2]
      assert hd(recovered.records).attributes == %{"f" => 1.5, "s" => "v"}
      assert recovered.corrupt_lines == 2
      assert recovered.duplicate_lines == 1
      assert recovered.torn_tail

      # Reopening terminates the torn tail so new lines never fuse with it.
      {:ok, j} = Journal.open(path)
      {:ok, j} = Journal.append(j, Journal.record_entry(record.(3)))
      :ok = Journal.close(j)
      assert {:ok, again} = Journal.recover(path)
      assert Enum.map(again.records, & &1.seq) == [2, 3]
      refute again.torn_tail
    end
  end

  describe "independent consumer" do
    test "refuses duplicated event identities and reports content duplicates", %{tmp_dir: dir} do
      run_id = "unit-dup-#{System.unique_integer([:positive])}"
      {:ok, pid} = Observer.start(run_id: run_id, mappings: [Fx.probe_mapping()])
      Fx.probe(%{probe_id: "same", i: 1})
      Fx.probe(%{probe_id: "same", i: 1})
      {:ok, flush} = Observer.flush(pid, dir)
      Observer.stop_run(run_id)

      assert {:ok, index} = Query.load(flush.path, flush.sha256)
      assert [%{type: "fixture.probe", count: 2, seqs: [a, b]}] = Query.duplicates(index)
      assert a != b

      doc = JSON.decode!(File.read!(flush.path))
      dup = Path.join(dir, "dup.json")
      File.write!(dup, JSON.encode!(%{doc | "events" => doc["events"] ++ [hd(doc["events"])]}))
      assert {:error, {:ocel_duplicate_event_identity, _}} = Query.load(dup)
    end
  end

  describe "static proofs" do
    test "the observer closure is proved non-authoritative and discovery sees unmapped SUT telemetry" do
      assert %{outcome: :proved, violations: [], unprovable: []} =
               NonAuthority.prove(NonAuthority.default_scope(SutMappings.mappings()))

      assert NonAuthority.forbidden?(AshA2A.CommandBus)
      assert NonAuthority.forbidden?(AshA2A.Authority.Broker.InMemory)
      refute NonAuthority.forbidden?(AshA2A.Chicago.Query)

      unmapped = SutEvents.unmapped(SutMappings.mappings())
      assert [:ash_a2a, :ocel, :shed] in unmapped
      refute [:ash_a2a, :receipt, :committed] in unmapped
      refute Enum.any?(unmapped, &match?([:ash_a2a, :chicago, :fixtures | _], &1))
    end
  end
end

# --- SECTION 5: Original test/ash_a2a/chicago/ocel_validator_test.exs ---
defmodule AshA2A.Chicago.OcelValidatorTest do
  @moduledoc """
  Qualifies `AshA2A.Chicago.Ocel.Validator` and the `SA2A-OCEL` court,
  Chicago style: the court end-to-end over the real `AshA2A.CommandBus`, a
  real `AshA2A.Chicago.Observer`, durable artifacts on disk, the real
  validator deciding, and the independent `AshA2A.Chicago.Query` consumer
  corroborating every verdict. Narrow tests exercise each validator guard over
  real files in `tmp_dir`, one defect at a time, so deleting a guard makes its
  test fail (§22).

  `async: false` -- `Context.stimulus/3` attribution and the observer's
  telemetry handlers see every event the node emits.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  alias AshA2A.Chicago.{Context, Observer, Result, Runner, StandingReceipt}
  alias AshA2A.Chicago.Courts.OcelValidity
  alias AshA2A.Chicago.Ocel.{Log, Mapping, Validator}

  @moduletag :tmp_dir

  @negatives ~w(002 003 004 005 006 007 008 009 010 013 014 015 016 017 018 019 020 021)
  @positives ~w(001 011 012)

  describe "SA2A-OCEL end-to-end through the runner" do
    test "every falsifier is killed, every positive control passes, all OCEL-corroborated",
         %{tmp_dir: dir} do
      assert {:ok, run} = Runner.run(courts: [OcelValidity], profile: :core, evidence_dir: dir)

      by_id = Map.new(run.results, &{&1.falsifier_id, &1})
      assert map_size(by_id) == length(@negatives) + length(@positives)
      assert Enum.sort(Map.keys(by_id)) == Enum.sort(Enum.map(OcelValidity.falsifiers(), & &1.id))

      for n <- @negatives do
        result = by_id["SA2A-OCEL-" <> n]

        assert result.verdict == :falsifier_killed,
               "SA2A-OCEL-#{n}: #{result.verdict} #{result.detail} | #{result.ocel_detail}"

        assert result.attempt_observed? == true
        assert result.ocel_corroborated? == true, "SA2A-OCEL-#{n}: #{result.ocel_detail}"
        assert Result.counts_as_pass?(result)
      end

      for n <- @positives do
        result = by_id["SA2A-OCEL-" <> n]

        assert result.verdict == :positive_control_passed,
               "SA2A-OCEL-#{n}: #{result.verdict} #{result.detail} | #{result.ocel_detail}"

        assert result.ocel_corroborated? == true, "SA2A-OCEL-#{n}: #{result.ocel_detail}"
      end

      # The run's own artifact is validated by the same independent validator
      # and the standing receipt binds that result (§16, §104).
      assert run.ocel_validation.status == :valid, inspect(run.ocel_validation.report)
      receipt = JSON.decode!(File.read!(Path.join(dir, "standing_receipt.json")))
      assert :ok = StandingReceipt.verify_digest(receipt)
      assert receipt["evidence"]["ocel_valid"] == true
      assert receipt["evidence"]["ocel_validator"] == inspect(Validator)
      assert receipt["results"]["falsifiers_survived"] == 0
      assert receipt["results"]["falsifiers_killed"] == length(@negatives)
      assert receipt["results"]["positive_controls_passed"] == length(@positives)

      validation = JSON.decode!(File.read!(Path.join(dir, "ocel_validation.json")))
      assert validation["status"] == "valid"
      assert validation["report"]["artifact_sha256"] == run.ocel.sha256
      assert validation["report"]["validator"]["name"] == inspect(Validator)

      # The base evidence is real SUT process history: object-centric (§107),
      # and the refused command wrote no row (independent reader).
      base = by_id["SA2A-OCEL-001"]
      assert base.evidence["refused_row_absent"] == true

      assert Enum.all?(
               ~w(capability command principal),
               &(&1 in base.evidence["admission_object_types"])
             )

      assert base.evidence["reply_code"] == ":authority_required"
    end
  end

  describe "validate_file/1 over a real producer artifact" do
    test "a real observer artifact validates and its report is JSON-safe and content-addressed",
         %{tmp_dir: dir} do
      path = observer_artifact(dir)
      bytes = File.read!(path)

      assert {:ok, report} = Validator.validate_file(path)
      assert report["valid"] == true
      assert report["serialization"] == "json"
      assert report["artifact_sha256"] == sha(bytes)
      assert report["artifact_bytes"] == byte_size(bytes)
      assert report["validator"]["name"] == "AshA2A.Chicago.Ocel.Validator"
      assert report["validator"]["version"] == "1.0.0"
      assert {:ok, _, _} = DateTime.from_iso8601(report["validated_at"])
      assert report["counts"]["events"] >= 3
      assert report["counts"]["event_object_relationships"] > 0
      assert report["errors"] == []
      assert JSON.decode!(JSON.encode!(report)) == report
    end

    test "each guard refuses exactly its defect with a coded, located error", %{tmp_dir: dir} do
      doc = base_doc()

      cases = [
        {"dangling_object_reference", "/events/0/relationships/0/objectId",
         put_in(
           doc,
           ["events", Access.at(0), "relationships", Access.at(0), "objectId"],
           "o-missing"
         )},
        {"dangling_object_reference", "/objects/0/relationships/0/objectId",
         put_in(
           doc,
           ["objects", Access.at(0), "relationships", Access.at(0), "objectId"],
           "o-missing"
         )},
        {"undeclared_attribute", "/events/0/attributes/1/name",
         update_in(
           doc,
           ["events", Access.at(0), "attributes"],
           &(&1 ++ [%{"name" => "x", "value" => "y"}])
         )},
        {"attribute_value_type_mismatch", "/events/0/attributes/0/value",
         put_in(doc, ["events", Access.at(0), "attributes", Access.at(0), "value"], "12x")},
        {"invalid_time", "/events/0/time",
         put_in(doc, ["events", Access.at(0), "time"], "2026-13-45T99:99:99Z")},
        {"invalid_time", "/objects/0/attributes/0/time",
         put_in(doc, ["objects", Access.at(0), "attributes", Access.at(0), "time"], "yesterday")},
        {"duplicate_object_id", "/objects/2/id", update_in(doc, ["objects"], &(&1 ++ [hd(&1)]))},
        {"duplicate_event_id", "/events/1/id", put_in(doc, ["events", Access.at(1), "id"], "e1")},
        {"missing_top_level_key", "/objects", Map.delete(doc, "objects")},
        {"undeclared_event_type", "/events/0/type",
         put_in(doc, ["events", Access.at(0), "type"], "nope")},
        {"undeclared_object_type", "/objects/1/type",
         put_in(doc, ["objects", Access.at(1), "type"], "nope")},
        {"invalid_qualifier", "/events/0/relationships/0/qualifier",
         put_in(doc, ["events", Access.at(0), "relationships", Access.at(0), "qualifier"], 7)},
        {"invalid_attribute_type", "/eventTypes/0/attributes/0/type",
         put_in(doc, ["eventTypes", Access.at(0), "attributes", Access.at(0), "type"], "datetime")},
        {"duplicate_type_name", "/objectTypes/2/name",
         update_in(doc, ["objectTypes"], &(&1 ++ [%{"name" => "order", "attributes" => []}]))},
        {"duplicate_attribute_declaration", "/eventTypes/0/attributes/1/name",
         update_in(
           doc,
           ["eventTypes", Access.at(0), "attributes"],
           &(&1 ++ [%{"name" => "seq", "type" => "string"}])
         )},
        {"duplicate_event_attribute", "/events/0/attributes/1/name",
         update_in(
           doc,
           ["events", Access.at(0), "attributes"],
           &(&1 ++ [%{"name" => "seq", "value" => 2}])
         )},
        {"empty_identifier", "/events/0/id", put_in(doc, ["events", Access.at(0), "id"], "")},
        {"missing_required_field", "/events/0/time",
         update_in(doc, ["events", Access.at(0)], &Map.delete(&1, "time"))},
        {"invalid_type", "/events", Map.put(doc, "events", %{})}
      ]

      # Removing `objects` necessarily also leaves event relationships dangling;
      # every other case must be diagnosed by exactly one guard.
      cascades = %{"missing_top_level_key" => ["dangling_object_reference"]}

      for {{code, path, corrupted}, i} <- Enum.with_index(cases) do
        file = write!(dir, "case-#{i}.json", JSON.encode!(corrupted))
        assert {:error, report} = Validator.validate_file(file), "case #{i} (#{code}) validated"
        assert report["valid"] == false

        assert Enum.any?(report["errors"], &(&1["code"] == code and &1["path"] == path)),
               "case #{i}: expected #{code}@#{path}, got #{inspect(report["errors"])}"

        codes = report["errors"] |> Enum.map(& &1["code"]) |> Enum.uniq()
        assert codes -- [code | Map.get(cascades, code, [])] == [], "case #{i}: #{inspect(codes)}"
      end
    end

    test "the fixture baseline is valid (so every case above isolates one guard)", %{tmp_dir: dir} do
      assert {:ok, %{"error_count" => 0}} =
               Validator.validate_file(write!(dir, "base.json", JSON.encode!(base_doc())))
    end

    test "non-JSON, non-object and unreadable artifacts are refused", %{tmp_dir: dir} do
      assert {:error, %{"errors" => [%{"code" => "non_json"}]} = r} =
               Validator.validate_file(write!(dir, "trunc.json", ~s({"objectTypes": [)))

      assert is_binary(r["artifact_sha256"])

      assert {:error, %{"errors" => [%{"code" => "non_json"}]}} =
               Validator.validate_file(write!(dir, "bin.json", <<0xFF, 0xFE, 0x00>>))

      assert {:error, %{"errors" => [%{"code" => "not_an_object"}]}} =
               Validator.validate_file(write!(dir, "array.json", "[]"))

      assert {:error,
              %{"errors" => [%{"code" => "unreadable_artifact"}], "artifact_sha256" => nil}} =
               Validator.validate_file(Path.join(dir, "absent.json"))
    end

    test "typed and all-string value serializations both validate; offset-less time warns",
         %{tmp_dir: dir} do
      doc =
        base_doc()
        |> put_in(["events", Access.at(0), "attributes", Access.at(0), "value"], "1")
        |> put_in(["objects", Access.at(0), "attributes", Access.at(0), "value"], "9.5")
        |> put_in(["events", Access.at(1), "time"], "2026-09-16T10:00:00")

      assert {:ok, report} =
               Validator.validate_file(write!(dir, "strings.json", JSON.encode!(doc)))

      assert [%{"code" => "time_without_offset", "count" => 1}] = report["warnings"]

      wrong_bool =
        put_in(base_doc(), ["objects", Access.at(1), "attributes", Access.at(0), "value"], "yes")

      assert {:error, %{"errors" => [%{"code" => "attribute_value_type_mismatch"}]}} =
               Validator.validate_file(write!(dir, "bool.json", JSON.encode!(wrong_bool)))

      float_as_int =
        put_in(base_doc(), ["events", Access.at(0), "attributes", Access.at(0), "value"], 1.5)

      assert {:error, %{"errors" => [%{"code" => "attribute_value_type_mismatch"}]}} =
               Validator.validate_file(write!(dir, "float.json", JSON.encode!(float_as_int)))
    end
  end

  describe "supports?/2 evidence completeness (§106)" do
    test "supported, incomplete and invalid are distinct outcomes", %{tmp_dir: dir} do
      path = write!(dir, "base.json", JSON.encode!(base_doc()))

      assert {:ok, %{"supported" => true, "missing" => [], "outcome" => "supported"}} =
               Validator.supports?(path, ["place", {"ship", %{"carrier" => "dhl"}}])

      assert {:error, %{"outcome" => "incomplete", "missing" => missing}} =
               Validator.supports?(path, ["place", {"ship", %{"carrier" => "ups"}}, "refund"])

      assert Enum.map(missing, & &1["activity"]) == ["ship", "refund"]

      bad = write!(dir, "bad.json", "not json")

      assert {:error, %{"outcome" => "invalid", "supported" => false, "missing" => [_]}} =
               Validator.supports?(bad, ["place"])
    end

    test "emits validated and completeness telemetry from the deciding boundary", %{tmp_dir: dir} do
      path = write!(dir, "base.json", JSON.encode!(base_doc()))
      ref = make_ref()
      parent = self()
      handler = {__MODULE__, ref}

      :ok =
        :telemetry.attach_many(
          handler,
          Validator.telemetry_events(),
          fn event, measurements, meta, _ -> send(parent, {ref, event, measurements, meta}) end,
          nil
        )

      try do
        {:error, _} = Validator.supports?(path, ["refund"])

        assert_received {^ref, [:ash_a2a, :chicago, :ocel, :validated], %{error_count: 0},
                         %{outcome: :valid, artifact_sha256: sha}}

        assert_received {^ref, [:ash_a2a, :chicago, :ocel, :completeness], %{missing_count: 1},
                         %{outcome: :incomplete, missing: "refund", artifact_sha256: ^sha}}
      after
        :telemetry.detach(handler)
      end
    end
  end

  describe "independence and the observer defect" do
    test "SA2A-OCEL is discovered for :core and every falsifier declares both predicates" do
      assert OcelValidity in AshA2A.Chicago.courts_for(:core)
      falsifiers = OcelValidity.falsifiers()
      assert length(falsifiers) == length(@negatives) + length(@positives)

      for f <- falsifiers do
        assert f.court_id == "SA2A-OCEL"
        assert String.starts_with?(f.id, "SA2A-OCEL-")
        assert f.attempt_predicate != nil, f.id
        assert f.outcome_predicate != nil, f.id
      end

      assert Enum.map(Enum.filter(falsifiers, &(&1.kind == :positive_control)), & &1.id) ==
               Enum.map(@positives, &("SA2A-OCEL-" <> &1))
    end

    test "the validator references no producer or consumer module (§15-§16)" do
      {:ok, {_, [atoms: atoms]}} =
        :beam_lib.chunks(elem(AshA2A.BeamFile.path(Validator), 1), [:atoms])

      referenced = MapSet.new(atoms, fn {_, atom} -> atom end)

      for forbidden <- [Log, Observer, Mapping, AshA2A.Chicago.Query, AshA2A.Chicago.Json] do
        refute MapSet.member?(referenced, forbidden), "validator references #{inspect(forbidden)}"
      end
    end

    test "two admitted mappings for one telemetry event still yield unique event ids", %{
      tmp_dir: dir
    } do
      event = [:ash_a2a, :chicago, :ocel_validator_test, :probe]
      a = Mapping.new!(event: event, activity: "probe.a", source: __MODULE__)
      b = Mapping.new!(event: event, activity: "probe.b", source: __MODULE__)
      {:ok, observer} = Observer.start_link(run_id: "overlap", mappings: [a, b])

      :telemetry.execute(event, %{}, %{})
      :telemetry.execute(event, %{}, %{})
      {:ok, flush} = Observer.flush(observer, dir)
      Observer.stop(observer)

      doc = JSON.decode!(File.read!(flush.path))
      ids = Enum.map(doc["events"], & &1["id"])
      assert length(ids) == 4
      assert ids == Enum.uniq(ids)
      assert {:ok, _} = Validator.validate_file(flush.path)
    end
  end

  # --- helpers -------------------------------------------------------------------

  # A real observer artifact of real telemetry (a mapped probe event inside a
  # real stimulus), flushed to disk.
  defp observer_artifact(dir) do
    event = [:ash_a2a, :chicago, :ocel_validator_test, :sut]

    mapping =
      Mapping.new!(
        event: event,
        activity: "sut.step",
        source: __MODULE__,
        objects: fn _m, meta ->
          [{"order", meta[:order], "order"}, {"item", meta[:item], "item"}]
        end,
        attributes: fn m, meta -> %{"n" => m[:n], "ok" => meta[:ok], "ratio" => m[:ratio]} end
      )

    {:ok, observer} = Observer.start_link(run_id: "validator-unit", mappings: [mapping])
    [f | _] = OcelValidity.falsifiers()

    ctx = %Context{
      run_id: "validator-unit",
      profile: :core,
      subject: nil,
      evidence_dir: dir,
      observer: observer
    }

    Context.stimulus(ctx, f, fn ->
      :telemetry.execute(event, %{n: 1, ratio: 0.5}, %{order: "o1", item: "i1", ok: true})
      :telemetry.execute(event, %{n: 2, ratio: 1.5}, %{order: "o1", item: "i2", ok: false})
    end)

    {:ok, flush} = Observer.flush(observer, Path.join(dir, "observer"))
    Observer.stop(observer)
    flush.path
  end

  # Minimal hand-checked OCEL 2.0 document exercising every construct the
  # validator judges. Used only to isolate one guard per case -- never as a
  # process-conformance oracle (§14).
  defp base_doc do
    %{
      "objectTypes" => [
        %{"name" => "order", "attributes" => [%{"name" => "price", "type" => "float"}]},
        %{"name" => "item", "attributes" => [%{"name" => "fragile", "type" => "boolean"}]}
      ],
      "eventTypes" => [
        %{"name" => "place", "attributes" => [%{"name" => "seq", "type" => "integer"}]},
        %{
          "name" => "ship",
          "attributes" => [
            %{"name" => "carrier", "type" => "string"},
            %{"name" => "eta", "type" => "time"}
          ]
        }
      ],
      "objects" => [
        %{
          "id" => "o1",
          "type" => "order",
          "attributes" => [%{"name" => "price", "time" => "1970-01-01T00:00:00Z", "value" => 9.5}],
          "relationships" => [%{"objectId" => "i1", "qualifier" => "contains"}]
        },
        %{
          "id" => "i1",
          "type" => "item",
          "attributes" => [
            %{"name" => "fragile", "time" => "2026-09-16T09:00:00+02:00", "value" => true}
          ]
        }
      ],
      "events" => [
        %{
          "id" => "e1",
          "type" => "place",
          "time" => "2026-09-16T09:00:00.123456Z",
          "attributes" => [%{"name" => "seq", "value" => 1}],
          "relationships" => [
            %{"objectId" => "o1", "qualifier" => "order"},
            %{"objectId" => "i1", "qualifier" => "item"}
          ]
        },
        %{
          "id" => "e2",
          "type" => "ship",
          "time" => "2026-09-16T10:00:00Z",
          "attributes" => [
            %{"name" => "carrier", "value" => "dhl"},
            %{"name" => "eta", "value" => "2026-09-17T10:00:00Z"}
          ],
          "relationships" => [%{"objectId" => "o1", "qualifier" => "order"}]
        }
      ]
    }
  end

  defp write!(dir, name, bytes) do
    path = Path.join(dir, name)
    File.write!(path, bytes)
    path
  end

  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end

# --- SECTION 6: Original test/ash_a2a/chicago/offline_replay_test.exs ---
defmodule AshA2A.Chicago.OfflineReplayTest do
  @moduledoc """
  Gate 10 offline replay + benchmark B8 qualification (RFC-SA2A-002 §41,
  §92), Chicago style: real consequence-bearing commands through the real
  CommandBus into real durable stores (on-disk EKV + receipt outbox journal),
  real sealed evidence chains on disk, a real fresh `elixir` OS process as the
  replay consumer, real file mutations as fault injection, real ledger rows
  read back through `Ash.read!`, and the independent OCEL consumer
  corroborating every verdict.

  `async: false` -- the observer attributes telemetry emitted between a
  stimulus start and stop to that falsifier, and the environment swaps the
  global receipt outbox directory.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  import ExUnit.CaptureIO

  alias AshA2A.Chicago.{Result, Runner}
  alias AshA2A.Chicago.Courts.OfflineReplay, as: Court
  alias AshA2A.Chicago.Fixtures.ChaosReconciliation.Environment
  alias AshA2A.Chicago.Fixtures.Replay, as: Fx
  alias AshA2A.Receipt.{EvidenceChain, OfflineReplay}

  @moduletag :tmp_dir
  @moduletag timeout: 1_200_000

  @ids for n <- 1..9, do: "CHI-REPLAY-00#{n}"

  describe "CHI-REPLAY court, end to end" do
    test "every falsifier reaches its verdict and every pass is OCEL-corroborated", %{
      tmp_dir: dir
    } do
      assert {:ok, run} = Runner.run(courts: [Court], profile: :do, evidence_dir: dir)
      by_id = Map.new(run.results, &{&1.falsifier_id, &1})

      assert Enum.sort(Map.keys(by_id)) == @ids

      assert by_id["CHI-REPLAY-001"].verdict == :positive_control_passed,
             inspect(by_id["CHI-REPLAY-001"], pretty: true, limit: :infinity)

      for id <-
            ~w(CHI-REPLAY-002 CHI-REPLAY-003 CHI-REPLAY-004 CHI-REPLAY-005 CHI-REPLAY-006 CHI-REPLAY-007 CHI-REPLAY-008) do
        assert by_id[id].verdict == :falsifier_killed,
               "#{id}: " <> inspect(by_id[id], pretty: true, limit: :infinity)

        assert Enum.all?(by_id[id].evidence["classes"] || ["detected"], &(&1 == "detected"))
      end

      assert by_id["CHI-REPLAY-009"].verdict == :measured,
             inspect(by_id["CHI-REPLAY-009"], pretty: true, limit: :infinity)

      for result <- run.results do
        assert result.ocel_corroborated? == true, "#{result.falsifier_id}: #{result.ocel_detail}"
        assert Result.counts_as_pass?(result)
      end

      positive = by_id["CHI-REPLAY-001"].evidence
      assert positive["ledger_rows_delta"] == 0
      assert positive["actuation_events_during_replay"] == []
      assert positive["deduplicated_retry_reconstructed"] == true
      assert positive["stages_reconstructed"] == positive["stages_expected"]
      assert positive["stages_expected"] == 3 * 8
      assert positive["fresh"]["process"]["do_boundary_loaded"] == false
      assert positive["fresh"]["process"]["ash_a2a_started"] == false

      # Each mutation was refused by the guard it targets, not by accident.
      expected_checks = %{
        "CHI-REPLAY-002" => %{
          "final_file_deleted" => "links_present",
          "prepared_link_removed_reforged" => "reconstruction_complete"
        },
        "CHI-REPLAY-003" => %{
          "prepared_final_swapped" => "link_chaining",
          "prepared_final_swapped_reforged" => "reconstruction_order",
          "dedup_retry_moved_first_reforged" => "reconstruction_order"
        },
        "CHI-REPLAY-004" => %{
          "final_input_digest_rewritten" => "link_digests",
          "final_input_digest_rewritten_reforged" => "reconstruction_identity"
        },
        "CHI-REPLAY-005" => %{
          "final_grant_rewritten_reforged" => "reconstruction_authority",
          "both_grants_rewritten_reforged" => "reconstruction_authority"
        },
        "CHI-REPLAY-006" => %{
          "real_double_actuation" => "reconstruction_actuation_unique",
          "spliced_segment_reforged" => "reconstruction_actuation_unique"
        },
        "CHI-REPLAY-007" => %{
          "link_root_left" => "link_root",
          "basis_root_left" => "basis_root",
          "both_roots_reforged_anchored" => "anchor_basis_root"
        }
      }

      for {id, mutations} <- expected_checks, {name, check} <- mutations do
        verdict = by_id[id].evidence[name]
        assert verdict["outcome"] == "refused", "#{id}/#{name}: #{inspect(verdict)}"
        assert verdict["fresh_process_accepted"] == true
        assert check in Enum.map(verdict["failed_checks"], & &1["check"]), "#{id}/#{name}"
      end

      assert by_id["CHI-REPLAY-006"].evidence["real_double_actuation_ledger_rows"] == 2

      actuator = by_id["CHI-REPLAY-008"].evidence
      assert actuator["replay"]["outcome"] == "verified"
      assert actuator["actuation_events"] == []
      assert actuator["ledger_rows_delta"] == 0
      assert actuator["redrive_reply"] =~ "authority_required"

      b8 = by_id["CHI-REPLAY-009"].measurements
      assert b8["benchmark"] == "SA2A-B8"
      assert b8["zero_external_consequence"] == true
      assert Enum.map(b8["sizes"], & &1["executed_effects"]) == [2, 8, 32]

      for size <- b8["sizes"] do
        assert size["receipt_chain_length"] == 3 * size["executed_effects"] + 2
        assert size["serialized_evidence_bytes"] > 0
        assert size["replay_verification_us"]["fresh_os_process"] > 0
        assert size["replay_verification_us"]["in_vm"] > 0
        assert size["peak_memory_bytes"]["fresh_vm_total"] > 0
        assert size["peak_memory_bytes"]["in_vm_verifier_process"] > 0
        assert size["fresh_consumer_startup_us"] > 0
        assert size["external_consequence_rows_delta"] == 0
        assert size["actuator_events_during_replay"] == 0
        assert size["fresh_do_boundary_loaded"] == false
      end

      assert Enum.find(run.receipt["gates"], &(&1["gate"] == 10))["status"] == "PASSED"
      assert run.receipt["evidence"]["replay"] == "PASS"
      assert run.receipt["results"]["survived_ids"] == []
    end
  end

  describe "OfflineReplay over a real sealed chain" do
    setup %{tmp_dir: dir} do
      env = Environment.open(Path.join(dir, "env"))
      on_exit(fn -> Environment.close(env) end)
      {:ok, pkg} = Fx.produce(env, Path.join(dir, "chain"))
      %{env: env, pkg: pkg}
    end

    test "an intact chain verifies from disk and reconstructs every stage", %{pkg: pkg} do
      refute Process.alive?(pkg.pid)
      assert pkg.seal["length"] == 8
      assert pkg.seal["reconstruction_failures"] == []

      verdict =
        OfflineReplay.verify_chain(pkg.dir,
          link_root: pkg.seal["link_root"],
          basis_root: pkg.seal["basis_root"]
        )

      assert verdict["outcome"] == "verified", inspect(verdict["checks"], pretty: true)
      assert verdict["chain"]["reconstructed_basis_root"] == pkg.seal["basis_root"]
      assert verdict["chain"]["reconstructed_link_root"] == pkg.seal["link_root"]

      assert [c1, c2, retry] = verdict["reconstruction"]["records"]

      for record <- [c1, c2, retry], stage <- OfflineReplay.stages() do
        assert record[stage] != nil, "#{record["command_id"]} lacks #{stage}"
      end

      assert c1["prepared_receipt"]["status"] == "pending"
      assert c1["final_receipt"]["terminal_status"] == "executed"
      assert c1["final_receipt"]["actuated_by_replay"] == false
      assert c1["authority_decision"]["decision"] == "admitted"
      assert c1["observed_post_state"]["rows"] == 1
      assert c2["intended_effect"]["actuation_id"] != c1["intended_effect"]["actuation_id"]

      assert retry["prepared_receipt"]["reason"] == "deduplicated"
      assert retry["intended_effect"]["actuation_id"] == c1["intended_effect"]["actuation_id"]
      assert retry["observed_post_state"]["rows"] == 1
    end

    test "a verdict is refused with the targeted reason, and no reconstruction on bad bytes", %{
      pkg: pkg,
      tmp_dir: dir
    } do
      deleted = Fx.copy_chain(pkg, dir, "deleted")
      Fx.delete_file!(deleted, Fx.link(Fx.manifest(deleted), 1, "prepared"))
      verdict = OfflineReplay.verify_chain(deleted)
      assert verdict["outcome"] == "refused"
      assert verdict["reasons"] == ["replay_receipt_missing"]
      assert verdict["reconstruction"] == nil

      wrong_anchor = OfflineReplay.verify_chain(pkg.dir, basis_root: String.duplicate("a", 64))
      assert wrong_anchor["reasons"] == ["replay_root_divergence"]

      no_manifest = Fx.copy_chain(pkg, dir, "no-manifest")
      File.rm!(Path.join(no_manifest, EvidenceChain.manifest_file()))
      assert OfflineReplay.verify_chain(no_manifest)["reasons"] == ["replay_manifest_invalid"]
    end

    test "replay/2 runs in the SUT VM, emits its decision, and never actuates", %{pkg: pkg} do
      test_pid = self()
      handler = {__MODULE__, test_pid}

      :ok =
        :telemetry.attach_many(
          handler,
          [
            OfflineReplay.event(),
            [:ash_a2a, :command_bus, :actuate, :start],
            [:ash_a2a, :dispatch, :start]
          ],
          &__MODULE__.forward/4,
          test_pid
        )

      try do
        before = Fx.rows(pkg.operations)
        assert {:ok, verdict} = OfflineReplay.replay(pkg.dir, producer: pkg.pid)
        assert verdict["outcome"] == "verified"
        assert verdict["mode"] == "in_vm"
        assert verdict["measurements"]["peak_verifier_bytes"] > 0
        assert Fx.rows(pkg.operations) == before

        assert_received {:telemetry, [:ash_a2a, :replay, :verified],
                         %{outcome: :verified, mode: :in_vm, producer_terminated: true}}

        refute_received {:telemetry, [:ash_a2a, :command_bus, :actuate, :start], _}
        refute_received {:telemetry, [:ash_a2a, :dispatch, :start], _}
      after
        :telemetry.detach(handler)
      end
    end

    test "verify_fresh/2 accepts only a verdict from a fresh OS process", %{
      pkg: pkg,
      tmp_dir: dir
    } do
      assert {:ok, verdict} = OfflineReplay.verify_fresh(pkg.dir, producer: pkg.pid)
      assert verdict["outcome"] == "verified", inspect(verdict, pretty: true)
      assert verdict["fresh_process_accepted"] == true
      assert verdict["process"]["os_pid"] != System.pid()
      assert verdict["process"]["ash_a2a_started"] == false
      assert verdict["process"]["do_boundary_loaded"] == false
      assert verdict["measurements"]["startup_us"] > 0

      liar = Path.join(dir, "lying_replay.sh")

      lie =
        JSON.encode!(%{
          "schema" => OfflineReplay.schema(),
          "outcome" => "verified",
          "reasons" => [],
          "process" => %{
            "os_pid" => System.pid(),
            "ash_a2a_started" => true,
            "do_boundary_loaded" => true
          }
        })

      File.write!(liar, "#!/bin/sh\nprintf '%s\\n' 'SA2A-OFFLINE-REPLAY-VERDICT #{lie}'\n")
      File.chmod!(liar, 0o755)

      assert {:ok, refused} = OfflineReplay.verify_fresh(pkg.dir, elixir: liar)
      assert refused["outcome"] == "refused"
      assert "replay_process_not_fresh:producer_os_pid" in refused["reasons"]
      assert "replay_process_not_fresh:os_pid_unbound" in refused["reasons"]
      assert "replay_process_not_fresh:ash_a2a_started" in refused["reasons"]
      assert "replay_consequence_boundary_loaded" in refused["reasons"]

      assert {:ok, silent} =
               OfflineReplay.verify_fresh(pkg.dir, elixir: System.find_executable("false"))

      assert silent["reasons"] == ["replay_crashed:no_verdict"]
    end

    test "main/1 prints exactly one parseable verdict line", %{pkg: pkg} do
      output = capture_io(fn -> OfflineReplay.main([pkg.dir, "-", "-"]) end)
      assert [line] = String.split(output, "\n", trim: true)
      assert "SA2A-OFFLINE-REPLAY-VERDICT " <> json = line
      assert %{"outcome" => "verified", "schema" => schema} = JSON.decode!(json)
      assert schema == OfflineReplay.schema()

      assert capture_io(fn -> OfflineReplay.main([]) end) =~ ~s("outcome":"refused")
    end
  end

  # Defect D1 guard (found by CHI-REPLAY-001): replay basis digests must not
  # depend on the verifying VM's atom table. Two fresh VMs create the same
  # atoms in opposite orders; plain term_to_binary/1 disagrees between them,
  # AshA2A.Actuation.digest/1 must not.
  test "Actuation.digest/1 is independent of the VM atom table" do
    paths = Path.wildcard(Path.join(Mix.Project.build_path(), "lib/*/ebin"))

    run = fn order ->
      script = """
      keys = Enum.map(#{inspect(order)}, &String.to_atom/1)
      term = %{basis: Map.new(keys, &{&1, Atom.to_string(&1)})}
      plain = :crypto.hash(:sha256, :erlang.term_to_binary(term)) |> Base.encode16(case: :lower)
      IO.puts(plain <> " " <> AshA2A.Actuation.digest(term))
      """

      {out, 0} = System.cmd("elixir", Enum.flat_map(paths, &["-pa", &1]) ++ ["-e", script])
      out |> String.trim() |> String.split(" ")
    end

    [plain_a, digest_a] = run.(["replay_guard_zeta", "replay_guard_alpha"])
    [plain_b, digest_b] = run.(["replay_guard_alpha", "replay_guard_zeta"])

    assert plain_a != plain_b
    assert digest_a == digest_b
  end

  test "every replay refusal code is classified" do
    for {code, class} <- OfflineReplay.__sa2a_refusal_codes__() do
      assert AshA2A.Semantic.Refusal.classify(code) == class
    end
  end

  @doc false
  def forward(event, _measurements, metadata, test_pid),
    do: send(test_pid, {:telemetry, event, metadata})
end

# --- SECTION 7: Original test/ash_a2a/chicago/plan_gates_test.exs ---
defmodule AshA2A.Chicago.PlanGatesTest do
  @moduledoc """
  RFC-SA2A-002 Gate 4 Planning Candidate-Only (§35), Gate 5 Whole Bounded
  Plan Preflighted (§36), Plan Package Court (§58) and Planner Non-Authority
  Court (§59): the `CHI-PLAN-AUTH`, `CHI-PREFLIGHT` and `SA2A-PLAN` courts run
  end to end, plus narrow Chicago tests of the preflight boundary and the
  Strict §58 identity gate they forced.

  Real collaborators throughout: the real `AshA2A.Semantic.Admission`,
  `PlanProjection`, `PlanPackage`, `Select`, `Construct`,
  `AshA2A.Planning.Preflight`, the real `native/hddl_cli` solver,
  `AshA2A.CommandBus`, `AshA2A.Dispatcher`, `AshA2A.Agent`, real
  `AshA2A.ReceiptStore.Memory` and `AshA2A.Authority.Broker.InMemory`
  processes, ETS resources read back through `Ash.read!/1`, and the durable
  OCEL artifact read by the independent consumer. No Mock/Mox/:meck/patch.

  `async: false` -- the observer attributes every telemetry event emitted
  between a stimulus start and stop to that falsifier, and the A2A falsifiers
  point `:authority_broker` at an isolated broker for their stimulus.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_solo
  alias AshA2A.Chicago
  alias AshA2A.Chicago.{Query, Runner}
  alias AshA2A.Chicago.Courts.{PlanAuthority, PlanPackage, WholePlanPreflight}
  alias AshA2A.Chicago.Fixtures.Brce.Planned
  alias AshA2A.Chicago.Fixtures.PlanGates, as: Fx
  alias AshA2A.CommandBus
  alias AshA2A.Planning.{BoundedPlan, Preflight}
  alias AshA2A.Semantic.PlanPackage, as: Package
  alias AshA2A.Semantic.Refusal

  @moduletag :tmp_dir

  @courts [PlanAuthority, WholePlanPreflight, PlanPackage]

  @expected Map.merge(
              Map.new(1..5, &{"CHI-PLAN-AUTH-00#{&1}", :falsifier_killed}),
              %{
                "CHI-PLAN-AUTH-006" => :positive_control_passed,
                "CHI-PLAN-AUTH-007" => :positive_control_passed
              }
            )
            |> Map.merge(
              Map.new(1..12, fn n ->
                {"CHI-PREFLIGHT-" <> String.pad_leading("#{n}", 3, "0"), :falsifier_killed}
              end)
            )
            |> Map.put("CHI-PREFLIGHT-013", :positive_control_passed)
            |> Map.merge(
              Map.new(Enum.to_list(1..14) ++ [16], fn n ->
                {"SA2A-PLAN-" <> String.pad_leading("#{n}", 3, "0"), :falsifier_killed}
              end)
            )
            |> Map.merge(%{
              "SA2A-PLAN-015" => :positive_control_passed,
              "SA2A-PLAN-017" => :positive_control_passed
            })

  describe "CHI-PLAN-AUTH + CHI-PREFLIGHT + SA2A-PLAN end to end over the real SUT" do
    @tag timeout: 600_000
    test "every falsifier reaches its verdict and every pass is corroborated by the independent OCEL consumer",
         %{tmp_dir: dir} do
      assert {:ok, run} = Runner.run(courts: @courts, profile: :plan, evidence_dir: dir)

      by_id = Map.new(run.results, &{&1.falsifier_id, &1})
      assert Enum.sort(Map.keys(by_id)) == Enum.sort(Map.keys(@expected))

      failures =
        for {id, verdict} <- Enum.sort(@expected),
            result = by_id[id],
            result.verdict != verdict or result.attempt_observed? != true or
              result.ocel_corroborated? != true do
          {id, result.verdict, result.detail, result.ocel_corroborated?, result.ocel_detail,
           result.evidence}
        end

      assert failures == [], inspect(failures, pretty: true, limit: :infinity)
      assert run.ocel.dropped == 0

      receipt = JSON.decode!(File.read!(Path.join(dir, "standing_receipt.json")))

      for gate <- [4, 5] do
        assert Enum.find(receipt["gates"], &(&1["gate"] == gate))["status"] == "PASSED"
      end

      refute receipt["standing"] == "NONCONFORMANT"

      # The independent consumer answers the Gate 4 question from the durable
      # artifact alone: the plan was SELECTED and CONSTRUCTED, the valid plan
      # was even preflight-verified at the boundary, and still nothing actuated.
      assert {:ok, index} = Query.load(Path.join(dir, "ocel.json"), run.ocel.sha256)

      for predicate <- [
            {:observed, "plan.select", %{"outcome" => "selected"}},
            {:observed, "plan.construct", %{"outcome" => "constructed"}},
            {:observed, "brce.preflight", %{"outcome" => "verified"}},
            {:observed, "brce.admission",
             %{"outcome" => "refused", "code" => "authority_required"}}
          ] do
        assert {true, _} = Query.eval(index, "CHI-PLAN-AUTH-001", predicate)
      end

      assert {false, _} = Query.eval(index, "CHI-PLAN-AUTH-001", Fx.actuation_predicate())

      # Gate 5: the mutated retry count is named by the refusal, before any claim.
      assert {true, _} =
               Query.eval(
                 index,
                 "CHI-PREFLIGHT-004",
                 {:observed, "brce.preflight",
                  %{
                    "outcome" => "refused",
                    "code" => "preflight_identity_mismatch",
                    "fields" => "retry_count"
                  }}
               )

      assert {false, _} = Query.eval(index, "CHI-PREFLIGHT-004", {:observed, "brce.claim"})
    end
  end

  describe "court declarations (§11, discovery)" do
    test "the three courts are discoverable SA2A-PLAN courts with fully declared falsifiers" do
      for court <- @courts do
        assert court in Chicago.courts_for(:plan)
        refute court in Chicago.courts_for(:logic)
      end

      assert PlanAuthority.gate() == 4
      assert WholePlanPreflight.gate() == 5
      assert PlanPackage.gate() == nil

      falsifiers = Enum.flat_map(@courts, & &1.falsifiers())
      assert Enum.sort(Enum.map(falsifiers, & &1.id)) == Enum.sort(Map.keys(@expected))

      for f <- falsifiers do
        assert f.attempt_predicate != nil, f.id
        assert f.outcome_predicate != nil, f.id
        assert :ok = Query.validate_predicate(f.attempt_predicate)
        assert :ok = Query.validate_predicate(f.outcome_predicate)
      end

      assert Enum.frequencies_by(falsifiers, & &1.kind) == %{negative: 32, positive_control: 5}
    end

    test "every BoundedPlan field is bound by the preflight identity" do
      assert Enum.sort(Preflight.bound_fields()) == WholePlanPreflight.plan_fields()
    end

    test "the new refusal codes are classified without editing the Refusal table" do
      assert Refusal.classify(:preflight_identity_mismatch) == :refused_identity
      assert Refusal.classify(:preflight_required) == :refused_bounds
      assert Refusal.classify(:plan_package_identity_missing) == :refused_plan
    end
  end

  describe "AshA2A.Planning.Preflight over a real planned candidate" do
    test "a preflighted plan's identity is stable and every bound field mutation changes it" do
      planned = Fx.planned()
      assert {:ok, again} = Preflight.preflight(planned.plan)
      assert again.preflight_digest == planned.preflight.preflight_digest

      for field <- WholePlanPreflight.plan_fields() do
        mutated = WholePlanPreflight.mutate(planned, field)

        assert {:error, %{code: :preflight_identity_mismatch, detail: %{fields: [^field]}}} =
                 Preflight.admit_step(planned.preflight, mutated, step_command(planned)),
               "#{field} is not bound"
      end
    end

    test "an unbounded whole plan is refused before any identity is issued" do
      planned = Fx.planned()

      assert {:error, %{code: :preflight_bound_exceeded, detail: %{fields: [:fan_out]}}} =
               Preflight.preflight(%{planned.plan | fan_out: 9})

      assert {:error, %{code: :preflight_bound_missing, detail: %{missing: [:retry_count]}}} =
               Preflight.preflight(%{planned.plan | retry_count: nil})

      assert {:error, %{code: :preflight_authority_ceiling_violated}} =
               Preflight.preflight(%{planned.plan | authority: :do})
    end

    test "CommandBus refuses a mutated plan step before claim and executes the preflighted one",
         %{tmp_dir: _dir} do
      planned = Fx.planned()
      [step | _] = planned.plan.steps
      name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
      start_supervised!({AshA2A.ReceiptStore.Memory, name: name})
      opts = [store_opts: [name: name], preflight: planned.preflight]

      assert {:error, %{code: :preflight_identity_mismatch}} =
               CommandBus.run(
                 Fx.step_command(step, authority: :granted),
                 Fx.step_message(step),
                 Planned,
                 opts ++ [plan: %BoundedPlan{planned.plan | retry_count: 1}]
               )

      assert Fx.consequence_rows(planned.token) == 0

      assert {:ok, receipt} =
               CommandBus.run(
                 Fx.step_command(step, authority: :granted),
                 Fx.step_message(step),
                 Planned,
                 opts ++ [plan: planned.plan]
               )

      assert receipt.plan_digest == planned.package.plan_digest
      assert Fx.consequence_rows(planned.token) == 1
    end
  end

  describe "§58 Strict identity gate" do
    test "a complete strict package builds; each withheld identity is refused" do
      {projection, _} = Fx.projection()
      token = Fx.token()
      assert {:ok, _} = Fx.package(projection, token)

      for overrides <- [
            [planning_domain_identity: nil],
            [action_identities: [], method_identities: []],
            [preconditions: [], effects: []]
          ] do
        assert {:error, %{code: :plan_package_identity_missing}} =
                 Fx.package(projection, token, overrides),
               inspect(overrides)
      end

      undeclared = token |> Fx.package_opts() |> Keyword.delete(:nondeterministic_outcomes)

      assert {:error, %{code: :plan_package_identity_missing, detail: %{missing: missing}}} =
               Package.from_projection(projection, Fx.planner_identity(), undeclared)

      assert :nondeterministic_outcomes in missing

      assert {:error,
              %{code: :plan_package_identity_missing, detail: %{missing: [:planner_identity]}}} =
               Package.from_projection(projection, "", Fx.package_opts(token))

      # Permissive stays permissive.
      assert {:ok, _} =
               Package.from_projection(
                 projection,
                 "",
                 Keyword.put(undeclared, :profile, :permissive)
               )
    end
  end

  defp step_command(planned) do
    [step | _] = planned.plan.steps
    Fx.step_command(step, authority: :granted)
  end
end

# --- SECTION 8: Original test/ash_a2a/chicago/postcondition_test.exs ---
defmodule AshA2A.Chicago.PostconditionTest do
  @moduledoc """
  Gate 8 independent postcondition observation (RFC-SA2A-002 §8, §39, §73),
  Chicago style: the real `AshA2A.CommandBus`, the real ETS
  `AshA2A.Chicago.Fixtures.Postcondition.Ledger`, a real
  `AshA2A.ReceiptStore.Memory`, real telemetry, and the durable OCEL artifact
  read back by the independent consumer.

  `async: false` -- the Chicago observer attributes every telemetry event
  emitted inside a stimulus to that falsifier, and the telemetry assertions
  below attach global handlers.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  alias AshA2A.{Authority, Command, CommandBus, Identity, Postcondition, Receipt}
  alias AshA2A.Chicago
  alias AshA2A.Chicago.{Query, Runner}
  alias AshA2A.Chicago.Courts.Postcondition, as: Court
  alias AshA2A.Chicago.Fixtures.Postcondition, as: Fixtures

  alias AshA2A.Chicago.Fixtures.Postcondition.{
    AlwaysRefusingVerifier,
    Ledger,
    LedgerVerifier,
    ReportReadingVerifier
  }

  alias AshA2A.Semantic.Refusal

  @moduletag :tmp_dir

  defmodule RaisingVerifier do
    @moduledoc "Real verifier whose read path raises (a crashing reader is an observation, not a verdict)."
    @behaviour AshA2A.Postcondition
    @impl true
    def verify(_expect, _probe), do: raise("ledger reader unavailable")
  end

  defmodule NotAVerifier do
    @moduledoc "A module that does not implement `AshA2A.Postcondition`."
  end

  describe "CHI-POST court end to end (Runner, profile :do)" do
    test "every falsifier reaches its verdict and every pass is OCEL-corroborated", %{
      tmp_dir: dir
    } do
      assert {:ok, run} = Runner.run(courts: [Court], profile: :do, evidence_dir: dir)
      by_id = Map.new(run.results, &{&1.falsifier_id, &1})

      assert Enum.sort(Map.keys(by_id)) ==
               ~w(CHI-POST-001 CHI-POST-002 CHI-POST-003 CHI-POST-004 CHI-POST-005 CHI-POST-006)

      expected = %{
        "CHI-POST-001" => :falsifier_killed,
        "CHI-POST-002" => :falsifier_killed,
        "CHI-POST-003" => :falsifier_killed,
        "CHI-POST-004" => :falsifier_killed,
        "CHI-POST-005" => :positive_control_passed,
        "CHI-POST-006" => :falsifier_killed
      }

      for {id, verdict} <- expected do
        result = by_id[id]
        assert result.verdict == verdict, "#{id}: #{inspect(result, pretty: true)}"
        assert result.attempt_observed? == true, id
        assert result.gate == 8
        assert result.ocel_corroborated? == true, "#{id}: #{result.ocel_detail}"
        assert AshA2A.Chicago.Result.counts_as_pass?(result), id
      end

      assert run.ocel.dropped == 0

      receipt = JSON.decode!(File.read!(Path.join(dir, "standing_receipt.json")))
      assert receipt["results"]["falsifiers_killed"] == 5
      assert receipt["results"]["positive_controls_passed"] == 1
      assert Enum.find(receipt["gates"], &(&1["gate"] == 8))["status"] == "PASSED"
      assert receipt["evidence"]["independent_postcondition"] == "PASS"
    end

    test "the independent consumer reads the postcondition decisions from disk", %{tmp_dir: dir} do
      {:ok, run} = Runner.run(courts: [Court], profile: :do, evidence_dir: dir)
      assert {:ok, index} = Query.load(Path.join(dir, "ocel.json"), run.ocel.sha256)

      # Lying and divergent actuators: contradicted, never completed.
      for id <- ["CHI-POST-001", "CHI-POST-002"] do
        assert {true, _} =
                 Query.eval(
                   index,
                   id,
                   {:observed, "brce.postcondition", %{"outcome" => "contradicted"}}
                 )

        assert {true, _} =
                 Query.eval(
                   index,
                   id,
                   {:observed, "receipt.committed", %{"status" => "postcondition_contradicted"}}
                 )

        assert {false, _} =
                 Query.eval(
                   index,
                   id,
                   {:observed, "receipt.committed", %{"status" => "completed"}}
                 )
      end

      # The report-reading verifier is detectably non-independent.
      assert {true, _} =
               Query.eval(
                 index,
                 "CHI-POST-003",
                 {:observed, "brce.postcondition",
                  %{
                    "outcome" => "unverified",
                    "reason" => "verifier_not_independent",
                    "independent" => "false"
                  }}
               )

      # Observation follows actuation for the same command.
      assert {true, _} =
               Query.eval(
                 index,
                 "CHI-POST-005",
                 {:precedes, "brce.actuate.stop", "brce.postcondition", "command"}
               )
    end

    test "the court is discoverable for SA2A-DO and owns gate 8" do
      assert Court in Chicago.courts_for(:do)
      refute Court in Chicago.courts_for(:plan)
      assert Court.gate() == 8
      assert Enum.all?(Court.falsifiers(), &(&1.attempt_predicate && &1.outcome_predicate))
    end
  end

  describe "AshA2A.Postcondition through the real CommandBus" do
    setup do
      name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
      {:ok, pid} = AshA2A.ReceiptStore.Memory.start_link(name: name)
      on_exit(fn -> AshA2A.TestSupport.SafeStop.stop(pid) end)

      handler = "postcondition-test-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler,
        [:ash_a2a, :command_bus, :postcondition],
        fn _event, _measurements, meta, _config -> send(test_pid, {:postcondition, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      %{store_opts: [name: name]}
    end

    test "honest actuator + independent verifier: verified, completed, independent", ctx do
      {key, result} = submit(:honest_write, LedgerVerifier, ctx.store_opts)

      assert {:ok, %Receipt{status: :completed} = receipt} = result
      assert %{status: :verified, independent: true, reason: nil} = receipt.metadata.postcondition
      assert Fixtures.stored_values(key) == ["X"]
      assert_received {:postcondition, %{outcome: :verified, independent: true}}
    end

    test "lying actuator: contradicted, receipted as such, returned as an error", ctx do
      {key, result} = submit(:lying_write, LedgerVerifier, ctx.store_opts)

      assert {:error, %{code: :postcondition_contradicted, receipt: returned}} = result
      assert returned.status == :postcondition_contradicted
      assert Fixtures.stored_values(key) == []

      # The committed receipt, read back independently, carries no completed standing.
      assert {:ok, stored} = AshA2A.ReceiptStore.Memory.fetch(returned.command_id, ctx.store_opts)
      assert stored.status == :postcondition_contradicted

      assert %{status: :contradicted, evidence: %{"observed" => []}} =
               stored.metadata.postcondition

      assert_received {:postcondition, %{outcome: :contradicted}}
    end

    test "replaying a contradicted command never resurrects completed standing", ctx do
      {key, command, message, opts} = build(:lying_write, LedgerVerifier, ctx.store_opts)

      assert {:error, %{code: :postcondition_contradicted}} =
               CommandBus.run(command, message, Ledger, opts)

      assert {:ok, %Receipt{replayed?: true, status: :postcondition_contradicted}} =
               CommandBus.run(command, message, Ledger, opts)

      assert Fixtures.stored_values(key) == []
    end

    test "divergent actuator: contradicted with the independently observed value", ctx do
      {key, result} = submit(:divergent_write, LedgerVerifier, ctx.store_opts)

      assert {:error, %{code: :postcondition_contradicted, postcondition: pc}} = result
      assert pc.evidence == %{"expected" => "X", "observed" => ["X:diverged"]}
      assert Fixtures.stored_values(key) == ["X:diverged"]
    end

    test "report-reading verifier is detected as non-independent", ctx do
      {_key, result} = submit(:lying_write, ReportReadingVerifier, ctx.store_opts)

      assert {:ok, %Receipt{} = receipt} = result

      assert %{
               status: :unverified,
               reason: :verifier_not_independent,
               independent: false,
               evidence: %{
                 "verdict_under_actuator_report" => "verified",
                 "verdict_under_counterfactual_report" => "contradicted"
               }
             } = receipt.metadata.postcondition

      assert_received {:postcondition, %{outcome: :unverified, independent: false}}
    end

    test "missing postcondition on a :change command is unverified, never verified", ctx do
      {_key, result} = submit(:lying_write, nil, ctx.store_opts)

      assert {:ok, %Receipt{} = receipt} = result

      assert %{status: :unverified, reason: :no_postcondition_declared, verifier: nil} =
               receipt.metadata.postcondition

      assert_received {:postcondition,
                       %{outcome: :unverified, reason: :no_postcondition_declared}}
    end

    test "always-refusing verifier contradicts even a real change (it cannot pass the positive control)",
         ctx do
      {key, result} = submit(:honest_write, AlwaysRefusingVerifier, ctx.store_opts)

      assert {:error, %{code: :postcondition_contradicted}} = result
      assert Fixtures.stored_values(key) == ["X"]
    end

    test "a raising verifier and a non-verifier module are unverified, never verified", ctx do
      {_key, raised} = submit(:honest_write, RaisingVerifier, ctx.store_opts)
      assert {:ok, %Receipt{metadata: %{postcondition: pc}}} = raised
      assert %{status: :unverified, reason: :verifier_raised} = pc
      assert pc.evidence["detail"] =~ "ledger reader unavailable"

      {_key, missing} = submit(:honest_write, NotAVerifier, ctx.store_opts)

      assert {:ok, %Receipt{metadata: %{postcondition: %{reason: :verifier_not_implemented}}}} =
               missing
    end

    test "an :observe command with no postcondition emits no postcondition observation", ctx do
      principal = Identity.principal("postcondition-test")
      capability = Fixtures.capability(:read)

      command =
        Command.new(capability,
          command_id: "postcondition-observe-#{System.unique_integer([:positive])}",
          agent_id: "postcondition-test",
          principal_id: principal,
          input: %{}
        )

      message = AshA2A.Protocol.Message.new_user([AshA2A.Protocol.Part.Data.new(%{})])

      assert {:ok, %Receipt{consequence: :observe} = receipt} =
               CommandBus.run(command, message, Ledger, store_opts: ctx.store_opts)

      refute Map.has_key?(receipt.metadata, :postcondition)
      refute_received {:postcondition, _}
    end
  end

  describe "AshA2A.Postcondition contract" do
    test "no success claim is unverified without consulting the verifier" do
      probe = %Postcondition.Probe{consequence: :change, actuator_report: {:error, :boom}}
      pc = %Postcondition{id: "p", verifier: AlwaysRefusingVerifier, expect: %{}}

      assert %{status: :unverified, reason: :no_success_claim, independent: nil} =
               Postcondition.evaluate(pc, probe, [])
    end

    test "absence is nil only for :observe" do
      assert Postcondition.evaluate(nil, %Postcondition.Probe{consequence: :observe}, []) == nil

      for consequence <- [:change, :external_do] do
        assert %{status: :unverified, reason: :no_postcondition_declared} =
                 Postcondition.evaluate(nil, %Postcondition.Probe{consequence: consequence}, [])
      end
    end

    test "postcondition_contradicted classifies without editing the Refusal table" do
      assert Refusal.classify(:postcondition_contradicted) == :refused_meta_rigor
    end
  end

  defp submit(action, verifier, store_opts) do
    {key, command, message, opts} = build(action, verifier, store_opts)
    {key, CommandBus.run(command, message, Ledger, opts)}
  end

  defp build(action, verifier, store_opts) do
    key = "unit-#{action}-#{System.unique_integer([:positive])}"
    capability = Fixtures.capability(action)
    principal = Identity.principal("postcondition-test")

    command =
      Command.new(capability,
        command_id: "postcondition-" <> key,
        agent_id: "postcondition-test",
        principal_id: principal,
        authority: Authority.new(principal, capability, token_id: "tok-" <> key),
        input: %{key: key, value: "X"}
      )

    message =
      AshA2A.Protocol.Message.new_user([
        AshA2A.Protocol.Part.Data.new(%{"key" => key, "value" => "X"})
      ])

    opts =
      [store_opts: store_opts] ++
        if verifier,
          do: [
            postcondition: %Postcondition{
              id: "ledger.value_persisted",
              verifier: verifier,
              expect: %{key: key, value: "X"}
            }
          ],
          else: []

    {key, command, message, opts}
  end
end

# --- SECTION 9: Original test/ash_a2a/chicago/real_collaborators_test.exs ---
defmodule AshA2A.Chicago.RealCollaboratorsTest do
  @moduledoc """
  Gate 3 (RFC-SA2A-002 §9, §10, §34) qualified Chicago style: the real
  `AshA2A.Chicago.Runner`, the real `AshA2A.Chicago.Courts.RealCollaborators`
  court, the real GraphLaw wasm executed by real `node` hosts, real receipt
  store processes really restarted, real EKV on disk, the real authority grant
  path, and a real OCEL artifact read back by the independent consumer.

  `async: false`: the court mutates application configuration for the length
  of one stimulus, and the observer attributes telemetry by stimulus window.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  alias AshA2A.Chicago.{Collaborators, Query, Runner}
  alias AshA2A.Chicago.Collaborators.{DurabilityProbe, MockScan}
  alias AshA2A.Chicago.Courts.RealCollaborators
  alias AshA2A.Chicago.Fixtures.RealCollaborators, as: Fixtures
  alias AshA2A.Semantic.Refusal

  @moduletag :tmp_dir
  @moduletag :capture_log
  @moduletag timeout: 600_000

  describe "CHI-REAL court end to end through the runner" do
    @tag :graphlaw_engine
    test "every falsifier reaches its verdict and every pass is OCEL-corroborated", %{
      tmp_dir: dir
    } do
      assert {:ok, run} =
               Runner.run(courts: [RealCollaborators], profile: :core, evidence_dir: dir)

      by_id = Map.new(run.results, &{&1.falsifier_id, &1})

      expected = %{
        "CHI-REAL-001" => :falsifier_killed,
        "CHI-REAL-002" => :falsifier_killed,
        "CHI-REAL-003" => :falsifier_killed,
        "CHI-REAL-004" => :falsifier_killed,
        "CHI-REAL-005" => :falsifier_killed,
        "CHI-REAL-006" => :falsifier_killed,
        "CHI-REAL-007" => :falsifier_killed,
        "CHI-REAL-008" => :positive_control_passed,
        "CHI-REAL-009" => :positive_control_passed,
        "CHI-REAL-010" => :positive_control_passed,
        "CHI-REAL-011" => :falsifier_killed
      }

      assert Map.keys(by_id) |> Enum.sort() == Map.keys(expected) |> Enum.sort()

      for {id, verdict} <- expected do
        result = by_id[id]

        assert result.verdict == verdict,
               "#{id}: #{inspect(result.verdict)} -- #{result.detail} -- #{result.ocel_detail}"

        assert result.attempt_observed? == true, id
        assert result.ocel_corroborated? == true, "#{id}: #{result.ocel_detail}"
      end

      assert run.ocel.dropped == 0

      gate3 = Enum.find(run.receipt["gates"], &(&1["gate"] == 3))
      assert gate3["status"] == "PASSED"
      assert gate3["courts"] == ["CHI-REAL"]

      # The independent consumer re-derives the key facts from disk alone.
      {:ok, index} = Query.load(Path.join(dir, "ocel.json"), run.ocel.sha256)

      assert {true, _} =
               Query.eval(
                 index,
                 "CHI-REAL-001",
                 {:observed, "chicago.collaborators.violation",
                  %{"code" => "authority_not_real_boundary"}}
               )

      assert {true, _} =
               Query.eval(
                 index,
                 "CHI-REAL-004",
                 {:observed, "chicago.collaborators.durability_probe",
                  %{
                    "store" => inspect(Fixtures.LossyDurableStore),
                    "stage" => "read",
                    "outcome" => "missing"
                  }}
               )

      assert {false, _} =
               Query.eval(index, "CHI-REAL-008", {:observed, "chicago.collaborators.violation"})
    end
  end

  describe "inventory of the real running configuration" do
    @tag :graphlaw_engine
    test "identifies all nine roles with the real components and admits them", %{tmp_dir: dir} do
      inv = Collaborators.inventory(claim: :core, probe_dir: dir)

      assert inv.scope == :full
      assert Map.keys(inv.roles) |> Enum.sort() == Enum.sort(Collaborators.roles())
      assert inv.violations == [], inspect(inv.violations, pretty: true)
      assert inv.verdict == :admitted

      engine = inv.roles.semantic_engine
      assert engine.module == AshA2A.GraphLaw.Wasm
      assert engine.digest_bound?
      assert engine.wasm_sha256 == engine.manifest_sha256
      assert engine.version == engine.manifest_version
      assert engine.agrees_with_reference?
      assert engine.port.real?

      assert inv.roles.admission_pipeline.engine_calls |> Enum.member?("batch/2")
      assert inv.roles.authority_broker.policy == :broker
      assert inv.roles.authority_broker.module == AshA2A.Authority.Broker.InMemory
      assert inv.roles.authority_broker.fail_closed_proven?
      # b4p-f5-10: CommandBus's re-dispatch now carries `resolved_skill:` (a 6th
      # opt arg) so the exact resolved skill is dispatched, never a display-name
      # rematch — the recorded actuator call is accordingly dispatch/6.
      assert inv.roles.consequence_boundary.actuator_calls == ["dispatch/6"]
      assert inv.roles.receipt_store.module == AshA2A.CommandBus.default_store()
      assert inv.roles.independent_verifier.module == AshA2A.Chicago.Query
      assert inv.mock_scan.outcome == :clean
      assert inv.mock_scan.dirs == ["lib", "test"]
    end

    test "under a :do claim the default in-memory store is refused, not assumed durable", %{
      tmp_dir: dir
    } do
      inv =
        Collaborators.inventory(
          claim: :do,
          roles: [:receipt_store],
          scan: false,
          receipt_store: AshA2A.ReceiptStore.Memory,
          probe_dir: dir
        )

      assert inv.verdict == :refused
      assert Collaborators.violation?(inv, :receipt_store_not_durable)
      refute inv.roles.receipt_store.proven_durable?
    end

    test "its violation codes classify without editing the Refusal table" do
      for {code, class} <- Collaborators.__sa2a_refusal_codes__() do
        assert Refusal.classify(code) == class
      end
    end
  end

  describe "DurabilityProbe proves durability by real restart" do
    test "EKV keeps the write across a real restart and replays it", %{tmp_dir: dir} do
      result = DurabilityProbe.run(AshA2A.ReceiptStore.Ekv, probe_dir: dir)

      assert %{write: :committed, restarted?: true, read: :found, replay: :replay} = result
      assert result.proven?
    end

    test "the in-memory store loses the write across a real restart", %{tmp_dir: dir} do
      result = DurabilityProbe.run(AshA2A.ReceiptStore.Memory, probe_dir: dir)

      assert %{write: :committed, restarted?: true, read: :missing} = result
      refute result.proven?
    end

    test "a store that declares durable?() true but keeps writes in memory is not proven", %{
      tmp_dir: dir
    } do
      assert Fixtures.LossyDurableStore.durable?()
      result = DurabilityProbe.run(Fixtures.LossyDurableStore, probe_dir: dir)

      assert %{write: :committed, restarted?: true, read: :missing, proven?: false} = result
    end

    test "a store module with no startable process is UNKNOWN, never durable" do
      result = DurabilityProbe.run(AshA2A.Chicago.Query)

      assert result.lifecycle == :unsupported
      refute result.proven?
      assert result.detail =~ "child_spec/1"
    end
  end

  describe "MockScan reads the AST, not the text" do
    test "reports each real mocking call with its line" do
      source = """
      defmodule T do
        import Mox
        def a, do: Mox.expect(M, :f, fn -> 1 end)
        def b, do: :meck.new(M, [])
        def c, do: &:meck.unload/1
        def d, do: apply(Mox, :stub, [M, :f, 1])
        def e, do: patch(M, :f, 1)
        def f do
          with_mocks([{M, [], []}]) do
            :ok
          end
        end
      end
      """

      assert {:ok, found} = MockScan.scan_source(source, "t.ex")

      assert Enum.map(found, &{&1.line, &1.call}) == [
               {2, "import Mox"},
               {3, "Mox.expect/3"},
               {4, ":meck.new/2"},
               {5, "&:meck.unload/1"},
               {6, "apply(Mox, :stub, ...)"},
               {7, "patch/3"},
               {9, "with_mocks/2"}
             ]
    end

    test "comments, docs, strings, sigils, atoms and HTTP patch are not calls" do
      source = ~S'''
      defmodule T do
        @moduledoc "Mox.expect(M, :f, 1) and :meck.new(M)"
        # with_mock M, [] do end
        @libs [:meck, Mox, Mock]
        def a, do: "import Mox"
        def b, do: ~S[Mox.stub(M, :f, 1)]
        def c(conn), do: patch(conn, "/x", %{})
        def libs, do: @libs
      end
      '''

      assert {:ok, []} = MockScan.scan_source(source, "t.ex")
    end

    test "unparseable source fails closed with its location" do
      assert {:error, %{file: "bad.ex", line: line}} =
               MockScan.scan_source("defmodule Bad do\n  def x(, do: 1\nend\n", "bad.ex")

      assert line >= 1
    end

    test "this repository's own lib/ and test/ contain no mocking calls" do
      scan = MockScan.scan(root: File.cwd!())

      assert scan.dirs == ["lib", "test"]
      assert scan.files > 100
      assert scan.violations == [], inspect(scan.violations, pretty: true)
      assert scan.unparseable == [], inspect(scan.unparseable, pretty: true)
      assert scan.outcome == :clean
    end
  end

  describe "boundary telemetry added for gate 3" do
    test "Grant.authorize/3 reports the decision it made" do
      ref = make_ref()
      test_pid = self()
      handler = {__MODULE__, ref}

      :ok =
        :telemetry.attach(
          handler,
          [:ash_a2a, :authority, :decision],
          fn _event, _measurements, metadata, _ -> send(test_pid, {ref, metadata}) end,
          nil
        )

      try do
        nonce = System.unique_integer([:positive])
        assert AshA2A.Authority.Grant.authorize("nobody-#{nonce}", "cap-#{nonce}") == nil
        assert_receive {^ref, %{outcome: :refused, policy: :broker, capability_id: capability}}
        assert capability == "cap-#{nonce}"
      after
        :telemetry.detach(handler)
      end
    end
  end
end

# --- SECTION 10: Original test/ash_a2a/chicago/receipt_binding_attestation_test.exs ---
defmodule AshA2A.Chicago.ReceiptBindingAttestationTest do
  @moduledoc """
  Gate 9 complete receipt identity binding (`CHI-RECEIPT`, RFC-SA2A-002 §40,
  §128) and the attestation court (`SA2A-ATTEST`, §24, §72), Chicago style:
  the real `AshA2A.CommandBus`, the real ETS Gate 8 ledger, real
  `AshA2A.ReceiptStore.Memory` / `AshA2A.ReceiptOutbox` on disk, real
  telemetry, and the durable OCEL artifact read back by the independent
  consumer. The binding key is application configuration set and restored
  around the stimulus -- environment, not a double.

  `async: false` -- the Chicago observer attributes every telemetry event
  emitted inside a stimulus, and the key / outbox directory are global env.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  alias AshA2A.{Receipt, ReceiptOutbox}
  alias AshA2A.Chicago
  alias AshA2A.Chicago.{Query, Runner}
  alias AshA2A.Chicago.Courts.{Attestation, ReceiptBinding}
  alias AshA2A.Chicago.Fixtures.ReceiptBindingAttestation, as: Fx
  alias AshA2A.Evidence.{Class, HostedCI, LocalTest, Merge, Production, Publication, RuntimeAlive}
  alias AshA2A.Receipt.{Binding, Replay}
  alias AshA2A.Semantic.{Envelope, Refusal, Standing}
  alias AshA2A.Semantic.Attestation, as: SemanticAttestation

  @moduletag :tmp_dir

  @receipt_expected Map.new(1..30, fn n ->
                      id = "CHI-RECEIPT-" <> String.pad_leading("#{n}", 3, "0")

                      {id,
                       if(n in [26, 27, 28, 30],
                         do: :positive_control_passed,
                         else: :falsifier_killed
                       )}
                    end)

  @attest_expected Map.new(1..14, fn n ->
                     id = "SA2A-ATTEST-" <> String.pad_leading("#{n}", 3, "0")

                     {id,
                      if(n in [13, 14], do: :positive_control_passed, else: :falsifier_killed)}
                   end)

  describe "CHI-RECEIPT + SA2A-ATTEST end to end (Runner, profile :do)" do
    test "every falsifier reaches its verdict and every pass is OCEL-corroborated", %{
      tmp_dir: dir
    } do
      assert {:ok, run} =
               Runner.run(courts: [ReceiptBinding, Attestation], profile: :do, evidence_dir: dir)

      by_id = Map.new(run.results, &{&1.falsifier_id, &1})
      expected = Map.merge(@receipt_expected, @attest_expected)
      assert Enum.sort(Map.keys(by_id)) == Enum.sort(Map.keys(expected))

      for {id, verdict} <- expected do
        result = by_id[id]
        assert result.verdict == verdict, "#{id}: #{inspect(result, pretty: true)}"
        assert result.attempt_observed? == true, id
        assert result.ocel_corroborated? == true, "#{id}: #{result.ocel_detail}"
        assert AshA2A.Chicago.Result.counts_as_pass?(result), id
      end

      assert run.ocel.dropped == 0

      receipt = JSON.decode!(File.read!(Path.join(dir, "standing_receipt.json")))
      assert receipt["results"]["falsifiers_killed"] == 38
      assert receipt["results"]["positive_controls_passed"] == 6
      assert Enum.find(receipt["gates"], &(&1["gate"] == 9))["status"] == "PASSED"
      assert receipt["evidence"]["receipt_binding"] == "PASS"
    end

    test "the independent consumer reads the binding, standing and attestation decisions from disk",
         %{tmp_dir: dir} do
      {:ok, run} =
        Runner.run(courts: [ReceiptBinding, Attestation], profile: :do, evidence_dir: dir)

      assert {:ok, index} = Query.load(Path.join(dir, "ocel.json"), run.ocel.sha256)

      # Each tampered field is refused and named.
      for {n, field} <- [{"001", "actor"}, {"007", "authority_grant"}, {"010", "result_identity"}] do
        assert {true, _} =
                 Query.eval(
                   index,
                   "CHI-RECEIPT-" <> n,
                   {:observed, "receipt.binding.verify",
                    %{
                      "outcome" => "refused",
                      "code" => "receipt_binding_field_mismatch",
                      "fields" => field
                    }}
                 )
      end

      # Key posture refusals are typed, not collapsed.
      for {n, code} <- [
            {"023", "receipt_binding_downgraded"},
            {"024", "receipt_binding_keyed_claim_unbacked"},
            {"025", "receipt_binding_key_mismatch"},
            {"029", "receipt_binding_result_unbound"}
          ] do
        assert {true, _} =
                 Query.eval(
                   index,
                   "CHI-RECEIPT-" <> n,
                   {:observed, "receipt.binding.verify", %{"code" => code}}
                 )
      end

      # §128 alternate encodings of llm_output refuse as inferred standing.
      for n <- ["018", "019", "020", "021"] do
        assert {true, _} =
                 Query.eval(
                   index,
                   "CHI-RECEIPT-" <> n,
                   {:observed, "semantic.standing.transition",
                    %{
                      "code" => "standing_inferred",
                      "forbidden_inference_sources" => "llm_output"
                    }}
                 )
      end

      # An evidence class earned elsewhere does not attest these receipts.
      assert {true, _} =
               Query.eval(
                 index,
                 "SA2A-ATTEST-009",
                 {:observed, "attestation.verify",
                  %{
                    "code" => "attestation_claims_unobserved_evidence",
                    "field" => "evidence_class"
                  }}
               )
    end

    test "both courts are discoverable for SA2A-DO with complete §11 declarations" do
      for court <- [ReceiptBinding, Attestation] do
        assert court in Chicago.courts_for(:do)
        refute court in Chicago.courts_for(:plan)
        assert Enum.all?(court.falsifiers(), &(&1.attempt_predicate && &1.outcome_predicate))
      end

      assert ReceiptBinding.gate() == 9
      assert length(ReceiptBinding.falsifiers()) == 30
      assert length(Attestation.falsifiers()) == 14
    end

    test "new refusal codes carry an S42 class" do
      for {code, class} <-
            Map.put(
              Binding.refusal_codes(),
              :attestation_receipt_binding_refused,
              :refused_receipt
            ) do
        assert Refusal.classify(code) == class, "#{code}"
      end
    end
  end

  describe "AshA2A.Receipt.Binding over real CommandBus receipts" do
    setup %{tmp_dir: dir} do
      previous_key = Application.fetch_env(:ash_a2a, :receipt_binding_key)
      previous_outbox = Application.fetch_env(:ash_a2a, :receipt_outbox_dir)
      Application.delete_env(:ash_a2a, :receipt_binding_key)
      Application.put_env(:ash_a2a, :receipt_outbox_dir, Path.join(dir, "outbox"))

      name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
      {:ok, pid} = AshA2A.ReceiptStore.Memory.start_link(name: name)

      on_exit(fn ->
        AshA2A.TestSupport.SafeStop.stop(pid)
        restore(:receipt_binding_key, previous_key)
        restore(:receipt_outbox_dir, previous_outbox)
      end)

      %{store_opts: [name: name]}
    end

    test "a committed receipt is bound prepared -> final -> postcondition and survives ETF on disk",
         %{store_opts: store_opts, tmp_dir: dir} do
      %{receipt: receipt} = Fx.execute("unit-honest", :honest_write, store_opts)

      assert %{keyed: false, algorithm: "sha256", key_id: nil, links: links} = receipt.binding
      assert Enum.map(links, & &1.stage) == [:prepared, :final, :postcondition]
      assert [nil, a, b] = Enum.map(links, & &1.predecessor)
      assert a == Enum.at(links, 0).digest and b == Enum.at(links, 1).digest

      from_disk = dir |> Fx.persist!("unit-honest", receipt) |> Fx.read_back!()
      assert {:ok, %{stage: :postcondition, keyed: false, links: 3}} = Binding.verify(from_disk)
      assert {:ok, %Replay.Basis{}} = Replay.basis(from_disk)
    end

    test "tampered and unbound receipts lose replay standing; a contradicted result cannot be laundered",
         %{store_opts: store_opts} do
      %{receipt: honest} = Fx.execute("unit-replay", :honest_write, store_opts)
      %{receipt: contradicted} = Fx.execute("unit-lie", :lying_write, store_opts)

      assert contradicted.status == :postcondition_contradicted
      assert {:ok, %{stage: :postcondition}} = Binding.verify(contradicted)

      laundered = %{contradicted | status: :completed}

      assert {:error,
              %{code: :receipt_binding_field_mismatch, detail: %{fields: [:result_identity]}}} =
               Binding.verify(laundered)

      assert {:error, %{code: :receipt_binding_field_mismatch}} =
               Replay.basis(%{honest | actor: AshA2A.Identity.principal("mallory")})

      assert {:error, %{code: :receipt_unbound}} = Replay.basis(%{honest | binding: nil})
    end

    test "the real outbox drain reseals an intact receipt and never a tampered one", %{
      store_opts: store_opts
    } do
      %{receipt: intact} = Fx.execute("unit-outbox", :honest_write, store_opts)
      %{receipt: other} = Fx.execute("unit-outbox-tamper", :honest_write, store_opts)
      target = Module.concat(__MODULE__, "Drain#{System.unique_integer([:positive])}")
      {:ok, pid} = AshA2A.ReceiptStore.Memory.start_link(name: target)
      on_exit(fn -> AshA2A.TestSupport.SafeStop.stop(pid) end)

      tampered = %{other | plan_digest: Fx.sha("forged-plan")}
      assert :ok = ReceiptOutbox.append(intact)
      assert :ok = ReceiptOutbox.append(tampered)

      assert {:ok, %{committed: 2}} =
               ReceiptOutbox.reconcile(AshA2A.ReceiptStore.Memory, name: target)

      assert {:ok, %Receipt{terminal_status: :reconciled} = drained} =
               AshA2A.ReceiptStore.Memory.fetch(intact.command_id, name: target)

      assert {:ok, %{stage: :reconciled}} = Binding.verify(drained)

      assert {:ok, %Receipt{terminal_status: :reconciled} = drained_tampered} =
               AshA2A.ReceiptStore.Memory.fetch(tampered.command_id, name: target)

      assert {:error, %{code: :receipt_binding_field_mismatch}} = Binding.verify(drained_tampered)
    end

    test "keyed MAC: the key is never recorded and verification is fail-closed on key posture", %{
      store_opts: store_opts
    } do
      key = "unit-receipt-binding-key"

      keyed =
        Fx.with_key(key, fn -> Fx.execute("unit-keyed", :honest_write, store_opts).receipt end)

      assert %{keyed: true, algorithm: "hmac-sha256", key_id: key_id, links: links} =
               keyed.binding

      assert key_id == Binding.key_id(key)
      refute inspect(keyed.binding) =~ key
      assert Enum.all?(links, &String.starts_with?(&1.digest, "hmac-sha256:"))

      assert {:ok, %{keyed: true}} = Binding.verify(keyed, key: key)
      assert {:error, %{code: :receipt_binding_key_unavailable}} = Binding.verify(keyed, key: nil)

      assert {:error, %{code: :receipt_binding_key_mismatch}} =
               Binding.verify(keyed, key: "other")

      %{receipt: unkeyed} = Fx.execute("unit-unkeyed", :honest_write, store_opts)
      assert {:ok, %{keyed: false}} = Binding.verify(unkeyed, key: nil)
      assert {:error, %{code: :receipt_binding_downgraded}} = Binding.verify(unkeyed, key: key)
    end

    test "a duplicate actuation through the real bus is receipted with a verifying :deduplicated link",
         %{store_opts: store_opts} do
      key = "unit-dedup-#{System.unique_integer([:positive])}"
      capability = AshA2A.Chicago.Fixtures.Postcondition.capability(:honest_write)
      principal = AshA2A.Identity.principal("chicago-receipt-subject")

      command = fn suffix ->
        AshA2A.Command.new(capability,
          command_id: "chicago-receipt-dedup-#{suffix}-#{key}",
          agent_id: "chicago-receipt-agent",
          principal_id: principal,
          authority: AshA2A.Authority.new(principal, capability, token_id: "tok-" <> key),
          input: %{key: key, value: "X"}
        )
      end

      message =
        AshA2A.Protocol.Message.new_user([
          AshA2A.Protocol.Part.Data.new(%{"key" => key, "value" => "X"})
        ])

      opts = [store_opts: store_opts, actuation_dedup: :strict]
      ledger = AshA2A.Chicago.Fixtures.Postcondition.Ledger

      assert {:ok, %Receipt{status: :completed} = first} =
               AshA2A.CommandBus.run(command.("first"), message, ledger, opts)

      assert {:ok, %Receipt{metadata: %{outcome: :deduplicated}} = second} =
               AshA2A.CommandBus.run(command.("second"), message, ledger, opts)

      assert first.actuation_id == second.actuation_id
      assert List.last(second.binding.links).stage == :deduplicated
      assert {:ok, %{stage: :deduplicated}} = Binding.verify(second)
      assert AshA2A.Chicago.Fixtures.Postcondition.stored_values(key) == ["X"]
    end
  end

  describe "AshA2A.Semantic.Standing §128 laundering resistance" do
    test "alternate encodings of llm_output refuse with the canonical key and full path" do
      base = %{transport: "https", received_at: "2026-09-16T00:00:00Z"}

      for {evidence, path} <- [
            {Map.put(base, :bundle, llm_output: "x"), ["bundle", 0, "llm_output"]},
            {Map.put(base, :bundle, [{"llm_output", "x"}]), ["bundle", 0, "llm_output"]},
            {Map.put(base, :tagged, {:llm_output, "x"}), ["tagged", "llm_output"]},
            {Map.put(base, "llmOutput", "x"), ["llmOutput"]},
            {Map.put(base, :bundle, %{"LLM-Output" => "x"}), ["bundle", "LLM-Output"]},
            {Map.put(base, :bundle, ok: [confidence: 0.99]), ["bundle", 0, "ok", 0, "confidence"]}
          ] do
        envelope =
          Envelope.new!(%{
            envelope_id: "urn:unit:#{System.unique_integer([:positive])}",
            kind: "sa2a:Request"
          })

        assert {:error, %Refusal{code: :standing_inferred, detail: detail}} =
                 Standing.transition(envelope, :received, evidence)

        assert detail.forbidden_inference_paths == [path], inspect(evidence)
        assert Enum.all?(detail.forbidden_inference_sources, &is_atom/1)
      end
    end

    test "clean evidence with keyword lists and pair tuples still transitions" do
      envelope = Envelope.new!(%{envelope_id: "urn:unit:clean", kind: "sa2a:Request"})

      evidence = %{
        transport: "https",
        received_at: "2026-09-16T00:00:00Z",
        bundle: [source: "bytes", status: {:ok, "fine"}],
        pairs: [{"digest", Fx.sha("clean")}]
      }

      assert {:ok, %Envelope{standing: :received}} =
               Standing.transition(envelope, :received, evidence)
    end
  end

  describe "AshA2A.Semantic.Attestation evidence class backing (§72)" do
    test "an earned class from an unrelated chain does not attest a local_test receipt", %{
      tmp_dir: _dir
    } do
      name = Module.concat(__MODULE__, "AttestStore#{System.unique_integer([:positive])}")
      {:ok, pid} = AshA2A.ReceiptStore.Memory.start_link(name: name)
      on_exit(fn -> AshA2A.TestSupport.SafeStop.stop(pid) end)

      %{receipt: receipt} = Fx.execute("unit-attest", :honest_write, name: name)
      assert {:ok, honest} = SemanticAttestation.from_receipts([receipt])
      assert %LocalTest{} = honest.evidence_class
      assert %{keyed: false, digests: [_]} = honest.receipt_binding
      assert :ok = SemanticAttestation.verify(honest, [receipt])

      merge =
        Enum.reduce(
          [
            {HostedCI, %{job: 1}},
            {Production, %{d: 1}},
            {RuntimeAlive, %{p: 1}},
            {Publication, %{r: 1}},
            {Merge, %{pr: 1}}
          ],
          LocalTest.new(%{suite: "elsewhere"}),
          fn {target, basis}, current ->
            {:ok, next} = Class.promote(current, target, basis)
            next
          end
        )

      assert :ok = Class.verify_chain(merge)

      assert {:error, %{code: :attestation_claims_unobserved_evidence, detail: :evidence_class}} =
               SemanticAttestation.verify(%{honest | evidence_class: merge}, [receipt])
    end
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:ash_a2a, key, value)
  defp restore(key, :error), do: Application.delete_env(:ash_a2a, key)
end

# --- SECTION 11: Original test/ash_a2a/chicago/root_manifest_meta_admission_test.exs ---
defmodule AshA2A.Chicago.RootManifestMetaAdmissionTest do
  @moduledoc """
  Meta-Admission (`SA2A-META`, RFC-SA2A-002 §52, §136, §137) and Root Manifest
  (`SA2A-ROOT`, §53) courts run end to end through the real
  `AshA2A.Chicago.Runner`: the real `AshA2A.Semantic.AdmissionPipeline` over the
  real `praxis-graphlaw` wasm, real `AshA2A.Semantic.LogicClosure`, SPARQL.ex,
  `hddl_cli`, receipt stores, Root Manifests over real files, real nested
  qualification runs, the real observer and the durable OCEL artifact read back
  by the independent consumer. No mocks, no stubs.

  `async: false` -- the observer attributes every telemetry event between a
  stimulus start and stop to that falsifier.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_solo
  alias AshA2A.Chicago
  alias AshA2A.Chicago.{CourtManifest, Result, Runner, StandingReceipt, Subject}
  alias AshA2A.Chicago.Courts.{MetaAdmission, RootManifest}
  alias AshA2A.Chicago.Fixtures.RootManifestMeta, as: F
  alias AshA2A.Semantic.{Refusal, RootManifest.ConformanceCorpus}

  @moduletag :tmp_dir

  @engine_unavailable (case AshA2A.GraphLaw.Wasm.availability() do
                         :ok -> nil
                         {:error, detail} -> "real GraphLaw wasm unavailable: #{inspect(detail)}"
                       end)

  @meta_expected Map.new(1..19, fn n ->
                   id = "SA2A-META-" <> String.pad_leading("#{n}", 3, "0")
                   {id, if(n in 16..19, do: :positive_control_passed, else: :falsifier_killed)}
                 end)

  @root_expected Map.new(1..15, fn n ->
                   id = "SA2A-ROOT-" <> String.pad_leading("#{n}", 3, "0")
                   {id, if(n in 14..15, do: :positive_control_passed, else: :falsifier_killed)}
                 end)

  describe "end to end over the real runner" do
    @tag :graphlaw
    if @engine_unavailable, do: @tag(skip: @engine_unavailable)

    test "every falsifier reaches its verdict, OCEL-corroborated, under the admitted court manifest",
         %{tmp_dir: dir} do
      assert {:ok, run} =
               Runner.run(
                 courts: [MetaAdmission, RootManifest],
                 profile: :strict,
                 evidence_dir: dir
               )

      verdicts = Map.new(run.results, &{&1.falsifier_id, &1.verdict})
      assert verdicts == Map.merge(@meta_expected, @root_expected)

      for result <- run.results do
        assert result.ocel_corroborated? == true,
               "#{result.falsifier_id} #{result.verdict}: #{result.ocel_detail} / #{result.detail}"

        assert result.attempt_observed? == true, result.falsifier_id
      end

      by_id = Map.new(run.results, &{&1.falsifier_id, &1})

      # §52 pipeline law: each substitute is refused by law standing at the
      # stage whose law it replaced, with canonical state unchanged.
      for {id, stage} <- [
            {"SA2A-META-001", "shex"},
            {"SA2A-META-002", "shacl"},
            {"SA2A-META-003", "rule_closure"},
            {"SA2A-META-004", "profile_checks"}
          ] do
        evidence = by_id[id].evidence
        assert evidence["refusal"] =~ "stage=#{stage} code=law_without_standing", id
        assert evidence["canonical_unchanged"] == true, id
      end

      # §52 gate kinds: the substitute's real machinery really produced a
      # positive apparent result, the artifact is not pinned, and the gate
      # still refused it -- the kill is not vacuous.
      for n <- 5..11 do
        evidence = by_id["SA2A-META-0" <> String.pad_leading("#{n}", 2, "0")].evidence
        assert evidence["apparent_positive"] == true, evidence["kind"]
        assert evidence["artifact_pinned"] == false, evidence["kind"]
        assert evidence["reply"] =~ "REFUSED_META_RIGOR", evidence["kind"]
        assert evidence["reply"] =~ "not_pinned", evidence["kind"]
      end

      assert by_id["SA2A-META-012"].evidence["reply"] =~ "semantic_mapping_receipt_unbound"
      assert by_id["SA2A-META-012"].evidence["receipt_held_by_store"] == true

      # §137: the nested runs record the exact drift, and the clean one is crowned.
      for {id, drift} <- [
            {"SA2A-META-013", "court:SA2A-METAFIX-G1:falsifier_corpus_digest"},
            {"SA2A-META-014", "ocel_validator"},
            {"SA2A-META-015", "court:SA2A-METAFIX-G3:unadmitted"}
          ] do
        evidence = by_id[id].evidence
        assert evidence["nested_standing"] == "PARTIAL_ALIVE", id
        assert evidence["court_manifest"]["verification"] == "drift", id
        assert drift in evidence["court_manifest"]["drift"], id
      end

      assert by_id["SA2A-META-019"].evidence["nested_standing"] == "CONFORMANT"

      # §53: every use-time attack is refused by the component it substituted.
      for {id, component} <- [
            {"SA2A-ROOT-002", :pins},
            {"SA2A-ROOT-003", :content_address},
            {"SA2A-ROOT-004", :canonicalization},
            {"SA2A-ROOT-005", :manufacturers},
            {"SA2A-ROOT-006", :pins},
            {"SA2A-ROOT-007", :engine},
            {"SA2A-ROOT-008", :authority_broker},
            {"SA2A-ROOT-009", :brce_contract},
            {"SA2A-ROOT-010", :receipt_law},
            {"SA2A-ROOT-011", :hash_algorithms},
            {"SA2A-ROOT-012", :version_policy}
          ] do
        assert by_id[id].evidence["refused_component"] == component, id
      end

      assert by_id["SA2A-ROOT-001"].evidence["document_bytes_changed"] == true
      assert by_id["SA2A-ROOT-001"].evidence["recorded_digest_untouched"] == true
      assert by_id["SA2A-ROOT-002"].evidence["ontology_root_bytes_match_pin"] == false
      assert by_id["SA2A-ROOT-006"].evidence["shapes_bytes_match_pin"] == false
      assert by_id["SA2A-ROOT-006"].evidence["consumer_reply"] =~ "REFUSED_META_RIGOR"
      assert by_id["SA2A-ROOT-013"].evidence["reply"] =~ "REFUSED_ROOT_CUSTODY"

      receipt = JSON.decode!(File.read!(Path.join(dir, "standing_receipt.json")))
      assert receipt["results"]["survived_ids"] == []
      assert receipt["results"]["unresolved_ids"] == []
      assert receipt["results"]["falsifiers_killed"] == 28
      assert receipt["results"]["positive_controls_passed"] == 6
      assert receipt["court"]["version"] == CourtManifest.version()
      assert receipt["court"]["manifest"]["verification"] == "admitted"

      assert receipt["court"]["ocel_validator_identity"]["module"] ==
               "AshA2A.Chicago.Ocel.Validator"

      assert is_binary(receipt["court"]["ocel_validator_identity"]["beam_md5"])
      assert receipt["subject"]["root_manifest_digest"] == committed_root_digest()
      assert StandingReceipt.verify_digest(receipt) == :ok
      assert run.ocel.dropped == 0
    end
  end

  describe "environment fault injection: engine artifact absent" do
    test "engine-backed falsifiers are blocked with the measured reason, never killed",
         %{tmp_dir: dir} do
      previous = Application.get_env(:ash_a2a, :graphlaw_wasm_path)
      Application.put_env(:ash_a2a, :graphlaw_wasm_path, Path.join(dir, "absent.wasm"))

      try do
        {:ok, run} =
          Runner.run(courts: [RootManifest, MetaAdmission], profile: :strict, evidence_dir: dir)

        by_id = Map.new(run.results, &{&1.falsifier_id, &1})

        for {id, result} <- by_id, String.starts_with?(id, "SA2A-ROOT") do
          assert result.verdict == :blocked, id
          assert result.detail =~ "engine artifact not resolvable"
        end

        for n <- ~w(001 002 003 004 005 006 007 008 009 010 011 013 014 015 016 017 019) do
          assert by_id["SA2A-META-" <> n].verdict == :blocked, n
        end

        # Boundaries that need no engine still ran for real.
        assert by_id["SA2A-META-012"].verdict == :falsifier_killed
        assert by_id["SA2A-META-018"].verdict == :positive_control_passed
        assert by_id["SA2A-META-018"].ocel_corroborated? == true
      after
        if previous,
          do: Application.put_env(:ash_a2a, :graphlaw_wasm_path, previous),
          else: Application.delete_env(:ash_a2a, :graphlaw_wasm_path)
      end
    end
  end

  describe "court declarations" do
    test "both courts are discoverable strict courts with fully declared falsifiers" do
      for {court, count} <- [{MetaAdmission, 19}, {RootManifest, 15}] do
        assert court in Chicago.courts()
        assert court.profile() == :strict
        assert length(court.falsifiers()) == count

        for f <- court.falsifiers() do
          assert String.starts_with?(f.id, court.id() <> "-")
          assert f.attempt_predicate != nil and f.outcome_predicate != nil, f.id
        end
      end

      refute F.GateCourt1 in Chicago.courts()
    end

    test "the committed court manifest admits both courts and the default validator" do
      assert {:admitted, digest} = CourtManifest.admission([MetaAdmission, RootManifest])
      assert {:ok, committed} = CourtManifest.load()
      assert committed["digest"] == digest
      assert CourtManifest.digest(committed) == digest

      ids = Enum.map(committed["courts"], & &1["id"])
      assert "SA2A-META" in ids and "SA2A-ROOT" in ids
    end
  end

  describe "court manifest and standing" do
    test "the manifest is deterministic and declaration-derived" do
      courts = F.gate_courts()
      assert CourtManifest.build(courts) == CourtManifest.build(Enum.reverse(courts))

      refute CourtManifest.build([F.GateCourt1]) == CourtManifest.build([F.GateCourt1Drifted])

      tampered = Map.put(CourtManifest.build(courts), "court_version", "chicago-court/0")
      assert {:drift, _, fields} = CourtManifest.admission(courts, [], tampered)
      assert "court_manifest_digest" in fields and "court_version" in fields

      assert {:drift, nil, [unavailable]} =
               CourtManifest.admission(courts, [], "/nonexistent.json")

      assert unavailable =~ "court_manifest_unavailable"
    end

    test "drift bars CONFORMANT in the pure recomputation, and round-trips through the receipt" do
      [f | _] = F.GateCourt1.falsifiers()

      results =
        for gate <- 1..3 do
          %{
            Result.positive(f, attempt_observed?: true, expected_outcome_observed?: true)
            | gate: gate,
              ocel_corroborated?: true
          }
        end

      facts = %{
        profile: :core,
        courts: Enum.map(1..3, &%{id: "C#{&1}", gate: &1}),
        results: results,
        ocel_validation_status: :valid,
        ocel_dropped: 0,
        source_revision: "rev",
        court_revision: String.duplicate("0", 64)
      }

      assert StandingReceipt.recompute(facts).standing == :conformant

      admitted = StandingReceipt.recompute(Map.put(facts, :court_admission, {:admitted, "d"}))
      assert admitted.standing == :conformant

      drift = {:drift, "d", ["ocel_validator"]}
      drifted = StandingReceipt.recompute(Map.put(facts, :court_admission, drift))
      assert drifted.standing == :partial_alive
      assert drifted.claim =~ "court manifest drift: ocel_validator"

      for admission <- [:not_evaluated, {:admitted, "d"}, drift] do
        assert admission |> CourtManifest.to_map() |> CourtManifest.from_map() == admission
      end
    end
  end

  describe "SUT surfaces this slice introduced" do
    test "the subject binds the committed Root Manifest's verified content address by default" do
      assert Subject.capture().root_manifest_digest == committed_root_digest()
    end

    test "new refusal codes are classified without editing the refusal table" do
      assert Refusal.classify(:law_without_standing) == :refused_meta_rigor
      assert Refusal.classify(:root_manifest_unavailable) == :refused_meta_rigor
      assert Refusal.classify(:semantic_mapping_receipt_not_held) == :refused_receipt
      assert Refusal.classify(:semantic_mapping_receipt_unbound) == :refused_receipt
      assert Refusal.classify(:court_manifest_not_an_object) == :refused_structure
    end

    @tag :graphlaw_engine
    test "the committed Root Manifest is reproduced from the corpus and verifies at use" do
      {:ok, rebuilt} = ConformanceCorpus.build()
      assert rebuilt.digest == committed_root_digest()

      {:ok, loaded} = AshA2A.Semantic.RootManifest.load(nil, require_engine: false)

      assert {:ok, _} =
               AshA2A.Semantic.RootManifest.verify_use(loaded, expected_digest: rebuilt.digest)

      assert loaded.brce_contract["boundary"] == "run/4"

      assert loaded.canonicalization["graph_identity"] ==
               AshA2A.Semantic.CanonicalGraph.algorithm_id()
    end
  end

  defp committed_root_digest do
    ConformanceCorpus.manifest_path() |> File.read!() |> JSON.decode!() |> Map.fetch!("digest")
  end
end

# --- SECTION 12: Original test/ash_a2a/chicago/sa2a_v26_9_17_fond_qualification_test.exs ---
defmodule AshA2A.Chicago.SA2AV26917FondQualificationTest do
  @moduledoc """
  Qualifies the real `native/hddl_cli` (ferroplan, strong-cyclic FOND) solver
  against `test/support/hddl/sa2a_v26_9_17_dogfood/{domain,problem}.hddl` -- a
  HDDL model of the v26.9.17 cross-repo SA2A self-improvement release-
  qualification loop (Orient -> CloseBoundaries -> Episode1(UNKNOWN->
  Experience) -> Episode2(KNOWN->Replay) -> Certify), spanning 11 real local
  repos as HDDL objects (autofde-lab, ash-a2a, ash-r2rml, bcinr, ggen,
  ggen-igniter, xaas, affidavit, beam4pm, unrdf, wasm4pm). Repo-topology
  grounding (a sibling Design-phase investigation, not re-derived here) found
  9 of these 11 real, ALIVE-or-PARTIAL local repos actually implementing the
  capability their HDDL object claims (autofde-lab/cap-crown, ash-a2a/
  cap-orchestration, ash-r2rml/cap-semantic-feedback, bcinr/cap-bounded-select,
  ggen/cap-manufacture, ggen-igniter/cap-framework-projection, xaas/
  cap-system-authority, affidavit/cap-standing all ALIVE; beam4pm/
  cap-process-court PARTIAL) -- real-world grounding for why this domain
  models what it models, not just an abstract exercise.

  Shells out to the real `native/hddl_cli/target/release/hddl_cli` binary via
  `System.cmd/2` (a real OS subprocess, zero Mock/mox/patch/monkeypatch) and
  asserts on the real decoded JSON/exit code it produces, mirroring
  `test/ash_a2a_hddl_solver_qualification_test.exs`'s own conventions exactly.

  ## The real, honest result this test asserts

  The fully reconciled domain reports **real NoPlan (not solved)** -- and this
  is the correct, disclosed, non-overclaimed result, not a failure to fix.

  Three sibling Design-phase investigations (episode1-recovery,
  episode2-and-receipt-boundary, repo-topology-grounding) independently
  verified, predicate by predicate, which of the domain's many
  non-deterministic (`oneof`) failure branches are genuine *modeling gaps*
  (a real recovery path exists and was added) versus genuine *intentional
  terminal states* (adding a "retry until it works" method would fabricate
  confidence or bypass a real invariant rather than repair a fixable fact).
  This test's fixture is their reconciled union:

  Recoverable and repaired (diagnose -> repair -> re-verify/re-admit, mirroring
  the domain's own pre-existing `build-broken`/`blocked` repo-boundary
  pattern): `allocation-blocked`, `manufacture-failed`, `authority-refused`
  (episode 1's `admit-authority` occurrence only), `actuation-failed`
  (episode 1's `execute-command` occurrence only), `candidate-refused`,
  `candidate-blocked` (via restructuring `admit-candidate` into a real
  compound task, mirroring `qualify-boundary`).

  Left deliberately terminal, no repair method added, each independently
  confirmed fatal-when-reachable by a real isolated ablation: `unsupported`
  (repo boundary -- capability genuinely doesn't exist), `candidate-unsupported`
  (same reasoning at the admission layer), `verification-failed` and
  `process-nonconformant` (both episodes -- independent evidence courts;
  retrying them until they pass would erase a real finding, not repair a
  fixable fact), `candidate-refused candidate-experience` (knowledge-promotion
  admission court -- the domain's own comment already states failing it does
  not invalidate the real execution receipt), `equivalence-failed` (no
  separately-fixable intervening state exists), `receipt-reconcile-blocked`
  (both episodes -- the domain's own explicit "NEVER replay automatically"
  BRCE zero-unreceipted-actuation invariant; real corroborating evidence in
  `ash_a2a/lib/ash_a2a/command_bus.ex`, whose reconciliation path is a
  distinct, presumably operator-invoked function, never folded into automatic
  dispatch), and `authority-refused`/`actuation-failed` on their EPISODE 2
  (replay) occurrences specifically -- deliberately left unwired even though
  episode 1's identically-named predicate got a real repair, because episode
  2's replay actions are real, separate call sites this reconciliation never
  wires a retry into (confirmed: `command_bus.ex`'s only real retries are
  bounded RECEIPT-COMMIT persistence retries, a different, later step, never
  execute/replay-execute itself).

  A real, previously-undiscovered bug was also found and fixed during
  reconciliation, independent of the above: `classify-problem` (wired into
  `run-discovery-episode`'s `e2` slot) had precondition `(classified ?e)`,
  but the only action that ever produces `classified` (`observe-classification`)
  was never invoked by any task/method anywhere in the domain -- an orphaned
  action, structurally identical to leaving a `oneof` branch permanently
  unreachable. Confirmed by stripping every OTHER `oneof` in the pasted
  domain down to its success-only branch (a maximal positive control) and
  observing it STILL returned real NoPlan; the minimal, non-inventive fix
  wraps `classify-problem`/`observe-classification` in a `classify-episode`
  task using the domain's own already-established `qualify-boundary`/
  `verify-boundary`/`resolve-boundary-result` "already done, else observe it
  for real" pattern -- inventing no new action or predicate.

  With that bug fixed and every remaining branch classified as above, a
  careful reconstruction that neutralizes exactly (and only) the confirmed
  terminal branches -- built from a from-scratch success-only baseline with
  each recoverable branch surgically restored one at a time and in
  combination -- reports real `solved: true`. This proves the honest `NoPlan`
  this test asserts against the real, undiluted fixture is fully and only
  explained by the deliberately-uncovered terminal predicates above: no other
  latent defect remains. See the manufacturing receipt for the exact real
  ablation commands and outputs (both the individual per-predicate ablations
  from the three sibling Design-phase tasks, and this reconciliation's own
  positive-control mechanism check).

  The real, load-bearing structural finding this whole exercise surfaces: the
  pinned ferroplan rev's `PlanningType::Fond` dispatch requires strong-cyclic
  coverage of *every* reachable `oneof` branch, with no HDDL syntax to declare
  an accepted non-goal terminal state (`adapt_problem` in `hddl.rs` hardcodes
  `unsafe_states`/`soft_goal_facts` to `Default::default()`, and neither field
  is consulted by `fond_policy_strong_cyclic` in a way that would help even if
  it could be populated from HDDL). A domain author who wants a genuine
  zero-unreceipted-actuation / non-rubber-stamp-court invariant (as this
  domain deliberately does, matching the real ash_a2a/command_bus.ex system it
  models) and wants this CLI to report a real strong-cyclic solve cannot have
  both at once for those predicates. That tension is real and unresolved by
  any existing knob in this pinned ferroplan rev -- an honest `NoPlan` is the
  correct report, not a defect to paper over.
  """

  use ExUnit.Case, async: true

  @cli_path Path.expand("../../../native/hddl_cli/target/release/hddl_cli", __DIR__)

  @domain Path.expand(
            "../../support/hddl/sa2a_v26_9_17_dogfood/domain.hddl",
            __DIR__
          )
  @problem Path.expand(
             "../../support/hddl/sa2a_v26_9_17_dogfood/problem.hddl",
             __DIR__
           )

  setup_all do
    unless File.exists?(@cli_path) do
      flunk("""
      hddl_cli binary not built at #{@cli_path}.
      Run: cd #{Path.expand("../../../native/hddl_cli", __DIR__)} && cargo build --release --locked
      """)
    end

    :ok
  end

  defp run_hddl_cli!(domain_path, problem_path) do
    {stdout, exit_code} = System.cmd(@cli_path, [domain_path, problem_path])

    decoded =
      case JSON.decode(stdout) do
        {:ok, decoded} ->
          decoded

        {:error, reason} ->
          flunk("hddl_cli produced non-JSON stdout: #{inspect(reason)}: #{stdout}")
      end

    {decoded, exit_code, stdout}
  end

  test "the real hddl_cli solver reports genuine NoPlan for the fully reconciled v26.9.17 domain" do
    assert File.exists?(@domain), "fixture domain missing: #{@domain}"
    assert File.exists?(@problem), "fixture problem missing: #{@problem}"

    {decoded, exit_code, raw} = run_hddl_cli!(@domain, @problem)

    # This is the real, asserted result: NoPlan, not solved. See moduledoc for
    # the full, disclosed reasoning on why this is the correct outcome and not
    # a failure to fix -- the domain models real, deliberate BRCE
    # zero-unreceipted-actuation and independent-evidence-court invariants
    # that this pinned ferroplan rev has no syntax to mark as acceptable
    # non-goal terminals, so a genuinely faithful model of them is honestly
    # unsolvable under PlanningType::Fond's universal-coverage requirement.
    refute exit_code == 0,
           "expected the real hddl_cli to report a non-zero exit for this " <>
             "genuinely unsolvable pair. Real raw stdout: #{raw}"

    assert Map.has_key?(decoded, "error"),
           "expected an \"error\" key (the real solver's NoPlan shape) from " <>
             "the real binary. Real raw stdout: #{raw}"

    assert decoded["error"] =~ "NoPlan",
           "expected the real solver's error to name NoPlan specifically " <>
             "(not a grounding/parse error -- this fixture is confirmed to " <>
             "ground cleanly), got: #{inspect(decoded["error"])}. " <>
             "Real raw stdout: #{raw}"

    refute decoded["solved"] == true,
           "the sa2a_v26_9_17_dogfood pair must never be reported solved -- " <>
             "if it ever is, either a genuinely-terminal invariant was " <>
             "silently weakened or ferroplan gained new behavior; either way " <>
             "this assertion, not a passing green run, is the signal to " <>
             "re-investigate. Real raw stdout: #{raw}"
  end

  test "the domain fixture grounds cleanly (the NoPlan above is semantic, not a parse/grounding error)" do
    {decoded, _exit_code, raw} = run_hddl_cli!(@domain, @problem)

    refute decoded["error"] =~ "parse error",
           "fixture must ground cleanly -- a parse error would mean the " <>
             "NoPlan assertion above is not testing what it claims to. " <>
             "Real raw stdout: #{raw}"

    refute decoded["error"] =~ "grounding error",
           "fixture must ground cleanly -- a grounding error would mean the " <>
             "NoPlan assertion above is not testing what it claims to. " <>
             "Real raw stdout: #{raw}"
  end
end

# --- SECTION 13: Original test/ash_a2a/chicago/sa2a_v26_9_17_reachability_analysis_test.exs ---
defmodule AshA2A.Chicago.SA2AV269_17ReachabilityAnalysisTest do
  @moduledoc """
  Qualifies the real `native/hddl_cli/target/release/hddl_analyze` binary --
  an additive diagnostic sibling to `hddl_cli` (`native/hddl_cli/src/bin/
  hddl_analyze.rs`) that reuses the SAME real `ferroplan_hddl` parser/
  grounder/translator the solving path already depends on (no
  reimplementation of parsing, grounding, or FOND solving) and adds one
  thing the solver's own solved/NoPlan verdict does not expose: exhaustive
  forward-reachability + terminal-state classification over the ground
  action/method graph `translate()` already computes internally.

  ## Why this exists

  `test/ash_a2a/chicago/sa2a_v26_9_17_fond_qualification_test.exs` already
  established, via the real solver, that the committed
  `test/support/hddl/sa2a_v26_9_17_dogfood/{domain,problem}.hddl` fixture
  reports real `NoPlan` -- and that a prior reconciliation pass (see that
  test's own moduledoc) gave every genuinely-repairable `oneof` dead-end a
  real recovery method while deliberately leaving true invariant-driven
  terminals (receipt-reconcile-blocked's "NEVER replay automatically",
  among others) unrepaired. That prior finding rested on *sampled* isolated
  ablations (construct a minimal sub-domain, run the real solver, observe
  NoPlan-vs-solved) -- real evidence, but not an exhaustive one: it could
  not rule out some OTHER, unnoticed uncovered branch also contributing to
  the NoPlan result.

  This test closes that gap with an *exhaustive* real measurement instead
  of a sampled one, mirroring (independently, in ash_a2a's own real Rust/
  ferroplan toolchain rather than a hand-rolled reimplementation) the same
  rigor upgrade a concurrent session's real work in `autofde-lab` applied to
  the sibling Python-side grounding of this same v26.9.17 domain: full
  ground-state enumeration, terminal-state classification against every
  disclosed "terminal-by-design" predicate, and confirmation of whether the
  stated `:goal` is reachable at all under *some* favorable sequence of
  non-deterministic outcomes (a "weak"/best-case path), even though no
  *strong-cyclic* (every-outcome-covered) policy exists.

  ## The real, measured result this test asserts (as of the committed
  fixture; re-run for real, not copied from a prior session)

      212 total ground states, all 212 reachable from :init
      239 ground transitions
      30 real terminal (dead-end, no outgoing transition) states
      0 of those 30 are unexplained by a known, disclosed terminal predicate
      2 of the 212 reachable states DO satisfy the full stated :goal

  Every one of the 30 terminals is attributable to exactly one of the
  domain's own disclosed dead-end predicates (unsupported, receipt-
  reconcile-blocked, verification-failed, process-nonconformant, candidate-
  refused, equivalence-failed, authority-refused [episode 2's un-repaired
  occurrence], actuation-failed [episode 2's un-repaired occurrence],
  candidate-unsupported) -- zero left unexplained. That is the exhaustive,
  not sampled, confirmation that the domain's real NoPlan verdict has no
  hidden, unaccounted-for cause: every real dead end traces to a predicate
  already named and disclosed as deliberately unrepaired.

  The 2 real goal-satisfying reachable states (their real ids are asserted
  below, not hand-picked) are the quantified, cited version of "the goal
  IS reachable given favorable nondeterminism, even though no total
  strong-cyclic guarantee exists" -- the same shape of finding the RFC's own
  Chicago-court discipline asks for: a real distinction between "provably
  impossible" and "provably not unconditionally guaranteed," never
  collapsed into a single undifferentiated NoPlan.

  Shells out to the real `native/hddl_cli/target/release/hddl_analyze`
  binary via `System.cmd/2` (a real OS subprocess, zero Mock/mox/patch/
  monkeypatch) and asserts on the real decoded JSON it produces, mirroring
  every other qualification test in this directory's own conventions.
  """

  use ExUnit.Case, async: true

  @cli_path Path.expand("../../../native/hddl_cli/target/release/hddl_analyze", __DIR__)

  @domain Path.expand("../../support/hddl/sa2a_v26_9_17_dogfood/domain.hddl", __DIR__)
  @problem Path.expand("../../support/hddl/sa2a_v26_9_17_dogfood/problem.hddl", __DIR__)

  @markers Enum.join(
             [
               "unsupported",
               "receipt-reconcile-blocked",
               "manufacture-failed",
               "authority-refused",
               "actuation-failed",
               "verification-failed",
               "process-nonconformant",
               "candidate-refused",
               "candidate-blocked",
               "candidate-unsupported",
               "equivalence-failed",
               "allocation-blocked",
               "build-broken",
               "blocked"
             ],
             ","
           )

  setup_all do
    unless File.exists?(@cli_path) do
      flunk("""
      hddl_analyze binary not built at #{@cli_path}.
      Run: cd #{Path.expand("../../../native/hddl_cli", __DIR__)} && cargo build --release
      """)
    end

    :ok
  end

  test "real exhaustive reachability: every terminal state is explained, and the goal is really reachable" do
    {stdout, exit_code} = System.cmd(@cli_path, [@domain, @problem, @markers])
    assert exit_code == 0, "hddl_analyze exited #{exit_code}: #{stdout}"

    decoded =
      case JSON.decode(stdout) do
        {:ok, decoded} ->
          decoded

        {:error, reason} ->
          flunk("hddl_analyze produced non-JSON stdout: #{inspect(reason)}: #{stdout}")
      end

    refute Map.has_key?(decoded, "error"),
           "hddl_analyze reported an error: #{inspect(decoded["error"])}"

    # Full ground-state graph: all 212 ground states are reachable from
    # :init (no dead code baked into the domain by construction).
    assert decoded["total_ground_states"] == 212
    assert decoded["reachable_state_count"] == 212
    assert decoded["total_transitions"] == 239

    # Exhaustive terminal classification: real, not sampled.
    assert decoded["terminal_state_count"] == 30
    assert decoded["unexplained_terminal_count"] == 0
    assert decoded["explained_terminal_count"] == 30
    assert decoded["unexplained_terminals"] == []

    # The full stated :goal IS reachable given favorable nondeterminism --
    # a real, cited "weak"/best-case path exists -- even though the
    # sibling fond_qualification_test's real solver run reports NoPlan for
    # a total strong-cyclic guarantee. Both are real and both are true;
    # they answer different questions.
    assert decoded["goal_reachable"] == true
    assert decoded["goal_satisfying_reachable_count"] == 2
    goal_state_ids = decoded["goal_states"] |> Enum.map(& &1["state_id"]) |> Enum.sort()
    assert goal_state_ids == ["s204", "s211"]
  end

  test "every disclosed terminal-by-design predicate is actually exercised by at least one real terminal state" do
    {stdout, 0} = System.cmd(@cli_path, [@domain, @problem, @markers])
    {:ok, decoded} = JSON.decode(stdout)

    matched_markers =
      decoded["explained_terminals"]
      |> Enum.flat_map(& &1["matched_markers"])
      |> MapSet.new()

    # Every predicate the domain's own comments name as deliberately
    # terminal-by-design is confirmed, by this real measurement, to
    # actually be reachable and actually dead-end -- not merely declared
    # in prose but never structurally reachable.
    for predicate <- ~w(unsupported receipt-reconcile-blocked verification-failed
                         process-nonconformant candidate-refused equivalence-failed
                         authority-refused actuation-failed candidate-unsupported) do
      assert predicate in matched_markers,
             "expected disclosed terminal predicate #{predicate} to be exercised by a real reachable terminal state, but it was not observed"
    end

    # The repo-boundary `blocked` predicate and `manufacture-failed` are
    # NOT expected to appear as terminals: both were given real repair
    # methods in the reconciliation pass, so a state carrying either fact
    # should always have an outgoing transition (never a dead end).
    refute "blocked" in matched_markers
    refute "manufacture-failed" in matched_markers
    refute "build-broken" in matched_markers
    refute "allocation-blocked" in matched_markers
    refute "candidate-blocked" in matched_markers
  end
end

# --- SECTION 14: Original test/ash_a2a/chicago/sa2a_v26_9_17_source_fidelity_test.exs ---
defmodule AshA2A.Chicago.SA2AV269_17SourceFidelityTest do
  @moduledoc """
  Mechanically cross-checks the committed, reconciled
  `test/support/hddl/sa2a_v26_9_17_dogfood/domain.hddl` against the user's
  own original, byte-for-byte verbatim pasted HDDL/FOND write-up preserved
  in the sibling `test/support/hddl/sa2a_v26_9_17_dogfood/SOURCE.md`.

  ## What this test is, and is not

  This is a real, mechanical parse-and-compare over two real files on
  disk -- simple string/regex processing, zero Mock/mox/patch/monkeypatch,
  zero fuzzy/semantic judgement. It does NOT re-verify the domain solves
  or grounds (that is `sa2a_v26_9_17_fond_qualification_test.exs`'s job)
  and does NOT re-verify exhaustive reachability (that is
  `sa2a_v26_9_17_reachability_analysis_test.exs`'s job). Its only claim:
  for every `:action` whose exact `(:action <name>` header line still
  appears verbatim in the committed `domain.hddl`, that action's `oneof`
  outcome set (the alternative effect branches a non-deterministic action
  can produce) is IDENTICAL -- same outcome predicates, same set,
  comment text stripped from both sides first -- between the original
  pasted text and the committed fixture.

  ## Why this matters

  `domain.hddl`'s own comments already disclose real edits made on top of
  the original pasted domain: 6 mirrored Episode-2 actions
  (`admit-authority-replay`, `dispatch-replay-command`,
  `execute-replay-command`, `close-replay-receipt`, `verify-replay`,
  `observe-replay-process` -- entirely new, never in the original text),
  one disclosed rename (`admit-candidate`'s own primitive body renamed to
  `attempt-admit-candidate`, wrapped in a new task of the same name), and
  a disclosed grounding-gap reconciliation (`classify-episode` wrapping
  the two originally-declared-but-mis-wired actions `classify-problem` /
  `observe-classification`, reusing both unchanged). None of those are
  fidelity violations -- they are named, comment-disclosed, additive
  changes. What this test guards against is the OTHER, un-disclosed
  failure mode: an action kept under its exact original name silently
  having an outcome predicate added, removed, or swapped in its `oneof`
  effect, with no comment marking the change. `disclosed rename` and
  `disclosed addition` are excluded by construction (the renamed action's
  old header no longer matches; the new actions have no original-source
  counterpart to compare against at all) -- both are asserted explicitly
  in dedicated tests below, so this suite does not just skip them
  silently.

  ## Source of the original text

  `SOURCE.md` was recovered by grepping this session's own JSONL
  transcript for the real user turn, and reproduces it byte-for-byte
  (see `SOURCE.md`'s own header for the full recovery note and the one
  stripped `ultracode ` command-invocation prefix).
  """

  use ExUnit.Case, async: true

  @source_md Path.expand("../../support/hddl/sa2a_v26_9_17_dogfood/SOURCE.md", __DIR__)
  @domain_hddl Path.expand("../../support/hddl/sa2a_v26_9_17_dogfood/domain.hddl", __DIR__)

  @begin_marker "<!-- BEGIN VERBATIM SOURCE -->\n"
  @end_marker "\n<!-- END VERBATIM SOURCE -->\n"
  @problem_heading "sa2a-v26.9.17-problem.hddl"

  # The one disclosed rename: the original pasted domain's primitive
  # action `admit-candidate` was renamed to `attempt-admit-candidate`
  # (body unchanged) and `admit-candidate` became a wrapping :task of the
  # same name instead -- so its old `(:action admit-candidate` header no
  # longer appears verbatim in domain.hddl, and this suite must not
  # silently treat that absence as "nothing to check" without also
  # confirming the disclosed replacement is real.
  @disclosed_renamed_action "admit-candidate"
  @disclosed_renamed_replacement "attempt-admit-candidate"

  # The 6 disclosed, wholly-new Episode-2 mirror actions -- present only
  # in the committed domain.hddl, absent from the original pasted text.
  @disclosed_new_actions ~w(
    admit-authority-replay
    dispatch-replay-command
    execute-replay-command
    close-replay-receipt
    verify-replay
    observe-replay-process
  )

  setup_all do
    for path <- [@source_md, @domain_hddl] do
      unless File.exists?(path) do
        flunk("required fixture missing: #{path}")
      end
    end

    :ok
  end

  test "SOURCE.md's verbatim block is present, delimited, and starts where the recovery note says it does" do
    source_md = File.read!(@source_md)

    assert String.contains?(source_md, @begin_marker),
           "SOURCE.md is missing its <!-- BEGIN VERBATIM SOURCE --> delimiter"

    assert String.contains?(source_md, @end_marker),
           "SOURCE.md is missing its <!-- END VERBATIM SOURCE --> delimiter"

    verbatim = extract_verbatim(source_md)

    assert String.starts_with?(verbatim, "The clean representation is"),
           "verbatim block does not start with the expected recovered text"

    assert String.ends_with?(
             verbatim,
             "That is the FOND/HDDL form of the self-reinforcing SA2A loop.\n"
           )

    # A real paste, not an accidentally-truncated stub.
    assert byte_size(verbatim) > 20_000
  end

  test "every original :action header still present verbatim in domain.hddl has an IDENTICAL oneof outcome set" do
    source_md = File.read!(@source_md)
    domain_text = File.read!(@domain_hddl)

    verbatim = extract_verbatim(source_md)
    source_domain_text = extract_domain_lisp_fences(verbatim)

    source_actions = extract_actions(strip_comments(source_domain_text))
    committed_actions = extract_actions(strip_comments(domain_text))

    assert map_size(source_actions) > 0, "found zero :action blocks in the recovered source text"

    assert map_size(committed_actions) > 0,
           "found zero :action blocks in the committed domain.hddl"

    {checked, violations} =
      Enum.reduce(source_actions, {[], []}, fn {name, src_block}, {checked_acc, viol_acc} ->
        if action_header_present?(domain_text, name) do
          committed_block = Map.fetch!(committed_actions, name)
          src_oneof = extract_oneof_outcomes(src_block)
          committed_oneof = extract_oneof_outcomes(committed_block)

          checked_acc = [name | checked_acc]

          if src_oneof == committed_oneof do
            {checked_acc, viol_acc}
          else
            violation = %{
              action: name,
              source_oneof: src_oneof,
              committed_oneof: committed_oneof
            }

            {checked_acc, [violation | viol_acc]}
          end
        else
          {checked_acc, viol_acc}
        end
      end)

    # Sanity floor: this must be a real, nontrivial mechanical check, not
    # a vacuous pass because a bug in the extraction found nothing to
    # compare. The original pasted domain declares 27 actions; all but
    # the one disclosed rename (admit-candidate) keep their exact header.
    assert length(checked) >= 20,
           "expected at least 20 original actions to still be verbatim-headered " <>
             "in domain.hddl, found #{length(checked)}: #{inspect(Enum.sort(checked))}"

    assert violations == [],
           "fidelity violation(s): an action's original oneof outcome set was " <>
             "silently narrowed, widened, or altered with no disclosure comment: " <>
             inspect(Enum.reverse(violations), pretty: true, limit: :infinity)
  end

  test "the disclosed rename (admit-candidate -> attempt-admit-candidate) is real, and correctly excluded rather than silently passed" do
    domain_text = File.read!(@domain_hddl)

    refute action_header_present?(domain_text, @disclosed_renamed_action),
           "admit-candidate is expected to no longer be declared as an :action " <>
             "in domain.hddl (it became a :task) -- if this now fails, the " <>
             "domain changed and the disclosed-rename exclusion above needs " <>
             "re-auditing, not silent removal"

    assert action_header_present?(domain_text, @disclosed_renamed_replacement),
           "expected the disclosed replacement action attempt-admit-candidate " <>
             "to be declared in domain.hddl"
  end

  test "the 6 mirrored Episode-2 actions are real domain.hddl-only additions, absent from the original pasted source" do
    source_md = File.read!(@source_md)
    domain_text = File.read!(@domain_hddl)

    verbatim = extract_verbatim(source_md)
    source_domain_text = extract_domain_lisp_fences(verbatim)
    source_actions = extract_actions(strip_comments(source_domain_text))

    for name <- @disclosed_new_actions do
      refute Map.has_key?(source_actions, name),
             "#{name} unexpectedly found in the original pasted source -- it " <>
               "is supposed to be a disclosed, domain.hddl-only addition"

      assert action_header_present?(domain_text, name),
             "expected disclosed new action #{name} to be declared in domain.hddl"
    end
  end

  # -- helpers --------------------------------------------------------------

  defp extract_verbatim(source_md) do
    [_before, rest] = String.split(source_md, @begin_marker, parts: 2)
    [verbatim, _after] = String.split(rest, @end_marker, parts: 2)
    verbatim
  end

  # Concatenates every ```lisp fenced code block that appears before the
  # problem.hddl heading in the verbatim text -- the original pasted
  # message interleaves prose section headers between successive lisp
  # fences that together make up the full original domain.hddl (the
  # single large problem.hddl fence comes after that heading and is out
  # of scope for this action-level domain check).
  defp extract_domain_lisp_fences(verbatim) do
    domain_region =
      case :binary.match(verbatim, @problem_heading) do
        {idx, _len} -> binary_part(verbatim, 0, idx)
        :nomatch -> verbatim
      end

    ~r/```lisp\n(.*?)\n```/s
    |> Regex.scan(domain_region, capture: :all_but_first)
    |> Enum.map_join("\n", fn [block] -> block end)
  end

  defp strip_comments(text) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", &Regex.replace(~r/;;.*/, &1, ""))
  end

  defp extract_actions(text) do
    ~r/\(:action\s+([\w-]+)/
    |> Regex.scan(text, return: :index)
    |> Enum.reduce(%{}, fn [{start, _len}, {name_start, name_len}], acc ->
      name = binary_part(text, name_start, name_len)
      block = extract_balanced_block(text, start)
      Map.put(acc, name, block)
    end)
  end

  defp extract_balanced_block(text, start), do: do_extract_balanced(text, start, 0, start)

  defp do_extract_balanced(text, pos, depth, start) when pos < byte_size(text) do
    case binary_part(text, pos, 1) do
      "(" ->
        do_extract_balanced(text, pos + 1, depth + 1, start)

      ")" ->
        case depth - 1 do
          0 -> binary_part(text, start, pos - start + 1)
          new_depth -> do_extract_balanced(text, pos + 1, new_depth, start)
        end

      _ ->
        do_extract_balanced(text, pos + 1, depth, start)
    end
  end

  defp do_extract_balanced(_text, _pos, _depth, _start), do: nil

  defp extract_oneof_outcomes(nil), do: nil

  defp extract_oneof_outcomes(block) do
    case :binary.match(block, "(oneof") do
      :nomatch ->
        nil

      {idx, len} ->
        oneof_end = find_matching_close(block, idx)
        body = binary_part(block, idx + len, oneof_end - (idx + len))

        body
        |> split_top_level_alternatives()
        |> Enum.map(&normalize_whitespace/1)
        |> Enum.sort()
    end
  end

  defp find_matching_close(text, open_idx), do: do_find_matching_close(text, open_idx, 0)

  defp do_find_matching_close(text, pos, depth) when pos < byte_size(text) do
    case binary_part(text, pos, 1) do
      "(" ->
        do_find_matching_close(text, pos + 1, depth + 1)

      ")" ->
        case depth - 1 do
          0 -> pos
          new_depth -> do_find_matching_close(text, pos + 1, new_depth)
        end

      _ ->
        do_find_matching_close(text, pos + 1, depth)
    end
  end

  defp split_top_level_alternatives(body), do: do_split(body, 0, 0, nil, [])

  defp do_split(body, pos, depth, start, acc) when pos < byte_size(body) do
    case binary_part(body, pos, 1) do
      "(" ->
        new_start = if depth == 0, do: pos, else: start
        do_split(body, pos + 1, depth + 1, new_start, acc)

      ")" ->
        case depth - 1 do
          0 ->
            alt = binary_part(body, start, pos - start + 1)
            do_split(body, pos + 1, 0, nil, [alt | acc])

          new_depth ->
            do_split(body, pos + 1, new_depth, start, acc)
        end

      _ ->
        do_split(body, pos + 1, depth, start, acc)
    end
  end

  defp do_split(_body, _pos, _depth, _start, acc), do: Enum.reverse(acc)

  defp normalize_whitespace(s) do
    s
    |> String.split()
    |> Enum.join(" ")
  end

  defp action_header_present?(domain_text, name) do
    escaped = Regex.escape(name)
    Regex.match?(~r/\(:action\s+#{escaped}(?=[\s)])/, domain_text)
  end
end

# --- SECTION 15: Original test/ash_a2a/chicago/sa2a_v26_9_17_topology_test.exs ---
defmodule AshA2A.Chicago.SA2AV269_17TopologyTest do
  @moduledoc """
  Qualifies `AshA2A.Chicago.Courts.SA2AV269_17Topology` Chicago style: the real
  `AshA2A.Chicago.Runner`, real `git rev-parse`/`git status` subprocesses over
  the 11 real local sibling repositories the v26.9.17
  `test/support/hddl/sa2a_v26_9_17_dogfood/problem.hddl` names as HDDL
  `:objects`, real telemetry, and a verdict read back by the independent OCEL
  consumer from the durable artifact on disk -- zero mocks anywhere.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  alias AshA2A.Chicago.Courts.SA2AV269_17Topology, as: Topology
  alias AshA2A.Chicago.{Query, Runner}

  @moduletag :tmp_dir

  describe "AshA2A.Chicago.courts/0 discovers this court" do
    test "the topology court is compiled into :ash_a2a and discoverable, not registered" do
      assert Topology in AshA2A.Chicago.courts()
      assert Topology.id() == "SA2A-TOPO"
      assert Topology.gate() == nil
      assert Topology.profile() == :core
    end
  end

  describe "the 11 real local repos this domain's :init declares as HDDL objects" do
    @tag :sibling_repos
    # ASH_A2A-26922-04: `mix test.all` = `test --include serial`, and this
    # module's `@moduletag :serial` rescues these `:sibling_repos` tests from
    # test_helper.exs's named `:sibling_repos` exclusion (ExUnit include
    # overrides ALL exclusions for a matching test) -- so on a hosted runner
    # they ran, found no /Users/sac sibling checkouts, and failed. Same class
    # as ASH_A2A-26922-02: a compile-time precondition check with a named,
    # printed reason, matching the repo's real skip convention.
    @tag skip:
           (Enum.any?(
              Enum.map(Topology.repos(), &Topology.repo_path(elem(&1, 1))),
              &(!File.exists?(Path.join(&1, ".git")))
            ) &&
              "sibling repo topology absent on this machine -- the 11 real checkouts are author-workstation-local") ||
             nil
    test "every one resolves to a real git HEAD via check_repo/1, on this machine" do
      results =
        for {obj, dir, _cap, _critical?} <- Topology.repos() do
          path = Topology.repo_path(dir)
          status = Topology.check_repo(path)

          case status do
            %{real?: true, head: head} ->
              assert Regex.match?(~r/\A[0-9a-f]{40}([0-9a-f]{24})?\z/, head),
                     "#{obj} (#{path}): reported real but head #{inspect(head)} is not a real object id"

            %{real?: false} ->
              # Report, never fail hard: this repo may genuinely not exist on
              # a different machine. On THIS machine (2026-09-17 session)
              # every one of the 11 is confirmed present -- the hard assertion
              # below is what actually enforces that, not this branch.
              IO.puts(
                "SA2A-TOPO: #{obj} (#{path}) has no real git HEAD on this machine -- reported, not failed"
              )
          end

          {obj, status.real?}
        end

      real_count = Enum.count(results, fn {_obj, real?} -> real? end)

      assert real_count == 11,
             "expected all 11 repos real on this machine, got #{real_count}: #{inspect(results)}"

      assert length(Topology.repos()) == 11
    end

    test "9 pairs are critical, 2 (unrdf/cap-runtime, wasm4pm/cap-portable-runtime) are not" do
      {critical, non_critical} = Enum.split_with(Topology.repos(), fn {_, _, _, c?} -> c? end)

      assert length(critical) == 9
      assert length(non_critical) == 2

      assert Enum.map(non_critical, fn {obj, _dir, cap, _c?} -> {obj, cap} end)
             |> Enum.sort() ==
               Enum.sort([
                 {"unrdf", "cap-runtime"},
                 {"wasm4pm", "cap-portable-runtime"}
               ])
    end

    test "check_repo/1 never raises for a path that does not exist" do
      missing =
        Path.join(
          System.tmp_dir!(),
          "sa2a-topo-does-not-exist-#{System.unique_integer([:positive])}"
        )

      assert %{real?: false, head: nil, dirty?: nil} = Topology.check_repo(missing)
    end
  end

  describe "SA2A-TOPO court end to end through the runner" do
    @tag :sibling_repos
    # ASH_A2A-26922-04: `mix test.all` = `test --include serial`, and this
    # module's `@moduletag :serial` rescues these `:sibling_repos` tests from
    # test_helper.exs's named `:sibling_repos` exclusion (ExUnit include
    # overrides ALL exclusions for a matching test) -- so on a hosted runner
    # they ran, found no /Users/sac sibling checkouts, and failed. Same class
    # as ASH_A2A-26922-02: a compile-time precondition check with a named,
    # printed reason, matching the repo's real skip convention.
    @tag skip:
           (Enum.any?(
              Enum.map(Topology.repos(), &Topology.repo_path(elem(&1, 1))),
              &(!File.exists?(Path.join(&1, ".git")))
            ) &&
              "sibling repo topology absent on this machine -- the 11 real checkouts are author-workstation-local") ||
             nil
    test "every falsifier reaches its verdict and every pass is OCEL-corroborated", %{
      tmp_dir: dir
    } do
      assert {:ok, run} = Runner.run(courts: [Topology], profile: :core, evidence_dir: dir)

      by_id = Map.new(run.results, &{&1.falsifier_id, &1})

      assert Map.keys(by_id) |> Enum.sort() == [
               "SA2A-TOPO-001",
               "SA2A-TOPO-002",
               "SA2A-TOPO-003"
             ]

      expected = %{
        "SA2A-TOPO-001" => :measured,
        "SA2A-TOPO-002" => :positive_control_passed,
        "SA2A-TOPO-003" => :falsifier_killed
      }

      for {id, verdict} <- expected do
        result = by_id[id]

        assert result.verdict == verdict,
               "#{id}: #{inspect(result.verdict)} -- #{result.detail} -- #{result.ocel_detail}"

        assert result.attempt_observed? == true, id
        assert result.ocel_corroborated? == true, "#{id}: #{result.ocel_detail}"
      end

      assert run.ocel.dropped == 0

      measurements = by_id["SA2A-TOPO-001"].measurements
      assert map_size(measurements) == 11

      for {obj, m} <- measurements do
        assert m["real"] == true, "#{obj}: #{inspect(m)}"
      end

      critical_pairs = by_id["SA2A-TOPO-002"].evidence["critical_pairs"]
      assert map_size(critical_pairs) == 9

      # The independent consumer re-derives the key facts from disk alone,
      # never from the observer's in-memory records or this court's structs.
      {:ok, index} = Query.load(Path.join(dir, "ocel.json"), run.ocel.sha256)

      assert {true, _} =
               Query.eval(
                 index,
                 "SA2A-TOPO-002",
                 {:not_observed, "chicago.topology.repo_checked", %{"real" => "false"}}
               )

      assert {true, _} =
               Query.eval(
                 index,
                 "SA2A-TOPO-003",
                 {:not_observed, "chicago.topology.repo_checked",
                  %{"repo" => "sa2a-topo-003-synthetic", "real" => "true"}}
               )

      assert {true, _} =
               Query.eval(
                 index,
                 "SA2A-TOPO-003",
                 {:observed, "chicago.topology.repo_checked",
                  %{"repo" => "sa2a-topo-003-synthetic", "real" => "false"}}
               )
    end
  end
end

# --- SECTION 16: Original test/ash_a2a/chicago/shex_shacl_admission_test.exs ---
defmodule AshA2A.Chicago.ShexShaclAdmissionTest do
  @moduledoc """
  Gate 2 / admission pipeline / ShEx / SHACL courts (RFC-SA2A-002 §33, §44,
  §45, §46) run end to end through the real `AshA2A.Chicago.Runner`: the real
  `AshA2A.Semantic.AdmissionPipeline`, the real `praxis-graphlaw` wasm, the
  real term and mapping registries, the real observer, and the durable OCEL
  artifact read back by the independent consumer. No mocks, no stubs.

  `async: false` -- the observer attributes every telemetry event between a
  stimulus start and stop to that falsifier.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  alias AshA2A.Chicago
  alias AshA2A.Chicago.{Query, Runner}
  alias AshA2A.Chicago.Courts.{ExecutableWorld, Shacl, Shex}
  alias AshA2A.Chicago.Fixtures.ShexShaclAdmission, as: World
  alias AshA2A.Chicago.Fixtures.ShexShaclAdmission.Evidence

  alias AshA2A.Semantic.{
    AdmissionPipeline,
    LawDocument,
    MappingRegistry,
    ShaclSeverity,
    TermRegistry
  }

  alias AshA2A.Semantic.AdmissionRefusal

  @moduletag :tmp_dir

  doctest AshA2A.Semantic.ShaclSeverity

  # Engine-backed cases are a NAMED, visible skip where the real wasm is absent
  # -- never a substituted engine.
  @engine_unavailable (case AshA2A.GraphLaw.Wasm.availability() do
                         :ok -> nil
                         {:error, detail} -> "real GraphLaw wasm unavailable: #{inspect(detail)}"
                       end)

  # Observed on the real SUT at this revision. CHI-ADM-005/006/008 survived at
  # 46e522f (meta-admission absent; named receipt accepted) and are killed by
  # the law-standing and held-receipt repairs -- the falsifiers are unchanged.
  @expected %{
    "CHI-ADM-001" => :falsifier_killed,
    "CHI-ADM-002" => :falsifier_killed,
    "CHI-ADM-003" => :falsifier_killed,
    "CHI-ADM-004" => :falsifier_killed,
    "CHI-ADM-005" => :falsifier_killed,
    "CHI-ADM-006" => :falsifier_killed,
    "CHI-ADM-007" => :falsifier_killed,
    "CHI-ADM-008" => :falsifier_killed,
    "CHI-ADM-009" => :falsifier_killed,
    "CHI-ADM-010" => :falsifier_killed,
    "CHI-ADM-011" => :positive_control_passed,
    "CHI-ADM-012" => :positive_control_passed,
    "CHI-ADM-013" => :positive_control_passed,
    "CHI-ADM-014" => :falsifier_killed,
    "SA2A-SHEX-001" => :falsifier_killed,
    "SA2A-SHEX-002" => :falsifier_killed,
    "SA2A-SHEX-003" => :falsifier_killed,
    "SA2A-SHEX-004" => :falsifier_killed,
    "SA2A-SHEX-005" => :falsifier_killed,
    "SA2A-SHEX-006" => :positive_control_passed,
    "SA2A-SHEX-007" => :positive_control_passed,
    "SA2A-SHACL-001" => :falsifier_killed,
    "SA2A-SHACL-002" => :falsifier_killed,
    "SA2A-SHACL-003" => :falsifier_killed,
    "SA2A-SHACL-004" => :falsifier_killed,
    "SA2A-SHACL-005" => :falsifier_killed,
    "SA2A-SHACL-006" => :falsifier_killed,
    "SA2A-SHACL-007" => :falsifier_killed,
    "SA2A-SHACL-008" => :positive_control_passed,
    "SA2A-SHACL-009" => :positive_control_passed
  }

  describe "end to end over the real runner" do
    @tag :graphlaw
    if @engine_unavailable, do: @tag(skip: @engine_unavailable)

    test "every falsifier reaches its observed verdict and every verdict is OCEL-corroborated",
         %{tmp_dir: dir} do
      assert {:ok, run} =
               Runner.run(
                 courts: [ExecutableWorld, Shex, Shacl],
                 profile: :core,
                 evidence_dir: dir
               )

      verdicts = Map.new(run.results, &{&1.falsifier_id, &1.verdict})
      assert verdicts == @expected

      for result <- run.results do
        assert result.ocel_corroborated? == true,
               "#{result.falsifier_id} #{result.verdict}: #{result.ocel_detail} / #{result.detail}"

        assert result.attempt_observed? == true, result.falsifier_id
      end

      by_id = Map.new(run.results, &{&1.falsifier_id, &1})

      # Canonical state, read independently, is unchanged by every refusal.
      for id <- ~w(SA2A-SHEX-001 SA2A-SHACL-001 CHI-ADM-002 CHI-ADM-009) do
        assert by_id[id].evidence["canonical_unchanged"] == true, id
        assert by_id[id].evidence["canonical_after"]["engine_scratch_entries"] == 0, id
      end

      assert by_id["CHI-ADM-010"].evidence["canonical_before"] ==
               by_id["CHI-ADM-010"].evidence["canonical_after"]

      # The laundering attempts are refused by law standing, at the stage whose
      # law lacked it -- not by an unrelated stage.
      assert by_id["CHI-ADM-005"].evidence["outcome"] == "refused"

      assert by_id["CHI-ADM-005"].evidence["refusal"] =~
               "stage=rule_closure code=law_without_standing"

      assert by_id["CHI-ADM-006"].evidence["outcome"] == "refused"
      assert by_id["CHI-ADM-006"].evidence["refusal"] =~ "stage=shacl code=law_without_standing"
      assert by_id["CHI-ADM-008"].evidence["reply"] =~ "semantic_mapping_receipt_not_held"

      receipt = JSON.decode!(File.read!(Path.join(dir, "standing_receipt.json")))
      refute receipt["standing"] in ["NONCONFORMANT", "CONFORMANT"]
      assert receipt["results"]["survived_ids"] == []
      assert receipt["results"]["falsifiers_killed"] == 23
      assert receipt["results"]["positive_controls_passed"] == 7
      assert receipt["results"]["unresolved_ids"] == []
      assert run.ocel.dropped == 0
    end

    @tag :graphlaw
    if @engine_unavailable, do: @tag(skip: @engine_unavailable)

    test "the independent consumer reads the ShEx/SHACL split and the admitted control from disk",
         %{tmp_dir: dir} do
      {:ok, run} = Runner.run(courts: [Shex], profile: :core, evidence_dir: dir)
      assert {:ok, index} = Query.load(Path.join(dir, "ocel.json"), run.ocel.sha256)

      assert {true, _} = Query.eval(index, "SA2A-SHEX-006", Evidence.stage(:shex, :ok))
      assert {true, _} = Query.eval(index, "SA2A-SHEX-006", Evidence.stage(:shacl, :refused))
      assert {false, _} = Query.eval(index, "SA2A-SHEX-003", Evidence.stage(:shacl))
      assert {true, _} = Query.eval(index, "SA2A-SHEX-007", Evidence.admitted())

      assert {true, _} =
               Query.eval(
                 index,
                 "SA2A-SHEX-007",
                 {:precedes, "admission.start", "admission.stop"}
               )
    end
  end

  describe "engine unavailable (environment fault injection)" do
    test "pipeline falsifiers are blocked with the measured reason, never killed", %{tmp_dir: dir} do
      previous = Application.get_env(:ash_a2a, :graphlaw_wasm_path)
      Application.put_env(:ash_a2a, :graphlaw_wasm_path, Path.join(dir, "absent.wasm"))

      try do
        {:ok, run} =
          Runner.run(courts: [Shex, ExecutableWorld], profile: :core, evidence_dir: dir)

        by_id = Map.new(run.results, &{&1.falsifier_id, &1})

        for {id, result} <- by_id, String.starts_with?(id, "SA2A-SHEX") do
          assert result.verdict == :blocked, id
          assert result.detail =~ "graphlaw_wasm_not_found"
        end

        for id <-
              ~w(CHI-ADM-002 CHI-ADM-003 CHI-ADM-004 CHI-ADM-005 CHI-ADM-006 CHI-ADM-009 CHI-ADM-010 CHI-ADM-011) do
          assert by_id[id].verdict == :blocked, id
        end

        # Boundaries that do not need the engine still ran for real.
        assert by_id["CHI-ADM-001"].verdict == :falsifier_killed
        assert by_id["CHI-ADM-001"].ocel_corroborated? == true
        assert by_id["CHI-ADM-013"].verdict == :positive_control_passed
      after
        if previous,
          do: Application.put_env(:ash_a2a, :graphlaw_wasm_path, previous),
          else: Application.delete_env(:ash_a2a, :graphlaw_wasm_path)
      end
    end
  end

  describe "court declarations" do
    test "the three courts are discoverable core courts with fully declared falsifiers" do
      for court <- [ExecutableWorld, Shex, Shacl] do
        assert court in Chicago.courts()
        assert court.gate() == 2
        assert court.profile() == :core

        for f <- court.falsifiers() do
          assert String.starts_with?(f.id, court.id() <> "-")
          assert f.attempt_predicate != nil and f.outcome_predicate != nil, f.id
        end
      end

      assert length(ExecutableWorld.falsifiers()) == 14
      assert length(Shex.falsifiers()) == 7
      assert length(Shacl.falsifiers()) == 9
    end

    test "the world law is non-vacuous under the pipeline's own obligation counts" do
      assert {:ok, 7} = LawDocument.shacl_shape_count(World.shacl_shapes())
      assert {:ok, 2} = LawDocument.shex_shape_count(World.shex_schema())
      assert {:ok, 1} = LawDocument.shex_shape_map_count(World.shex_shape_map())
      assert {:ok, 2} = LawDocument.owl_axiom_count(World.profile())
      assert LawDocument.n3_rule_count(World.falsifiers()) == 1
      assert {:ok, _graph} = LawDocument.turtle_graph(World.world_graph())
    end
  end

  describe "AshA2A.Semantic.ShaclSeverity" do
    test "Violation-only law needs no partition" do
      shapes = World.shacl_shapes() |> String.replace("sh:severity sh:Warning ;", "")
      assert {:ok, :no_non_violation_shapes} = ShaclSeverity.violations_only(shapes)
    end

    test "removes exactly the sh:Warning shape and keeps every Violation shape" do
      assert {:ok, %{violations_only: law, removed: 1}} =
               ShaclSeverity.violations_only(World.shacl_shapes())

      assert {:ok, graph} = LawDocument.turtle_graph(law)
      refute law =~ "Warning"
      refute law =~ "rdfs:comment"
      assert {:ok, 7} = LawDocument.shacl_shape_count(law)

      severities =
        for {_s, p, o} <- RDF.Graph.triples(graph),
            to_string(p) == "http://www.w3.org/ns/shacl#severity",
            do: to_string(o)

      assert severities == ["http://www.w3.org/ns/shacl#Violation"]
    end

    test "refuses a partition that would change a Violation shape's meaning" do
      prefix = "@prefix sh: <http://www.w3.org/ns/shacl#> . @prefix ex: <http://e.org/> .\n"

      referenced = """
      ex:V a sh:NodeShape ; sh:targetClass ex:C ; sh:node ex:W .
      ex:W a sh:NodeShape ; sh:severity sh:Warning ; sh:property [ sh:path ex:p ; sh:minCount 1 ] .
      """

      assert {:error, %{code: :shacl_severity_not_partitionable}} =
               ShaclSeverity.violations_only(prefix <> referenced)

      nested = """
      ex:W a sh:NodeShape ; sh:targetClass ex:C ; sh:severity sh:Warning ;
        sh:property [ sh:path ex:p ; sh:minCount 1 ] .
      """

      assert {:error, %{code: :shacl_severity_not_partitionable, reason: :carries_nested_shapes}} =
               ShaclSeverity.violations_only(prefix <> nested)

      closed = """
      ex:S a sh:NodeShape ; sh:targetClass ex:C ; sh:closed true ;
        sh:property [ sh:path ex:p ; sh:minCount 1 ; sh:severity sh:Info ] .
      """

      assert {:error,
              %{code: :shacl_severity_not_partitionable, reason: :property_of_closed_shape}} =
               ShaclSeverity.violations_only(prefix <> closed)

      custom = """
      ex:S a sh:NodeShape ; sh:targetClass ex:C ;
        sh:property [ sh:path ex:p ; sh:minCount 1 ; sh:severity ex:Advisory ] .
      """

      assert {:ok, :no_non_violation_shapes} = ShaclSeverity.violations_only(prefix <> custom)
      assert {:error, %{code: :turtle_not_parseable}} = ShaclSeverity.violations_only("@@@")
    end

    test "its refusal code is classified without editing the refusal table" do
      assert AshA2A.Semantic.Refusal.classify(:shacl_severity_not_partitionable) == :refused_shacl
    end
  end

  describe "admission pipeline severity repair against the conformance corpus" do
    @tag :graphlaw
    if @engine_unavailable, do: @tag(skip: @engine_unavailable)

    test "warning-only admits, violation-with-warning refuses at :shacl, matching the corpus sidecars",
         %{tmp_dir: dir} do
      corpus = Path.join(to_string(:code.priv_dir(:ash_a2a)), "sa2a_conformance")
      read = &File.read!(Path.join(corpus, &1))

      law = fn name -> read.(name) end

      {:ok, manifest} =
        AshA2A.Semantic.RootManifest.LawCorpus.build(Path.join(dir, "corpus-law"), [
          {"semantic_profile", law.("profile.ttl")},
          {"shacl_shapes", law.("shapes.shacl.ttl")},
          {"shex_schema", law.("schema.shex")},
          {"shex_shape_map", law.("shape_map.json")},
          {"n3_rules", law.("rules/denials.n3")}
        ])

      scratch = Path.join(dir, "scratch")
      File.mkdir_p!(scratch)

      candidate = fn vector ->
        %AdmissionPipeline.Candidate{
          graph_ttl: read.(vector),
          profile_ttl: read.("profile.ttl"),
          shacl_shapes: read.("shapes.shacl.ttl"),
          shex_schema: read.("schema.shex"),
          shex_shape_map: read.("shape_map.json"),
          falsifiers: read.("rules/denials.n3"),
          provenance: World.provenance()
        }
      end

      for {vector, sidecar} <- [
            {"base.ttl", "base.expected.json"},
            {"negative/shacl_warning_only.ttl", "negative/shacl_warning_only.expected.json"},
            {"negative/shacl_violation_and_warning.ttl",
             "negative/shacl_violation_and_warning.expected.json"},
            {"negative/shacl_violation.ttl", "negative/shacl_violation.expected.json"}
          ] do
        expected = JSON.decode!(read.(sidecar))["expected"]["sa2a_admission"]

        case AdmissionPipeline.admit(candidate.(vector),
               tmp_dir: scratch,
               root_manifest: manifest
             ) do
          {:ok, result} ->
            assert expected == "ADMITTED", vector
            assert result.standing == :admitted

          {:error, %AdmissionRefusal{} = refusal} ->
            assert expected == "REFUSED", "#{vector}: #{AdmissionRefusal.describe(refusal)}"
            assert refusal.stage == :shacl
            assert refusal.code == :shacl_nonconformant
        end
      end

      assert File.ls!(scratch) == []
    end
  end

  describe "boundary telemetry added for independent observation" do
    setup do
      pid = self()
      handler = "gate2-boundary-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler,
        [
          [:ash_a2a, :semantic, :term, :operational_use],
          [:ash_a2a, :semantic, :mapping, :register]
        ],
        fn event, _m, meta, _ -> send(pid, {event, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
    end

    test "TermRegistry reports its real decision and returns it unchanged" do
      {:ok, registry} = TermRegistry.from_cache(profile: :strict)
      term = World.unadmitted_term()

      assert {:error, %{code: :runtime_semantic_individualism_refused, return_to: :admission}} =
               TermRegistry.admit_operational_use(registry, term)

      assert_receive {[:ash_a2a, :semantic, :term, :operational_use],
                      %{
                        iri: ^term,
                        outcome: :refused,
                        code: :runtime_semantic_individualism_refused
                      }}

      assert {:ok, {:candidate, ^term}} =
               TermRegistry.admit_operational_use(registry, term, consequential?: false)

      assert_receive {_, %{iri: ^term, outcome: :candidate, code: nil, consequential: false}}

      admitted = World.admitted_term()

      assert {:ok, {:admitted, ^admitted}} =
               TermRegistry.admit_operational_use(registry, admitted)

      assert_receive {_, %{iri: ^admitted, outcome: :admitted}}
    end

    test "MappingRegistry reports its real decision and returns it unchanged" do
      assert {:error, %{code: :semantic_mapping_unadmitted}} =
               MappingRegistry.register(MappingRegistry.new(), World.mapping(nil))

      assert_receive {[:ash_a2a, :semantic, :mapping, :register],
                      %{outcome: :refused, code: :semantic_mapping_unadmitted, kind: :exact_match}}

      assert {:error, %{code: :semantic_mapping_malformed}} =
               MappingRegistry.register(MappingRegistry.new(), :not_a_map)

      assert_receive {_, %{outcome: :refused, code: :semantic_mapping_malformed, source: nil}}
    end
  end
end

# --- SECTION 17: Original test/ash_a2a/chicago/unknown_llm_gate12_test.exs ---
defmodule AshA2A.Chicago.UnknownLlmGate12Test do
  @moduledoc """
  Qualifies `CHI-KNOWN` (Gate 12), `SA2A-UNKNOWN`, `SA2A-LLM` and `SA2A-MX`
  (RFC-SA2A-002 §43, §79-§82, §134) end to end: real router, real solver
  subprocess, real UNKNOWN router/allocator/LLM boundary, real CommandBus over
  real ETS resources, real staged conformance corpus, and the durable OCEL
  artifact re-read by the independent consumer.

  `async: false`: the observer attributes every telemetry event between a
  stimulus start and stop to that falsifier.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  alias AshA2A.Chicago
  alias AshA2A.Chicago.{Context, Falsifier, Result, Runner}
  alias AshA2A.Chicago.Courts
  alias AshA2A.Chicago.Courts.InferenceMappings, as: M
  alias AshA2A.Chicago.Fixtures.UnknownLlm, as: Fx
  alias AshA2A.Planning.RequestRouter
  alias AshA2A.Semantic.{Allocator, Unknown}

  @moduletag :tmp_dir

  @courts [
    Courts.Known,
    Courts.Unknown,
    Courts.LlmBoundary,
    Courts.MachineExperience
  ]

  @expected %{
    "CHI-KNOWN-001" => :falsifier_killed,
    "CHI-KNOWN-002" => :falsifier_killed,
    "CHI-KNOWN-003" => :falsifier_killed,
    "CHI-KNOWN-004" => :positive_control_passed,
    "CHI-KNOWN-005" => :positive_control_passed,
    "CHI-KNOWN-006" => :falsifier_killed,
    "CHI-KNOWN-007" => :falsifier_killed,
    "CHI-KNOWN-008" => :positive_control_passed,
    "SA2A-UNKNOWN-001" => :falsifier_killed,
    "SA2A-UNKNOWN-002" => :falsifier_killed,
    "SA2A-UNKNOWN-003" => :falsifier_killed,
    "SA2A-UNKNOWN-004" => :positive_control_passed,
    "SA2A-UNKNOWN-005" => :positive_control_passed,
    "SA2A-UNKNOWN-006" => :falsifier_killed,
    "SA2A-UNKNOWN-007" => :falsifier_killed,
    "SA2A-UNKNOWN-008" => :falsifier_killed,
    "SA2A-UNKNOWN-009" => :positive_control_passed,
    "SA2A-LLM-001" => :falsifier_killed,
    "SA2A-LLM-002" => :positive_control_passed,
    "SA2A-LLM-003" => :falsifier_killed,
    "SA2A-LLM-004" => :falsifier_killed,
    "SA2A-LLM-005" => :falsifier_killed,
    "SA2A-LLM-006" => :positive_control_passed,
    "SA2A-LLM-007" => :falsifier_killed,
    "SA2A-LLM-008" => :positive_control_passed,
    "SA2A-LLM-009" => :falsifier_killed,
    "SA2A-LLM-010" => :falsifier_killed,
    "SA2A-LLM-011" => :falsifier_killed,
    "SA2A-LLM-012" => :positive_control_passed,
    "SA2A-LLM-013" => :positive_control_passed,
    "SA2A-MX-001" => :positive_control_passed,
    "SA2A-MX-002" => :falsifier_killed,
    "SA2A-MX-003" => :positive_control_passed,
    "SA2A-MX-004" => :falsifier_killed,
    "SA2A-MX-005" => :falsifier_killed,
    "SA2A-MX-006" => :falsifier_killed
  }

  describe "end-to-end qualification run" do
    @tag :graphlaw_engine
    test "every falsifier reaches its final verdict and every pass is OCEL-corroborated",
         %{tmp_dir: dir} do
      assert {:ok, run} = Runner.run(courts: @courts, profile: :strict, evidence_dir: dir)

      by_id = Map.new(run.results, &{&1.falsifier_id, &1})
      assert Enum.sort(Map.keys(by_id)) == Enum.sort(Map.keys(@expected))

      failures =
        for {id, verdict} <- @expected,
            r = by_id[id],
            r.verdict != verdict or
              (Result.passing_verdict?(r) and r.ocel_corroborated? != true) do
          {id, r.verdict, r.detail, r.ocel_detail, r.evidence}
        end

      assert failures == [], inspect(failures, pretty: true, limit: :infinity)

      assert run.ocel.dropped == 0
      assert File.exists?(Path.join(dir, "ocel.json"))

      # Gate 12 is covered by a court at this profile.
      receipt = JSON.decode!(File.read!(Path.join(dir, "standing_receipt.json")))
      assert receipt["results"]["falsifiers_survived"] == 0
    end
  end

  describe "declarations" do
    test "courts are discoverable at :strict with exactly the assigned ids" do
      strict = Chicago.courts_for(:strict)
      for court <- @courts, do: assert(court in strict)

      assert Enum.map(@courts, & &1.id()) == ["CHI-KNOWN", "SA2A-UNKNOWN", "SA2A-LLM", "SA2A-MX"]
      assert Courts.Known.gate() == 12
      refute Courts.Known in Chicago.courts_for(:do)
    end

    test "every falsifier is fully declared with attempt and outcome predicates" do
      falsifiers = Enum.flat_map(@courts, & &1.falsifiers())
      ids = Enum.map(falsifiers, & &1.id)

      assert length(ids) == length(Enum.uniq(ids))

      for %Falsifier{} = f <- falsifiers do
        assert String.starts_with?(f.id, f.court_id <> "-")
        assert f.attempt_predicate, "#{f.id} has no attempt predicate"
        assert f.outcome_predicate, "#{f.id} has no outcome predicate"
      end

      kinds = Enum.frequencies_by(falsifiers, & &1.kind)
      assert kinds[:negative] >= 20
      assert kinds[:positive_control] >= 12
    end
  end

  # --- §22 anti-vacuity and §134 regression: the court machinery must detect
  # a non-executing reflex and a reintroduced inference call. Test-only courts
  # reuse CHI-KNOWN's own exported predicates.

  defmodule NonExecutingKnown do
    @moduledoc "Reuses CHI-KNOWN predicates over a request that never reaches the reflex."
    use AshA2A.Chicago.Court, discoverable: false

    alias AshA2A.Chicago.Courts.InferenceMappings, as: M

    def id, do: "CHI-KNOWNVAC"
    def title, do: "non-executing KNOWN reflex"
    def gate, do: 12
    def profile, do: :strict
    def rfc_sections, do: ["§43"]
    def ocel_mappings, do: [M.llm_invoke(), M.planner_invoke(), M.router_tier_refused()]

    def falsifiers do
      [
        Falsifier.new!(
          id: "CHI-KNOWNVAC-001",
          court_id: "CHI-KNOWNVAC",
          kind: :negative,
          invariant: "zero tokens without execution is not a pass",
          stimulus: "RequestRouter.route of a message with no input",
          boundary: "RequestRouter",
          forbidden_outcome: "llm.invoke",
          attempt_evidence: "router decided and machinery ran",
          survival_evidence: "llm.invoke",
          guard: "CHI-KNOWN attempt predicate",
          attempt_predicate: Courts.Known.router_decided_and_ran_predicate(),
          outcome_predicate: Courts.Known.llm_allocated_predicate()
        ),
        Falsifier.new!(
          id: "CHI-KNOWNVAC-002",
          court_id: "CHI-KNOWNVAC",
          kind: :positive_control,
          invariant: "positive execution is required",
          stimulus: "same",
          boundary: "RequestRouter",
          attempt_evidence: "router.tier_refused",
          attempt_predicate: {:observed, "router.tier_refused"},
          outcome_predicate: Courts.Known.known_reflex_predicate()
        )
      ]
    end

    def run(ctx) do
      [neg, pos] = falsifiers()
      empty = AshA2A.Protocol.Message.new_user([AshA2A.Protocol.Part.Data.new(%{})])

      for f <- [neg, pos] do
        Context.stimulus(ctx, f, fn -> RequestRouter.route(Fx.gate(), empty) end)
      end

      [
        # Claims a kill: the independent consumer must refuse to corroborate it.
        Result.negative(neg, attempt_observed?: true, forbidden_outcome_observed?: false),
        Result.positive(pos,
          attempt_observed?: M.seen?(ctx, pos, "router.tier_refused"),
          expected_outcome_observed?:
            M.seen?(ctx, pos, "planner.invoke", %{"outcome" => "solved"})
        )
      ]
    end
  end

  defmodule RegressedKnown do
    @moduledoc "The KNOWN phrase with its compiled template missing: inference reintroduced."
    use AshA2A.Chicago.Court, discoverable: false

    alias AshA2A.Chicago.Courts.InferenceMappings, as: M

    def id, do: "CHI-KNOWNREG"
    def title, do: "machine-experience regression"
    def gate, do: 12
    def profile, do: :strict
    def rfc_sections, do: ["§134"]
    def ocel_mappings, do: [M.llm_invoke(), M.planner_invoke()]

    def falsifiers do
      [
        Falsifier.new!(
          id: "CHI-KNOWNREG-001",
          court_id: "CHI-KNOWNREG",
          kind: :negative,
          invariant: "a KNOWN phrase allocates no LLM",
          stimulus: "RequestRouter.route of the KNOWN phrase with the compiled template removed",
          boundary: "RequestRouter.route_text/3",
          forbidden_outcome: "llm.invoke",
          attempt_evidence: "router decided and machinery ran",
          survival_evidence: "llm.invoke",
          guard: "compiled phrase template (removed)",
          failure_class: :planning_failure,
          attempt_predicate: Courts.Known.router_decided_and_ran_predicate(),
          outcome_predicate: Courts.Known.llm_allocated_predicate()
        )
      ]
    end

    def run(ctx) do
      [f] = falsifiers()

      Context.stimulus(ctx, f, fn ->
        RequestRouter.route(Fx.gate(), Fx.text_message(Fx.known_phrase()),
          phrase_templates: [],
          generate_object: Fx.tripwire_model()
        )
      end)

      [
        Result.negative(f,
          attempt_observed?:
            M.seen?(ctx, f, "router.tier_selected") and M.seen?(ctx, f, "llm.invoke"),
          forbidden_outcome_observed?: M.seen?(ctx, f, "llm.invoke")
        )
      ]
    end
  end

  defmodule SkippedMachinery do
    @moduledoc "SA2A-MX-002's stimulus with the compiled store withheld (step 1 guard deleted)."
    use AshA2A.Chicago.Court, discoverable: false

    alias AshA2A.Chicago.Courts.InferenceMappings, as: M

    def id, do: "SA2A-MXMUT"
    def title, do: "compiled route bypassed"
    def gate, do: nil
    def profile, do: :strict
    def rfc_sections, do: ["§22"]
    def ocel_mappings, do: [M.allocation(), M.allocator_decision(), M.llm_boundary_candidate()]

    def falsifiers do
      [mx2] = Enum.filter(Courts.MachineExperience.falsifiers(), &(&1.id == "SA2A-MX-002"))
      [%{mx2 | id: "SA2A-MXMUT-001", court_id: "SA2A-MXMUT"}]
    end

    def run(ctx) do
      [f] = falsifiers()
      budget = Allocator.new!([inference_calls: 1], issued_by: {:host, :mutation})

      Context.stimulus(ctx, f, fn ->
        Unknown.route("chicago.mx.mutation", Courts.MachineExperience.preserved_fixture(),
          budget: budget,
          resolver: {:llm, fn _ -> {:ok, %{"template" => "^x$"}} end}
        )
      end)

      [
        Result.negative(f,
          attempt_observed?: M.seen?(ctx, f, "semantic.allocation"),
          forbidden_outcome_observed?:
            M.seen?(ctx, f, "semantic.allocation", %{"resolver" => "llm"})
        )
      ]
    end
  end

  describe "permanent guards for the defects SA2A-LLM found" do
    test "SA2A-LLM-010: CommandBus refuses a model-sourced Authority before any actuation" do
      Fx.with_store(fn store_opts ->
        label = "guard-model-authority-#{Fx.unique()}"

        assert {:error, %{code: :model_authority_refused}} =
                 AshA2A.CommandBus.run(
                   Fx.ledger_command(label, Fx.ledger_authority(:model)),
                   Fx.ledger_message(label),
                   Fx.ledger(),
                   store_opts: store_opts
                 )

        refute label in Fx.ledger_labels()
        assert AshA2A.Semantic.Refusal.classify(:model_authority_refused) == :refused_authority
      end)
    end

    test "SA2A-LLM-003: admission refuses a model-invented namespace term, admits admitted/local ones" do
      text = "The operator opened the north gate."
      source = AshA2A.Semantic.Source.new(text)

      entity = fn type ->
        %{
          "entities" => [
            %{
              "id" => "e1",
              "kind" => "entity",
              "type" => type,
              "label" => "the north gate",
              "source_quote" => "the north gate"
            }
          ]
        }
      end

      admit = fn overrides ->
        {:ok, ir} = AshA2A.Semantic.IR.from_map(source.id, Fx.ir_proposal(text, overrides))
        AshA2A.Semantic.Admission.admit(source, ir)
      end

      assert {:error, %{code: :ontology_term_not_admitted, detail: %{term: "acme:Widget"}}} =
               admit.(entity.("acme:Widget"))

      assert {:error, %{code: :ontology_term_not_admitted}} =
               admit.(entity.("https://evil.example/vocab#Widget"))

      assert {:ok, %{standing: :admitted}} = admit.(entity.("schema:Thing"))
      assert {:ok, %{standing: :admitted}} = admit.(entity.("organization"))

      assert AshA2A.Semantic.Refusal.classify(:ontology_term_not_admitted) == :refused_namespace
    end
  end

  describe "anti-vacuity (§12, §22) and machine-experience regression (§134)" do
    test "a KNOWN run that never executed the reflex never passes", %{tmp_dir: dir} do
      {:ok, run} = Runner.run(courts: [NonExecutingKnown], profile: :strict, evidence_dir: dir)
      by_id = Map.new(run.results, &{&1.falsifier_id, &1})

      assert by_id["CHI-KNOWNVAC-001"].verdict == :unknown
      refute Result.counts_as_pass?(by_id["CHI-KNOWNVAC-001"])
      assert by_id["CHI-KNOWNVAC-002"].verdict == :positive_control_failed
      refute Result.counts_as_pass?(by_id["CHI-KNOWNVAC-002"])
    end

    test "reintroducing inference on the KNOWN route is detected as a regression",
         %{tmp_dir: dir} do
      {:ok, run} = Runner.run(courts: [RegressedKnown], profile: :strict, evidence_dir: dir)
      [result] = run.results

      assert result.verdict == :falsifier_survived
      assert result.ocel_corroborated? == true
      assert result.failure_class == :planning_failure
    end

    test "bypassing compiled machinery makes SA2A-MX-002's predicates survive", %{tmp_dir: dir} do
      {:ok, run} = Runner.run(courts: [SkippedMachinery], profile: :strict, evidence_dir: dir)
      [result] = run.results

      assert result.verdict == :falsifier_survived
      assert result.ocel_corroborated? == true
    end
  end
end

# --- SECTION 18: Original test/ash_a2a/chicago/wasm_default_resolution_test.exs ---
defmodule AshA2A.Chicago.WasmDefaultResolutionTest do
  @moduledoc """
  Permanent guard for `errc/ash-a2a-format` (ash_a2a#27): with NO override set
  (no `opts[:wasm_path]`, no application env, no environment variable), every
  praxis-graphlaw wasm resolver in this library resolves to the vendored,
  git-tracked, MANIFEST-pinned artifact `priv/graphlaw/praxis_graphlaw.wasm`.

  ash_a2a#27 run 35539819401 failed 103 tests on a hosted runner because seven
  resolvers defaulted to `/Users/sac/praxis/...`, a path that exists only on the
  author's machine, although the identical bytes ship in every checkout. This
  module asserts the resolved *state* -- the path, that a real file exists
  there, and that its real sha256 equals the digest `priv/graphlaw/MANIFEST.json`
  pins -- for each resolver. No collaborator is faked; the environment is the
  real process environment, saved and restored around each test.

  `async: false`: it mutates process-global application/OS environment, and
  ExUnit runs every `async: false` module only after all async modules finish,
  so no async module can observe the temporarily cleared overrides.
  """

  use ExUnit.Case, async: false

  alias AshA2A.GraphLaw

  @env_vars ~w(
    SA2A_GRAPHLAW_WASM
    PRAXIS_GRAPHLAW_WASM
    GRAPHLAW_WASM_PATH
    ASH_A2A_GRAPHLAW_WASM
    GRAPHLAW_WASM
  )
  @app_keys [:graphlaw_wasm_path, :sa2a_graphlaw_wasm]
  @semantic_wasm_module AshA2A.Semantic.GraphLaw.Wasm

  @resolvers [
    {"GraphLaw.WasmDriver", AshA2A.GraphLaw.WasmDriver},
    {"GraphLaw.Wasm", AshA2A.GraphLaw.Wasm},
    {"GraphLaw.Runtime", AshA2A.GraphLaw.Runtime},
    {"Semantic.GraphLawBridge", AshA2A.Semantic.GraphLawBridge},
    {"SA2A.Graphlaw", AshA2A.SA2A.Graphlaw},
    {"RootManifest.EngineProbe", AshA2A.Semantic.RootManifest.EngineProbe}
  ]

  setup do
    saved_env = for var <- @env_vars, do: {var, System.get_env(var)}
    saved_app = for key <- @app_keys, do: {key, Application.fetch_env(:ash_a2a, key)}
    saved_semantic = Application.fetch_env(:ash_a2a, @semantic_wasm_module)

    Enum.each(@env_vars, &System.delete_env/1)
    Enum.each(@app_keys, &Application.delete_env(:ash_a2a, &1))
    Application.delete_env(:ash_a2a, @semantic_wasm_module)

    on_exit(fn ->
      for {var, value} <- saved_env do
        if value, do: System.put_env(var, value), else: System.delete_env(var)
      end

      for {key, saved} <- saved_app do
        case saved do
          {:ok, value} -> Application.put_env(:ash_a2a, key, value)
          :error -> Application.delete_env(:ash_a2a, key)
        end
      end

      case saved_semantic do
        {:ok, value} -> Application.put_env(:ash_a2a, @semantic_wasm_module, value)
        :error -> Application.delete_env(:ash_a2a, @semantic_wasm_module)
      end
    end)

    :ok
  end

  defp pinned_sha256 do
    GraphLaw.manifest_path() |> File.read!() |> Jason.decode!() |> get_in(["artifact", "sha256"])
  end

  defp sha256_of(path), do: :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)

  defp assert_is_pinned_vendored_artifact(label, path) do
    assert path == GraphLaw.wasm_path(),
           "#{label} default resolved to #{path}, not the vendored #{GraphLaw.wasm_path()}"

    assert File.regular?(path), "#{label} default #{path} is not a real file"
    assert sha256_of(path) == pinned_sha256()
  end

  for {label, mod} <- @resolvers do
    test "#{label}.wasm_path/0 with no override resolves to the vendored, pinned artifact" do
      assert_is_pinned_vendored_artifact(unquote(label), unquote(mod).wasm_path())
    end
  end

  test "Semantic.GraphLaw.Wasm.wasm_path/0 with no override resolves to the vendored, pinned artifact" do
    assert_is_pinned_vendored_artifact(
      "Semantic.GraphLaw.Wasm",
      @semantic_wasm_module.wasm_path()
    )
  end

  test "AshA2A.SA2A.Graphlaw.available?/0 agrees with node presence alone: the default artifact is never the missing piece" do
    result = AshA2A.SA2A.Graphlaw.available?()

    if System.find_executable("node") do
      assert result == :ok
    else
      assert {:unavailable, reason} = result
      refute reason == :wasm_not_built
    end
  end

  test "an explicit override still wins over the vendored default (precedence is unchanged)" do
    explicit = "/nonexistent/override/praxis_graphlaw.wasm"

    assert AshA2A.GraphLaw.WasmDriver.wasm_path(wasm_path: explicit) == explicit
    assert AshA2A.GraphLaw.Wasm.wasm_path(wasm_path: explicit) == explicit
    assert AshA2A.GraphLaw.Runtime.wasm_path(wasm_path: explicit) == explicit
    assert AshA2A.Semantic.GraphLawBridge.wasm_path(wasm_path: explicit) == explicit
    assert AshA2A.SA2A.Graphlaw.wasm_path(wasm_path: explicit) == explicit
    assert AshA2A.Semantic.RootManifest.EngineProbe.wasm_path(wasm_path: explicit) == explicit

    System.put_env("GRAPHLAW_WASM", explicit)
    assert @semantic_wasm_module.wasm_path() == explicit
  end
end
