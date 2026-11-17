# NOTE: 2 module(s) removed from this consolidated file because the repaired originals (kept as separate files) define the same modules; see docs/reference/test-consolidation-merge.md.
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
# SPDX-License-Identifier: MIT

# ==============================================================================
# Consolidated Test Suite: Chicago Formal Verification, Hardening, Stress & Release Courts (Part 1)
# Contains 18 original test files:
#   - test/ash_a2a/chicago/authority_courts_test.exs
#   - test/ash_a2a/chicago/autonomy_bounds_test.exs
#   - test/ash_a2a/chicago/bench_harness_test.exs
#   - test/ash_a2a/chicago/brce_gate7_test.exs
#   - test/ash_a2a/chicago/canonical_identity_projection_test.exs
#   - test/ash_a2a/chicago/crash_reconciliation_test.exs
#   - test/ash_a2a/chicago/cross_runtime_portability_test.exs
#   - test/ash_a2a/chicago/crown_test.exs
#   - test/ash_a2a/chicago/envelope_negotiation_transport_test.exs
#   - test/ash_a2a/chicago/falsifier_wasm_default_reachability_test.exs
#   - test/ash_a2a/chicago/federated_delegation_test.exs
#   - test/ash_a2a/chicago/fibo_finance_test.exs
#   - test/ash_a2a/chicago/fibo_high_value_finance_test.exs
#   - test/ash_a2a/chicago/foundation_test.exs
#   - test/ash_a2a/chicago/fresh_consumer_test.exs
#   - test/ash_a2a/chicago/graphlaw_engine_stop_host_test.exs
#   - test/ash_a2a/chicago/graphlaw_engine_test.exs
#   - test/ash_a2a/chicago/hooks_cascade_test.exs
# ==============================================================================

# --- SECTION 1: Original test/ash_a2a/chicago/authority_courts_test.exs ---

# --- SECTION 2: Original test/ash_a2a/chicago/autonomy_bounds_test.exs ---
defmodule AshA2A.Chicago.AutonomyBoundsTest do
  @moduledoc """
  Qualifies the Gate 6 autonomous-execution court (`CHI-AUTO`) and the
  resource-bounds court (`SA2A-BOUNDS`, incl. Benchmark B4) end to end, plus
  narrow tests of the episode executor and ledger they attack.

  Chicago style throughout: the real `AshA2A.Semantic.Episode` executor and
  ledger, real admission over real source text, the real `hddl_cli`
  subprocess, the real CommandBus, a real receipt store and authority broker,
  the real ETS `Step` resource, and a real OCEL artifact read back from disk
  by the independent consumer.

  `async: false` -- the observer attributes telemetry to the active stimulus.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_solo
  alias AshA2A.Chicago
  alias AshA2A.Chicago.{Query, Result, Runner, StandingReceipt}
  alias AshA2A.Chicago.Courts.{AutonomousExecution, ResourceBounds}
  alias AshA2A.Chicago.Fixtures.AutonomyBounds, as: F
  alias AshA2A.Planning.HddlSolver
  alias AshA2A.Semantic.{BoundedProduction, Episode, Refusal}
  alias AshA2A.Semantic.Episode.Ledger

  @moduletag :tmp_dir

  @planner_dependent ["CHI-AUTO-001", "SA2A-BOUNDS-020"]

  @expected %{
    "CHI-AUTO-001" => :positive_control_passed,
    "CHI-AUTO-002" => :falsifier_killed,
    "CHI-AUTO-003" => :falsifier_killed,
    "CHI-AUTO-004" => :falsifier_killed,
    "CHI-AUTO-005" => :falsifier_killed,
    "CHI-AUTO-006" => :positive_control_passed,
    "SA2A-BOUNDS-001" => :falsifier_killed,
    "SA2A-BOUNDS-002" => :falsifier_killed,
    "SA2A-BOUNDS-003" => :falsifier_killed,
    "SA2A-BOUNDS-004" => :falsifier_killed,
    "SA2A-BOUNDS-005" => :falsifier_killed,
    "SA2A-BOUNDS-006" => :falsifier_killed,
    "SA2A-BOUNDS-007" => :falsifier_killed,
    "SA2A-BOUNDS-008" => :falsifier_killed,
    "SA2A-BOUNDS-009" => :falsifier_killed,
    "SA2A-BOUNDS-010" => :falsifier_killed,
    "SA2A-BOUNDS-011" => :falsifier_killed,
    "SA2A-BOUNDS-012" => :falsifier_killed,
    "SA2A-BOUNDS-013" => :falsifier_killed,
    "SA2A-BOUNDS-014" => :falsifier_killed,
    "SA2A-BOUNDS-015" => :positive_control_passed,
    "SA2A-BOUNDS-016" => :falsifier_killed,
    "SA2A-BOUNDS-017" => :falsifier_killed,
    "SA2A-BOUNDS-018" => :positive_control_passed,
    "SA2A-BOUNDS-019" => :positive_control_passed,
    "SA2A-BOUNDS-020" => :measured
  }

  describe "end-to-end Chicago run of CHI-AUTO and SA2A-BOUNDS" do
    test "every falsifier reaches its verdict and every pass is corroborated from the OCEL on disk",
         %{tmp_dir: dir} do
      planner? = File.exists?(HddlSolver.cli_path())

      unless planner?,
        do:
          IO.puts(
            "\n  [sa2a] hddl_cli not built: #{inspect(@planner_dependent)} expected BLOCKED"
          )

      assert {:ok, run} =
               Runner.run(
                 courts: [AutonomousExecution, ResourceBounds],
                 profile: :do,
                 evidence_dir: dir
               )

      by_id = Map.new(run.results, &{&1.falsifier_id, &1})
      assert Enum.sort(Map.keys(by_id)) == Enum.sort(Map.keys(@expected))

      for {id, verdict} <- @expected do
        result = by_id[id]

        if id in @planner_dependent and not planner? do
          assert result.verdict == :blocked
        else
          assert result.verdict == verdict,
                 "#{id}: #{result.verdict} detail=#{result.detail} ocel=#{result.ocel_detail} " <>
                   "evidence=#{inspect(result.evidence)}"

          assert result.ocel_corroborated? == true, "#{id}: #{result.ocel_detail}"
          assert Result.counts_as_pass?(result)
        end
      end

      assert run.ocel.dropped == 0

      # Exhaustion is typed per dimension and never passes the admitted ceiling.
      for {id, resource} <- [
            {"SA2A-BOUNDS-001", :executions},
            {"SA2A-BOUNDS-008", :external_requests},
            {"SA2A-BOUNDS-009", :money_micros},
            {"SA2A-BOUNDS-010", :tokens}
          ] do
        ev = by_id[id].evidence
        assert ev["episode_outcome"] == :resource_exhausted
        assert ev["episode_resource"] == resource
        assert ev["committed"] == 2 and ev["step_rows"] == 2
      end

      assert by_id["SA2A-BOUNDS-004"].evidence["max_in_flight"] <= 2
      assert by_id["SA2A-BOUNDS-004"].evidence["max_actuation_overlap"] <= 2
      assert by_id["SA2A-BOUNDS-007"].evidence["retries"] == 2
      assert by_id["SA2A-BOUNDS-014"].evidence["token_limit"] == 2_000
      assert by_id["SA2A-BOUNDS-014"].evidence["tokens_consumed"] == 1_000

      delegation = by_id["SA2A-BOUNDS-011"].evidence
      assert delegation["from_parent"] == "bounds_delegation_not_narrowing"
      assert delegation["from_stale"] == "bounds_delegation_not_narrowing"
      assert delegation["forged_run"] == "refused:episode_envelope_unknown"
      assert delegation["fresh_run"] == "refused:episode_envelope_not_delegated"

      authority = by_id["SA2A-BOUNDS-012"].evidence
      assert authority["with_authority"] == "bounds_authority_not_delegable"
      assert authority["with_principal"] == "bounds_authority_not_delegable"
      assert authority["widened_capabilities"] == "bounds_delegation_not_narrowing"
      assert authority["limited_subplan"] == "refused:authority_required"

      edges = by_id["SA2A-BOUNDS-016"].evidence
      assert edges["tokens"] == "episode_envelope_ceiling_overflow"
      assert edges["fan_out"] == "episode_envelope_ceiling_overflow"
      assert edges["executions"] == "bounds_resource_invalid"
      assert edges["parallelism"] == "bounds_ceiling_invalid"

      if planner? do
        b4 = by_id["SA2A-BOUNDS-020"].measurements
        assert b4["planner_invocation_us"]["n"] == 3
        assert b4["planning_projection_us"]["n"] == 3
        assert b4["plan_admission_us"]["n"] == 3
        assert b4["plan_size"] == 5 and b4["planner_plan_size"] == 5
        assert b4["authority_decision_us"]["n"] == 5 and b4["do_us"]["n"] == 5
        assert b4["planning_events_carry_command"] == false
        assert b4["planning_precedes_first_actuation"] == true
        assert b4["effective_bounds"]["executions"] == 64

        auto = by_id["CHI-AUTO-001"].evidence
        assert length(auto["planned_actions"]) == 5
        assert auto["envelope_executions"].consumed == 5
      end

      # The independent consumer reads the durable artifact.
      assert {:ok, index} = Query.load(Path.join(dir, "ocel.json"), run.ocel.sha256)

      assert {true, _} =
               Query.eval(
                 index,
                 "CHI-AUTO-006",
                 {:precedes, "episode.transition.start", "brce.actuate.start", "command"}
               )

      receipt = JSON.decode!(File.read!(Path.join(dir, "standing_receipt.json")))
      assert :ok = StandingReceipt.verify_digest(receipt)
      assert receipt["results"]["falsifiers_survived"] == 0
    end
  end

  describe "discovery, mappings and refusal classification" do
    test "CHI-AUTO is a gate-6 DO court and SA2A-BOUNDS a PLAN court" do
      assert AutonomousExecution in Chicago.courts_for(:do)
      refute AutonomousExecution in Chicago.courts_for(:plan)
      assert ResourceBounds in Chicago.courts_for(:plan)
      refute ResourceBounds in Chicago.courts_for(:logic)
      assert AutonomousExecution.gate() == 6 and ResourceBounds.gate() == 6
    end

    test "every falsifier declares both OCEL predicates and the episode mappings are admitted once" do
      for court <- [AutonomousExecution, ResourceBounds], f <- court.falsifiers() do
        assert f.attempt_predicate != nil and f.outcome_predicate != nil, f.id
      end

      shared =
        [AutonomousExecution, ResourceBounds]
        |> Runner.ocel_mappings()
        |> Enum.filter(&match?([:ash_a2a, :episode | _], &1.event))

      assert length(shared) == length(F.mappings())
    end

    test "every refusal code the executor and ledger introduce classifies without editing the table" do
      codes = Map.merge(Episode.__sa2a_refusal_codes__(), Ledger.__sa2a_refusal_codes__())

      for {code, class} <- codes do
        assert Refusal.classify(code) == class
        refute class == :blocked_unknown
      end
    end
  end

  describe "episode executor and ledger (real collaborators)" do
    test "an envelope missing a dimension is refused, never defaulted" do
      spec = Keyword.delete(F.envelope_spec(), :memory_bytes)

      assert {:error, %{code: :episode_envelope_incomplete, detail: %{missing: [:memory_bytes]}}} =
               Episode.issue({:host, :test}, spec)
    end

    test "a model cannot issue an envelope" do
      assert {:error, %{code: :model_issued_budget_refused}} =
               Episode.issue({:model, "m"}, F.envelope_spec())
    end

    test "concurrent delegations of the last execution admit exactly one" do
      parent = F.envelope!(executions: 1)

      results =
        1..16
        |> Task.async_stream(fn _ -> Episode.delegate(parent, executions: 1) end,
          max_concurrency: 16
        )
        |> Enum.map(fn {:ok, r} -> r end)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert {:ok, %{executions: %{remaining: 0}}} = Episode.snapshot(parent)
    end

    test "an episode without a control contract is refused, not run unbounded" do
      F.with_env(fn env ->
        package = F.static_package!(F.projection(), 1)

        result =
          F.run!(package, F.envelope!(), env,
            bind: F.bind(&F.record("unit-#{env.nonce}", &1)),
            control: nil
          )

        assert {result.outcome, result.code} == {:refused, :unbounded_production_operation}
        assert F.rows("unit-#{env.nonce}") == []
      end)
    end

    test "BoundedProduction bound refusals carry the state reached" do
      {:ok, contract} =
        BoundedProduction.contract("unit",
          max_steps: 3,
          max_wall_time_ms: 5_000,
          termination: fn _ -> false end
        )

      assert {:error, %{code: :bound_reached, bound: :max_steps, state: 3}} =
               BoundedProduction.run(contract, &(&1 + 1), 0)
    end
  end
end

# --- SECTION 3: Original test/ash_a2a/chicago/bench_harness_test.exs ---
defmodule AshA2A.Chicago.BenchHarnessTest do
  @moduledoc """
  Qualifies the RFC-SA2A-002 benchmark harness and court `SA2A-BENCH`
  (§84, §85, §89, §93, §102, §122, §135, Appendix E), Chicago style: the
  benchmarks drive the real `AdmissionPipeline` + GraphLaw wasm, the real
  `Authority.Grant` over a real `Broker.InMemory`, the real `CommandBus` with a
  real `ReceiptStore.Memory` and receipt outbox, and a real `Observer` whose
  OCEL artifact is read back from disk by the independent `Query` consumer.
  Post-state is read with `Ash.read!/1`. No collaborator is replaced.

  `async: false` -- the court run attributes every boundary event emitted
  during a stimulus to its falsifier, so concurrent tests driving the same
  boundaries would pollute attribution.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  alias AshA2A.Authority.Broker.InMemory
  alias AshA2A.Authority.Grant
  alias AshA2A.Chicago.{Bench, Query, Runner, StandingReceipt, Subject}
  alias AshA2A.Chicago.Bench.{B1Admission, B5Authority, B9OcelOverhead}
  alias AshA2A.Chicago.Bench.{Environment, Regression, Timeline}
  alias AshA2A.Chicago.Courts.Benchmarks
  alias AshA2A.Chicago.Fixtures.BenchHarness.{AdmissionCorpus, Ledger}
  alias AshA2A.GraphLaw.Wasm

  @moduletag :tmp_dir

  @graphlaw Wasm.availability()
  @graphlaw_skip (case @graphlaw do
                    :ok ->
                      nil

                    {:error, detail} ->
                      "real GraphLaw wasm unavailable (#{inspect(detail)}); B1 runs the real engine and is never faked"
                  end)

  setup_all do
    {:ok, body} = B5Authority.run(iterations: 2, warmup: 1)
    %{b5: Bench.record(B5Authority.id(), body)}
  end

  describe "latency distribution" do
    test "nearest-rank percentiles, mean and tail over a known sample" do
      d = Bench.distribution(Enum.shuffle(Enum.to_list(1..100)))

      assert d["n"] == 100

      assert {d["min"], d["p50"], d["p90"], d["p95"], d["p99"], d["max"]} ==
               {1, 50, 90, 95, 99, 100}

      assert d["mean"] == 50.5
      assert d["stddev"] == 28.9
    end

    test "a single sample and an empty sample" do
      assert %{"n" => 1, "min" => 7, "p50" => 7, "p99" => 7, "max" => 7} = Bench.distribution([7])
      assert Bench.distribution([]) == %{"n" => 0}
    end
  end

  describe "measure/2" do
    test "warmup is excluded from the distribution but its invariant failures are reported" do
      step = fn phase, i ->
        payload = :crypto.strong_rand_bytes(512)
        algorithm = if phase == :warmup or i == 2, do: :md5, else: :sha256
        started = System.monotonic_time(:microsecond)
        digest = :crypto.hash(algorithm, payload)
        duration = System.monotonic_time(:microsecond) - started

        invariant =
          if byte_size(digest) == 32,
            do: :ok,
            else: {:error, "#{algorithm} digest is #{byte_size(digest)} bytes, not 32"}

        [
          %{
            case: "digest",
            duration_us: duration,
            outcome: Atom.to_string(algorithm),
            phases: %{"hash" => duration},
            invariant: invariant
          }
        ]
      end

      result = Bench.measure(step, iterations: 3, warmup: 2)

      assert result["iterations"] == 3
      assert result["latency_us"]["n"] == 3
      assert result["warmup_policy"]["warmup_samples"] == 2
      assert result["warmup_policy"]["warmup_samples_in_distribution"] == false
      assert Enum.map(result["samples"], & &1["iteration"]) == [1, 2, 3]
      assert result["by_case"]["digest"]["phases_us"]["hash"]["n"] == 3
      assert result["by_case"]["digest"]["outcomes"] == %{"sha256" => 2, "md5" => 1}

      assert result["invariant_failure_count"] == 3

      assert Enum.map(result["invariant_failures"], &{&1["phase"], &1["iteration"]}) ==
               [{"warmup", 1}, {"warmup", 2}, {"measured", 2}]

      assert is_integer(result["memory"]["erlang_memory_delta_bytes"]["total"])
      assert is_integer(result["memory"]["measuring_process_memory_delta_bytes"])
      assert result["throughput"]["samples_per_second"] > 0
      assert Bench.record("SA2A-B0", result)["status"] == "INVARIANT_FAILURE"
    end
  end

  describe "raw result integrity (§135)" do
    test "a written raw result verifies; an edited one is refused", %{tmp_dir: dir, b5: record} do
      written = Bench.write!(record, dir)

      assert Path.basename(written.path) == "SA2A-B5.#{written.digest}.json"
      assert {:ok, raw} = Bench.verify_file(written.path)
      assert raw["benchmark_id"] == "SA2A-B5"
      assert raw["raw_result_digest"] == nil

      doc = JSON.decode!(File.read!(written.path))

      # Manual edit of one latency number: digest no longer matches.
      edited = put_in(doc, ["raw_result", "latency_us", "p50"], 1)
      File.write!(written.path, JSON.encode!(edited))

      assert {:error, {:raw_result_digest_mismatch, claimed: claimed, actual: actual}} =
               Bench.verify_file(written.path)

      assert claimed == written.digest
      refute actual == written.digest

      # Re-sealing the embedded digest without renaming the content address is refused too.
      resealed =
        Map.put(
          edited,
          "raw_result_digest",
          Bench.sha256(AshA2A.Chicago.Json.canonical(edited["raw_result"]))
        )

      File.write!(written.path, JSON.encode!(resealed))

      assert {:error, {:content_address_mismatch, file_name: _, actual: _}} =
               Bench.verify_file(written.path)

      File.write!(written.path, JSON.encode!(%{"not" => "a raw result"}))
      assert {:error, :not_a_bench_raw_result} = Bench.verify_file(written.path)

      # The integrity refusal codes are classified without editing Semantic.Refusal.
      mapping = AshA2A.Semantic.Refusal.mapping()
      assert mapping[:not_a_bench_raw_result] == :refused_structure
      assert mapping[:raw_result_digest_mismatch] == :refused_identity
      assert mapping[:content_address_mismatch] == :refused_identity
    end
  end

  describe "environment receipt (§102)" do
    test "captures the real host, runtime and WASM engine identity" do
      env = Environment.capture()

      assert is_binary(env["cpu"]["model"]) and env["cpu"]["model"] != ""
      assert env["cpu"]["logical_count"] > 0
      assert env["cpu"]["beam_schedulers_online"] == System.schedulers_online()
      assert env["memory"]["total_bytes"] > 0
      assert is_binary(env["os"]["kernel_release"])
      assert env["runtime"]["otp_release"] == System.otp_release()
      assert env["runtime"]["elixir"] == System.version()
      assert env["wasm"]["wasmex"] == to_string(Application.spec(:wasmex, :vsn))

      if System.find_executable("wasmtime") do
        assert env["wasm"]["wasmtime_cli"] =~ "wasmtime"
      else
        assert env["wasm"]["wasmtime_cli"] == nil
      end

      assert env["wasm"]["graphlaw_available"] == (@graphlaw == :ok)
      assert is_binary(env["storage"]["filesystem"])
      assert env["model_provider"]["status"] == "not_applicable"
      assert env["host"]["hostname_sha256"] =~ ~r/\A[0-9a-f]{64}\z/

      # Identity covers stable fields only: a second capture shares it, and it
      # is re-derivable from the receipt itself.
      assert env["identity"] =~ ~r/\A[0-9a-f]{64}\z/
      assert Environment.capture()["identity"] == env["identity"]
      assert Environment.identity(env) == env["identity"]
      refute Environment.identity(put_in(env, ["cpu", "model"], "other")) == env["identity"]
    end
  end

  describe "regression policy (§122)" do
    test "compares only within one environment; correctness outranks latency", %{b5: baseline} do
      assert {:ok, same} = Regression.compare(baseline, baseline)
      assert same["verdict"] == "WITHIN_BOUNDS"
      assert same["latency_deltas_us"]["p50"]["delta"] == 0

      other_env = put_in(baseline, ["environment", "identity"], String.duplicate("0", 64))

      assert {:error, {:not_comparable, ["environment.identity"]}} =
               Regression.compare(baseline, other_env)

      p99 = baseline["latency_us"]["p99"]

      assert {:ok, %{"verdict" => "BOUND_VIOLATED", "bound_violations" => [violation]}} =
               Regression.compare(baseline, baseline, bounds: %{"latency_us.p99" => p99 - 1})

      assert violation["observed"] == p99

      failing = Map.put(baseline, "invariant_failure_count", 1)

      assert {:ok, %{"verdict" => "CORRECTNESS_REGRESSION"}} =
               Regression.compare(baseline, failing, bounds: %{"latency_us.p99" => p99 * 10})
    end
  end

  describe "SA2A-B5 authority and BRCE (§89)" do
    test "reports every authority path separately with its BRCE semantics intact", %{b5: record} do
      assert record["status"] == "MEASURED"
      assert record["invariant_failure_count"] == 0
      by_case = record["by_case"]

      assert by_case["authorized"]["outcomes"] == %{"committed" => 2}

      for scenario <- ["refused", "expired", "revoked", "broker_unavailable"] do
        assert by_case[scenario]["outcomes"] == %{"refused:authority_required" => 2}, scenario
        phases = by_case[scenario]["phases_us"]
        assert phases["authority_decision"]["n"] == 2
        refute Map.has_key?(phases, "actuator"), "#{scenario} must never actuate"
        refute Map.has_key?(phases, "prepared_receipt_durability")
      end

      authorized = by_case["authorized"]["phases_us"]

      for phase <- [
            "authority_decision",
            "bus_admission",
            "prepared_receipt_durability",
            "actuator",
            "final_receipt",
            "independent_postcondition",
            "end_to_end"
          ] do
        assert authorized[phase]["n"] == 2, phase
      end

      assert record["exact_subject"]["identity"] =~ ~r/\A[0-9a-f]{64}\z/
      assert record["environment"]["identity"] =~ ~r/\A[0-9a-f]{64}\z/

      # Independent post-state: authorized commands left rows, refusal paths none.
      labels = Ledger |> Ash.read!() |> Enum.map(& &1.label)
      assert Enum.count(labels, &String.starts_with?(&1, "chicago-bench-b5-authorized-")) >= 3

      for scenario <- ["refused", "expired", "revoked", "broker_unavailable"] do
        assert Enum.filter(labels, &String.starts_with?(&1, "chicago-bench-b5-#{scenario}-")) ==
                 []
      end
    end

    test "the grant decision emits evidence at its own boundary without changing its result" do
      broker_name = Module.concat(__MODULE__, "Broker#{System.unique_integer([:positive])}")
      {:ok, broker_pid} = InMemory.start_link(name: broker_name)
      broker = {InMemory, [name: broker_name]}
      principal = "grant-telemetry-#{System.unique_integer([:positive])}"
      capability = B5Authority.capability()
      # The decision is ONE event: the retired `[:ash_a2a, :authority, :grant]`
      # name is attached too, so a second emission for the same decision
      # would appear in the drained timeline and break the exact match below.
      ref = Timeline.attach([B5Authority.grant_event(), [:ash_a2a, :authority, :grant]])

      try do
        assert Grant.authorize(principal, capability, policy: :broker, broker: broker) == nil

        {:ok, _} =
          Grant.grant(AshA2A.Identity.principal(principal), capability, broker: broker)

        authority = Grant.authorize(principal, capability, policy: :broker, broker: broker)
        assert authority.subject.value == principal
        assert authority.capability_id == capability

        decision = B5Authority.grant_event()

        assert [
                 %{
                   event: ^decision,
                   metadata: %{
                     outcome: :refused,
                     code: :no_standing_grant,
                     reason: :no_standing_grant
                   }
                 },
                 %{
                   event: ^decision,
                   metadata: %{outcome: :granted, code: nil, reason: :grant_standing}
                 }
               ] = Timeline.drain(ref)
      after
        Timeline.detach(ref)
        GenServer.stop(broker_pid)
      end
    end
  end

  describe "SA2A-B1 admission latency and throughput (§85)" do
    if @graphlaw_skip, do: @describetag(skip: @graphlaw_skip)

    test "valid and invalid candidates all go through the real engine and are all costed" do
      assert {:ok, body} = B1Admission.run(iterations: 1, warmup: 0)
      record = Bench.record(B1Admission.id(), body)

      assert record["status"] == "MEASURED", inspect(record["invariant_failures"])
      assert record["throughput"]["admitted"] == 1
      assert record["throughput"]["refused"] == 5
      assert record["throughput"]["admissions_per_second"] > 0
      assert record["throughput"]["refusals_per_second"] > 0
      assert record["fixture"]["invalid_cases"] == 5
      assert record["fixture"]["corpus_digest"] == AdmissionCorpus.digest()

      assert Enum.sort(Map.keys(record["by_case"])) ==
               Enum.sort(Enum.map(AdmissionCorpus.cases(), & &1.id))

      # Invalid candidates are never skipped from cost: every case is in the totals.
      assert record["rfc_measures_us"]["total_admission"]["n"] == 6
      assert record["rfc_measures_us"]["candidate_parse"]["n"] == 6
      assert record["latency_us"]["n"] == 6
      # Only the lawful case reaches the profile checks.
      assert record["stage_latency_us"]["profile_checks"]["n"] == 1

      for measure <- ["canonicalization", "shex", "shacl", "closure", "falsifier"] do
        assert record["rfc_measures_us"][measure]["n"] >= 1, measure
      end
    end

    test "a mislabeled corpus surfaces as an invariant failure, never as a measurement" do
      mislabeled = [
        %{
          id: "mislabeled-not-turtle-expected-admitted",
          valid?: true,
          expect: :admitted,
          candidate: AdmissionCorpus.candidate(graph_ttl: AdmissionCorpus.not_turtle())
        }
      ]

      assert {:ok, body} = B1Admission.run(iterations: 1, warmup: 0, cases: mislabeled)
      record = Bench.record(B1Admission.id(), body)

      assert record["status"] == "INVARIANT_FAILURE"
      assert [%{"detail" => detail, "phase" => "measured"}] = record["invariant_failures"]
      assert detail =~ "lawful candidate refused at :parse"
      refute record["fixture"]["corpus_digest"] == AdmissionCorpus.digest()
      # The cost of the refused candidate is still reported.
      assert record["latency_us"]["n"] == 1
    end
  end

  describe "SA2A-BENCH court end-to-end" do
    @tag :graphlaw_engine
    test "Runner.run: every benchmark falsifier measured over the real SUT and OCEL-corroborated",
         %{tmp_dir: dir} do
      assert {:ok, run} =
               Runner.run(
                 courts: [Benchmarks],
                 profile: :core,
                 evidence_dir: dir,
                 bench_iterations: 2,
                 bench_warmup: 1
               )

      # Discovered, not registered.
      assert Benchmarks in AshA2A.Chicago.courts_for(:core)

      by_id = Map.new(run.results, &{&1.falsifier_id, &1})
      assert Enum.sort(Map.keys(by_id)) == ["SA2A-BENCH-001", "SA2A-BENCH-002", "SA2A-BENCH-003"]

      expected_b1 = if @graphlaw == :ok, do: :measured, else: :blocked

      for {id, expected} <- [
            {"SA2A-BENCH-001", expected_b1},
            {"SA2A-BENCH-002", :measured},
            {"SA2A-BENCH-003", :measured}
          ] do
        result = by_id[id]
        assert result.verdict == expected, "#{id}: #{result.verdict} #{result.detail}"

        if expected == :measured do
          assert result.ocel_corroborated? == true, "#{id}: #{result.ocel_detail}"
          assert result.attempt_observed? == true

          assert {:ok, raw} = Bench.verify_file(result.evidence["raw_result_path"])
          assert raw["status"] == "MEASURED"
          assert raw["invariant_failure_count"] == 0
          assert raw["iterations"] == 2
          assert raw["warmup_policy"]["warmup_iterations"] == 1
          assert raw["exact_subject"]["identity"] == Subject.digest(run.subject)
          assert raw["environment"]["identity"] == Environment.identity(raw["environment"])
          assert result.measurements["raw_result_digest"] == result.evidence["raw_result_digest"]
        end
      end

      b9 = by_id["SA2A-BENCH-003"]
      {:ok, b9_raw} = Bench.verify_file(b9.evidence["raw_result_path"])
      assert b9_raw["ocel"]["dropped"] == 0
      assert b9_raw["ocel"]["events"] >= 3 * 8
      assert b9_raw["ocel"]["serialized_bytes"] > 0
      assert b9_raw["ocel"]["query"]["load"] == "ok"
      assert b9_raw["evidence_disabled"] == false
      assert b9_raw["ocel"]["validation"]["status"] in ["valid", "not_run"]
      assert is_integer(b9_raw["observer_process"]["reductions"])
      assert Map.has_key?(b9_raw["arms"], "baseline")

      # The independent consumer, from disk, sees the real SUT activities per falsifier.
      assert {:ok, index} = Query.load(run.ocel.path, run.ocel.sha256)

      assert {true, _} =
               Query.eval(
                 index,
                 "SA2A-BENCH-002",
                 {:observed, "authority.decision", %{"outcome" => "refused"}}
               )

      assert {false, _} =
               Query.eval(index, "SA2A-BENCH-002", {:observed, "admission.stop"})

      # The package binds every raw-result digest through the standing receipt.
      results_json = JSON.decode!(File.read!(Path.join(dir, "results.json")))

      for entry <- results_json, entry["verdict"] == "MEASURED" do
        assert entry["measurements"]["raw_result_digest"] =~ ~r/\A[0-9a-f]{64}\z/
        assert entry["ocel_corroborated"] == true
      end

      receipt = JSON.decode!(File.read!(Path.join(dir, "standing_receipt.json")))
      assert :ok = StandingReceipt.verify_digest(receipt)
      assert receipt["results"]["measured"] == if(@graphlaw == :ok, do: 3, else: 2)
      # Benchmarks cover no crown gate: standing is honestly partial, never CONFORMANT.
      assert receipt["standing"] == "PARTIAL_ALIVE"
    end

    if @graphlaw_skip, do: @tag(skip: @graphlaw_skip)

    test "a benchmark that observes an invariant failure is reported UNKNOWN, never measured (§84)",
         %{tmp_dir: dir} do
      mislabeled = [
        %{
          id: "mislabeled-not-turtle-expected-admitted",
          valid?: true,
          expect: :admitted,
          candidate: AdmissionCorpus.candidate(graph_ttl: AdmissionCorpus.not_turtle())
        }
      ]

      assert {:ok, run} =
               Runner.run(
                 courts: [Benchmarks],
                 profile: :core,
                 evidence_dir: dir,
                 bench_iterations: 1,
                 bench_warmup: 0,
                 bench_b1_cases: mislabeled
               )

      b1 = Enum.find(run.results, &(&1.falsifier_id == "SA2A-BENCH-001"))
      assert b1.verdict == :unknown
      assert b1.failure_class == :admission_failure
      assert b1.detail =~ "semantic invariant failure"
      assert b1.measurements["invariant_failure_count"] == 1
      refute AshA2A.Chicago.Result.counts_as_pass?(b1)

      assert {:ok, raw} = Bench.verify_file(b1.evidence["raw_result_path"])
      assert raw["status"] == "INVARIANT_FAILURE"

      receipt = JSON.decode!(File.read!(Path.join(dir, "standing_receipt.json")))
      assert "SA2A-BENCH-001" in receipt["results"]["unresolved_ids"]
    end
  end

  describe "mix ash_a2a.chicago.bench" do
    setup do
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    end

    test "writes verifiable raw results and refuses a tampered one", %{tmp_dir: dir} do
      Mix.Tasks.AshA2a.Chicago.Bench.run([
        "--only",
        "B5,B9",
        "--iterations",
        "1",
        "--warmup",
        "0",
        "--out",
        dir,
        "--require-measured"
      ])

      summary = JSON.decode!(File.read!(Path.join(dir, "summary.json")))
      assert summary["derived"] == true
      assert Enum.map(summary["results"], & &1["benchmark_id"]) == ["SA2A-B5", "SA2A-B9"]
      assert Enum.all?(summary["results"], &(&1["status"] == "MEASURED"))

      [b5_path] = Path.wildcard(Path.join(dir, "SA2A-B5.*.json"))
      assert [_] = Path.wildcard(Path.join(dir, "SA2A-B9.*.json"))

      Mix.Tasks.AshA2a.Chicago.Bench.run(["--verify", b5_path])
      assert_received {:mix_shell, :info, ["VERIFIED SA2A-B5 " <> _]}

      doc = JSON.decode!(File.read!(b5_path))
      File.write!(b5_path, JSON.encode!(put_in(doc, ["raw_result", "iterations"], 1000)))

      assert_raise Mix.Error, fn ->
        Mix.Tasks.AshA2a.Chicago.Bench.run(["--verify", b5_path])
      end

      assert_received {:mix_shell, :error, ["REFUSED " <> _]}

      assert {:error, {:unknown_benchmarks, ["B42"]}} = Bench.select(["B1", "B42"])
      assert {:ok, [{"B9", B9OcelOverhead}]} = Bench.select(["sa2a-b9"])
    end
  end
end

# --- SECTION 4: Original test/ash_a2a/chicago/brce_gate7_test.exs ---
defmodule AshA2A.Chicago.BrceGate7Test do
  @moduledoc """
  RFC-SA2A-002 Gate 7 (§38), BRCE Court (§68) and Prepared Receipt Court
  (§69): the `CHI-BRCE` court run end to end, plus narrow Chicago tests of the
  sole-DO fence it forced (`AshA2A.BrceAnchor`).

  Real collaborators throughout: the real `AshA2A.CommandBus`,
  `AshA2A.Dispatcher`, `AshA2A.Agent`, `AshA2A.ReceiptOutbox` journal on
  disk, real `AshA2A.ReceiptStore.Memory` processes, real ETS resources read
  back through `Ash.read!/1`, real telemetry, and the durable OCEL artifact
  read by the independent consumer. No Mock/Mox/:meck/patch.

  `async: false` -- the observer attributes every telemetry event emitted
  between a stimulus start and stop to that falsifier, and the court points
  `:receipt_outbox_dir` / `:authority_broker` at real faulted or isolated
  environments for the duration of a stimulus.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  alias AshA2A.{Authority, BrceAnchor, Command, CommandBus, Dispatcher, Identity, Receipt}
  alias AshA2A.{ReceiptOutbox, ReceiptStore}
  alias AshA2A.Chicago
  alias AshA2A.Chicago.{Query, Runner}
  alias AshA2A.Chicago.Courts.Brce
  alias AshA2A.Chicago.Fixtures.Brce, as: Fx
  alias AshA2A.Chicago.Fixtures.Brce.Ledger
  alias AshA2A.Semantic.Refusal

  @moduletag :tmp_dir

  @expected %{
    "CHI-BRCE-001" => :falsifier_killed,
    "CHI-BRCE-002" => :falsifier_killed,
    "CHI-BRCE-003" => :falsifier_killed,
    "CHI-BRCE-004" => :falsifier_killed,
    "CHI-BRCE-005" => :falsifier_killed,
    "CHI-BRCE-006" => :falsifier_killed,
    "CHI-BRCE-007" => :falsifier_killed,
    "CHI-BRCE-008" => :falsifier_killed,
    "CHI-BRCE-009" => :falsifier_killed,
    "CHI-BRCE-010" => :falsifier_killed,
    "CHI-BRCE-011" => :falsifier_killed,
    "CHI-BRCE-012" => :positive_control_passed,
    "CHI-BRCE-013" => :positive_control_passed,
    "CHI-BRCE-014" => :positive_control_passed,
    "CHI-BRCE-015" => :positive_control_passed
  }

  describe "CHI-BRCE end to end over the real SUT" do
    @tag timeout: 300_000
    @tag :graphlaw_engine
    test "every falsifier reaches its verdict and every pass is corroborated by the independent OCEL consumer",
         %{tmp_dir: dir} do
      assert {:ok, run} = Runner.run(courts: [Brce], profile: :do, evidence_dir: dir)

      by_id = Map.new(run.results, &{&1.falsifier_id, &1})
      assert Enum.sort(Map.keys(by_id)) == Enum.sort(Map.keys(@expected))

      for {id, verdict} <- @expected do
        result = by_id[id]
        assert result.verdict == verdict, "#{id}: #{inspect(result, pretty: true)}"
        assert result.attempt_observed? == true, "#{id}: #{inspect(result, pretty: true)}"
        assert result.ocel_corroborated? == true, "#{id}: #{result.ocel_detail}"
      end

      assert run.ocel.dropped == 0

      receipt = JSON.decode!(File.read!(Path.join(dir, "standing_receipt.json")))
      assert Enum.find(receipt["gates"], &(&1["gate"] == 7))["status"] == "PASSED"
      refute receipt["standing"] == "NONCONFORMANT"
    end

    test "the independent consumer answers the Gate 7 questions from the durable artifact alone",
         %{tmp_dir: dir} do
      {:ok, run} = Runner.run(courts: [Brce], profile: :do, evidence_dir: dir)
      assert {:ok, index} = Query.load(Path.join(dir, "ocel.json"), run.ocel.sha256)

      # The direct-dispatch attack reached the dispatcher, which decided to
      # refuse, and nothing actuated.
      assert {true, _} = Query.eval(index, "CHI-BRCE-001", {:observed, "dispatch.start"})

      assert {true, _} =
               Query.eval(
                 index,
                 "CHI-BRCE-001",
                 {:observed, "dispatch.brce_gate", %{"outcome" => "refused"}}
               )

      assert {false, _} = Query.eval(index, "CHI-BRCE-001", {:observed, "dispatch.actuate"})

      # The storage-failure attack: preparation failed, so DO never began.
      assert {true, _} =
               Query.eval(
                 index,
                 "CHI-BRCE-003",
                 {:observed, "brce.prepare", %{"outcome" => "failed"}}
               )

      assert {false, _} = Query.eval(index, "CHI-BRCE-003", {:observed, "brce.actuate.start"})

      # The lawful DO: durable preparation precedes both actuation points on
      # the same command and the same receipt, and commit follows.
      for predicate <- [
            {:precedes, "brce.prepare", "brce.actuate.start", "command"},
            {:precedes, "brce.prepare", "dispatch.actuate", "receipt"},
            {:precedes, "brce.actuate.start", "brce.commit", "command"}
          ] do
        assert {true, _} = Query.eval(index, "CHI-BRCE-012", predicate)
      end
    end
  end

  describe "court declaration (§11, discovery)" do
    test "CHI-BRCE is a discoverable gate 7 SA2A-DO court with fully declared falsifiers" do
      assert Brce in Chicago.courts_for(:do)
      refute Brce in Chicago.courts_for(:plan)
      assert Brce.gate() == 7

      falsifiers = Brce.falsifiers()
      assert Enum.map(falsifiers, & &1.id) == Enum.sort(Map.keys(@expected))

      for f <- falsifiers do
        assert f.court_id == "CHI-BRCE"
        assert f.attempt_predicate != nil, f.id
        assert f.outcome_predicate != nil, f.id
        assert :ok = Query.validate_predicate(f.attempt_predicate)
        assert :ok = Query.validate_predicate(f.outcome_predicate)
      end

      kinds = Enum.frequencies_by(falsifiers, & &1.kind)
      assert kinds == %{negative: 11, positive_control: 4}
    end

    test "the fence's refusal code is classified without editing the Refusal table" do
      assert Refusal.classify(:brce_prepared_receipt_required) == :refused_receipt
    end
  end

  describe "AshA2A.BrceAnchor.admit/2 over real capability-index skills" do
    setup do
      {:ok, record} = AshA2A.Info.skill(Ledger, :record)
      {:ok, transmit} = AshA2A.Info.skill(Ledger, :transmit)
      {:ok, entries} = AshA2A.Info.skill(Ledger, :entries)
      %{record: record, transmit: transmit, entries: entries}
    end

    test ":observe needs no receipt", %{entries: entries} do
      assert {:ok, nil} = BrceAnchor.admit(entries, nil)
    end

    test "consequence-bearing and :unknown skills without an anchor are refused", %{
      record: record,
      transmit: transmit
    } do
      for skill <- [record, transmit, %{record | consequence: :unknown}] do
        assert {:error, %{code: :brce_prepared_receipt_required, reason: :no_prepared_receipt}} =
                 BrceAnchor.admit(skill, nil)
      end
    end

    test "a pending anchor admits only its own capability and consequence class", %{
      record: record,
      transmit: transmit
    } do
      by_id = pending_anchor(record.id, :change)
      by_name = pending_anchor("record", :change)
      # RFC-SA2A-004 §21: admission requires a durable outbox entry.
      :ok = ReceiptOutbox.append(by_id)
      :ok = ReceiptOutbox.append(by_name)

      on_exit(fn ->
        ReceiptOutbox.remove(by_id)
        ReceiptOutbox.remove(by_name)
      end)

      assert {:ok, ^by_id} = BrceAnchor.admit(record, by_id)
      assert {:ok, ^by_name} = BrceAnchor.admit(record, by_name)

      assert {:error, %{reason: :capability_mismatch}} = BrceAnchor.admit(transmit, by_id)

      assert {:error, %{reason: :consequence_mismatch}} =
               BrceAnchor.admit(record, pending_anchor(record.id, :external_do))

      finalized = Receipt.finalize(by_id, {:reply, []})
      assert {:error, %{reason: :anchor_not_pending}} = BrceAnchor.admit(record, finalized)
    end

    test "take/0 is single use" do
      anchor = pending_anchor("record", :change)
      :ok = BrceAnchor.put(anchor)
      assert BrceAnchor.take() == anchor
      assert BrceAnchor.take() == nil
    end
  end

  describe "the fence on the real dispatcher" do
    test "direct dispatch of a :change skill is refused before the Ash action runs" do
      label = "brce-unit-direct-#{System.unique_integer([:positive])}"

      assert {:error, {:brce_gate, %{code: :brce_prepared_receipt_required}}} =
               Dispatcher.dispatch(:record, message(label), Ledger)

      refute label in Fx.ledger_labels()
    end

    test "a durably prepared anchor actuates exactly one dispatch; the next is refused" do
      {:ok, skill} = AshA2A.Info.skill(Ledger, :record)
      label = "brce-unit-anchored-#{System.unique_integer([:positive])}"
      anchor = pending_anchor(skill.id, :change)
      assert :ok = ReceiptOutbox.append(anchor)
      assert ReceiptOutbox.anchored?(anchor)

      :ok = BrceAnchor.put(anchor)
      # consequence-bearing dispatch is admitted only inside the kernel's dispatcher fence
      assert {:reply, _} =
               AshA2A.ConsequenceKernel.Dispatch.DispatcherFence.enter(fn ->
                 Dispatcher.dispatch(:record, message(label), Ledger)
               end)

      assert Enum.count(Fx.ledger_labels(), &(&1 == label)) == 1

      assert {:error, {:brce_gate, %{reason: :no_prepared_receipt}}} =
               Dispatcher.dispatch(:record, message(label), Ledger)

      assert Enum.count(Fx.ledger_labels(), &(&1 == label)) == 1
      :ok = ReceiptOutbox.remove(anchor)
    end

    test "an anchor for one capability cannot actuate another" do
      {:ok, record} = AshA2A.Info.skill(Ledger, :record)
      label = "brce-unit-mismatch-#{System.unique_integer([:positive])}"
      :ok = BrceAnchor.put(pending_anchor(record.id, :change))

      assert {:error, {:brce_gate, %{reason: :capability_mismatch}}} =
               Dispatcher.dispatch(:transmit, message(label), Ledger)

      refute label in Fx.effect_labels()
      assert BrceAnchor.take() == nil
    end

    test "CommandBus anchors its own dispatch and leaves no anchor behind" do
      name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
      start_supervised!({ReceiptStore.Memory, name: name})
      {:ok, skill} = AshA2A.Info.skill(Ledger, :transmit)
      label = "brce-unit-bus-#{System.unique_integer([:positive])}"

      assert {:ok, %Receipt{status: :completed}} =
               CommandBus.run(command(skill.id, label), message(label), Ledger,
                 store_opts: [name: name]
               )

      assert Enum.count(Fx.effect_labels(), &(&1 == label)) == 1
      assert BrceAnchor.take() == nil
    end
  end

  defp principal, do: Identity.principal("brce-gate7-test")

  defp command(capability_id, label) do
    Command.new(capability_id,
      command_id: "brce-gate7-test-" <> Ash.UUIDv7.generate(),
      agent_id: "brce-gate7-test-agent",
      principal_id: principal(),
      authority: Authority.new(principal(), capability_id),
      input: %{"label" => label}
    )
  end

  defp pending_anchor(capability_id, consequence) do
    command = command(capability_id, "anchor")
    Receipt.pending(command, Identity.execution(Ash.UUIDv7.generate()), consequence)
  end

  defp message(label),
    do: AshA2A.Protocol.Message.new_user([AshA2A.Protocol.Part.Data.new(%{"label" => label})])
end

# --- SECTION 5: Original test/ash_a2a/chicago/canonical_identity_projection_test.exs ---
defmodule AshA2A.Chicago.CanonicalIdentityProjectionTest do
  @moduledoc """
  SA2A-CANON, SA2A-NS, SA2A-PROJECTION and SA2A-CANONMUT end to end over the
  real SUT, plus narrow Chicago-style tests for the boundary repairs those
  courts forced: `CanonicalGraph.verify_pin/1` + `RootManifest.load/2`,
  `Iri.resolve/2` steps 3-4, `PlanProjection.verify/2`, `PlanPackage.verify/1`,
  `OntologyCache.manifest/1` and `FalsifierSuite.check_update/2`.

  `async: false`: the observer attributes every telemetry event between a
  stimulus start and stop to that falsifier.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_solo
  alias AshA2A.Chicago.Courts.{
    CanonicalGraphIdentity,
    CanonicalMutation,
    GeneratedProjection,
    PublicSemanticsNamespace
  }

  alias AshA2A.Chicago.Fixtures.CanonicalIdentity, as: F
  alias AshA2A.Chicago.{Result, Runner, StandingReceipt}

  alias AshA2A.Semantic.{
    CanonicalGraph,
    FalsifierSuite,
    Iri,
    OntologyCache,
    PlanPackage,
    PlanProjection,
    Refusal,
    RootManifest,
    TermRegistry
  }

  alias AshA2A.Semantic.RootManifest.ConformanceCorpus

  @moduletag :tmp_dir

  @courts [
    CanonicalGraphIdentity,
    PublicSemanticsNamespace,
    GeneratedProjection,
    CanonicalMutation
  ]

  describe "the courts over the real SUT" do
    @tag timeout: 600_000
    @tag :graphlaw_engine
    test "every falsifier reaches its final verdict and every pass is OCEL-corroborated",
         %{tmp_dir: dir} do
      assert {:ok, run} = Runner.run(courts: @courts, profile: :strict, evidence_dir: dir)

      declared = Enum.flat_map(@courts, & &1.falsifiers())
      by_id = Map.new(run.results, &{&1.falsifier_id, &1})

      assert map_size(by_id) == length(declared) and length(declared) == 51

      mismatches =
        for falsifier <- declared,
            result = Map.fetch!(by_id, falsifier.id),
            expected = expected_verdict(falsifier),
            result.verdict != expected or result.ocel_corroborated? != true or
              not Result.counts_as_pass?(result) do
          "#{falsifier.id}: #{result.verdict} (expected #{expected}) corroborated=#{inspect(result.ocel_corroborated?)} " <>
            "#{inspect(result.detail)} #{inspect(result.ocel_detail)} #{inspect(result.evidence, limit: 12)}"
        end

      assert mismatches == [], Enum.join(mismatches, "\n")

      receipt = JSON.decode!(File.read!(Path.join(dir, "standing_receipt.json")))
      assert :ok = StandingReceipt.verify_digest(receipt)
      assert receipt["results"]["falsifiers_survived"] == 0
      assert receipt["results"]["survived_ids"] == []
      assert receipt["results"]["unresolved_ids"] == []
      assert run.ocel.dropped == 0

      assert by_id["SA2A-PROJECTION-001"].evidence["rederived_ontology_matches"] == true
      assert by_id["SA2A-CANONMUT-004"].evidence["o_star_unchanged"] == true
      assert by_id["SA2A-CANONMUT-003"].evidence["reply"]["injected_admitted"] == false
    end

    test "the four courts are discoverable with their assigned ids, profiles and full declarations" do
      courts = AshA2A.Chicago.courts()

      assert Enum.map(@courts, &{&1.id(), &1.profile()}) == [
               {"SA2A-CANON", :core},
               {"SA2A-NS", :core},
               {"SA2A-PROJECTION", :plan},
               {"SA2A-CANONMUT", :strict}
             ]

      for court <- @courts do
        assert court in courts
        ids = Enum.map(court.falsifiers(), & &1.id)
        assert ids == Enum.uniq(ids)

        for f <- court.falsifiers() do
          assert String.starts_with?(f.id, court.id() <> "-")
          assert f.attempt_predicate != nil and f.outcome_predicate != nil
        end
      end

      refute CanonicalMutation in AshA2A.Chicago.courts_for(:do)
      refute GeneratedProjection in AshA2A.Chicago.courts_for(:logic)
    end

    test "every refusal family has a positive control" do
      for court <- @courts do
        kinds = court.falsifiers() |> Enum.map(& &1.kind) |> Enum.uniq()
        assert :negative in kinds and :positive_control in kinds, court.id()
      end
    end
  end

  describe "canonicalization pin (SA2A-CANON-012..015 repair)" do
    test "the committed Root Manifest pins exactly the executing identity" do
      assert {:ok, manifest} = RootManifest.load(nil, require_engine: false)
      assert :ok = CanonicalGraph.verify_pin(manifest.canonicalization)

      for {key, value} <- CanonicalGraph.identity() do
        assert manifest.canonicalization[key] == value, key
      end

      assert manifest.hash_algorithms["graph_identity"] == CanonicalGraph.hash_function()
    end

    test "every drifted pin is refused with the drifted field named", %{tmp_dir: dir} do
      for drift <- [:algorithm, :hash_function, :implementation] do
        {:ok, path} = F.drifted_manifest(dir, drift)

        assert {:error, %{code: :REFUSED_MANIFEST_CANONICALIZATION_DRIFT, detail: detail}} =
                 RootManifest.load(path, F.manifest_load_opts())

        assert %{code: :refused_canonicalization_pin_drift, field: field} = detail
        assert is_binary(field)
      end

      pinned = CanonicalGraph.identity()

      assert {:error, %{code: :refused_canonicalization_pin_drift, field: "library"}} =
               CanonicalGraph.verify_pin(Map.delete(pinned, "library"))

      assert {:error, %{code: :refused_canonicalization_pin_drift}} =
               CanonicalGraph.verify_pin(:not_a_pin)
    end

    @tag :graphlaw_engine
    test "the committed manifest is still reproduced by its lawful manufacturer" do
      {:ok, rebuilt} = ConformanceCorpus.build()
      committed = ConformanceCorpus.manifest_path() |> File.read!() |> JSON.decode!()
      assert rebuilt.digest == committed["digest"]
    end
  end

  describe "namespace repairs (SA2A-NS-003..006)" do
    setup do
      {:ok, index} = TermRegistry.from_cache()
      %{index: index}
    end

    test "a textual equivalent is a candidate, not an identity", %{index: index} do
      assert {:error, %{code: :equivalent_requires_admitted_mapping, detail: detail}} =
               Iri.resolve("customer class", index: index)

      assert detail =~ "http://www.w3.org/2000/01/rdf-schema#Class"
    end

    test "a mapping without a receipt does not select an equivalent", %{index: index} do
      [target | _] = TermRegistry.search_equivalent(index, "Concept")

      assert {:error, %{code: :equivalent_requires_admitted_mapping}} =
               Iri.resolve("Concept",
                 index: index,
                 sufficient?: false,
                 mappings: [%{target: target, kind: :close_match}]
               )
    end

    test "composition refuses a mapping lacking an admission receipt", %{index: index} do
      assert {:error, %{code: :composition_mapping_unadmitted}} =
               Iri.resolve("Concept",
                 index: index,
                 sufficient?: false,
                 accept_equivalent?: false,
                 composition: [F.skos_concept(), F.owl_class()],
                 mappings: [
                   %{
                     target: F.skos_concept(),
                     kind: :exact_match,
                     admission_receipt: F.receipt("a")
                   },
                   %{target: F.owl_class(), kind: :close_match}
                 ]
               )
    end
  end

  describe "projection repairs (SA2A-PROJECTION-002, 003, 006)" do
    test "graph witness refuses content the graph does not carry, per field" do
      {_ir, ontology, _planning, projection} = F.admitted_chain()

      for {field, value} <- [
            goals: ["forged goal"],
            constraints: ["forged constraint"],
            task_candidates: [],
            nondeterminism: projection.nondeterminism ++ projection.nondeterminism,
            exclusions: ["no phase may be skipped", "forged"],
            objects: [%{"id" => "room", "type" => "schema:Person", "label" => "the room"}],
            predicates: [
              %{"subject" => "room", "predicate" => "schema:agent", "object" => "facilitator"}
            ]
          ] do
        forged = Map.put(projection, field, value)
        forged = %{forged | projection_digest: PlanProjection.content_digest(forged)}

        assert {:error, %{code: :projection_not_witnessed_by_graph, detail: %{field: ^field}}} =
                 PlanProjection.verify(forged, ontology),
               "#{field} forgery verified"
      end
    end

    test "a forged fence is refused by verify/2 and verify_self/1" do
      {_ir, ontology, _planning, projection} = F.admitted_chain()

      for forged <- [%{projection | standing: :admitted}, %{projection | authority: :full}] do
        assert {:error, %{code: :projection_manual_edit_not_canonical}} =
                 PlanProjection.verify(forged, ontology)

        assert {:error, %{code: :projection_manual_edit_not_canonical}} =
                 PlanProjection.verify_self(forged)
      end
    end

    test "a re-digested package with a forged fence is refused" do
      {_ir, _ontology, _planning, projection} = F.admitted_chain()
      {:ok, package} = PlanPackage.from_projection(projection, "hddl_cli", F.package_opts())

      assert {:error, %{code: :plan_package_manual_edit_not_canonical}} =
               PlanPackage.verify(F.forged_package(package))

      assert {:ok, ^package} = PlanPackage.verify(package)
    end
  end

  describe "canonical mutation repairs (SA2A-CANONMUT-002, 008)" do
    test "a rewritten cache manifest is not admitted, an unmodified copy is", %{tmp_dir: dir} do
      forged = F.copy_ontology_cache(dir, "forged")
      :ok = F.direct_write(forged, consistent: true)

      assert {:error, %{code: :ontology_manifest_unadmitted}} = OntologyCache.manifest(forged)

      assert {:error, %{code: :ontology_manifest_unadmitted}} =
               OntologyCache.load(F.skos_ns(), root: forged)

      untouched = F.copy_ontology_cache(dir, "untouched")
      assert {:ok, entries} = OntologyCache.manifest(untouched)
      assert length(entries) == 4
    end

    test "canonical classification wins over staging" do
      graph = F.ambiguous_classification()

      assert {:error, %{code: :refused_sparql_update_on_canonical, detail: detail}} =
               FalsifierSuite.check_update(graph, F.update(:ambiguous))

      assert detail.reason =~ "canonical"
      assert :ok = FalsifierSuite.check_update(graph, F.update(:staging))
    end
  end

  test "every new refusal code is classified without editing the Refusal table" do
    for module <- [CanonicalGraph, Iri, PlanProjection, OntologyCache],
        {code, class} <- module.__sa2a_refusal_codes__() do
      assert Refusal.classify(code) == class
    end
  end

  defp expected_verdict(%{kind: :negative}), do: :falsifier_killed
  defp expected_verdict(%{kind: :positive_control}), do: :positive_control_passed
end

# --- SECTION 6: Original test/ash_a2a/chicago/crash_reconciliation_test.exs ---
defmodule AshA2A.Chicago.CrashReconciliationTest do
  @moduledoc """
  Qualifies the `SA2A-CHAOS` court (RFC-SA2A-002 §70, §71, §94, §96) and the
  modules it introduces, Chicago style: real `AshA2A.CommandBus`, real
  on-disk EKV receipt store killed and restarted, real filesystem receipt
  outbox, real Ash ETS external ledger, real `AshA2A.ReceiptStore.Memory`,
  real telemetry, and a durable OCEL artifact read back by the independent
  consumer. No component on the path is replaced by a double.

  `async: false` -- the observer attributes every telemetry event emitted
  between a stimulus start and stop to that falsifier, and these tests point
  the global `:receipt_outbox_dir` at private directories.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  alias AshA2A.{Command, CommandBus, Identity, Receipt, ReceiptOutbox, Reconciliation}
  alias AshA2A.Chicago.Courts.CrashReconciliation
  alias AshA2A.Chicago.Fixtures.ChaosReconciliation.Environment, as: Env
  alias AshA2A.Chicago.Runner
  alias AshA2A.ReceiptStore.Memory

  @moduletag :tmp_dir
  @moduletag capture_log: true
  @moduletag timeout: 600_000

  @expected %{
    "SA2A-CHAOS-001" => :falsifier_killed,
    "SA2A-CHAOS-002" => :falsifier_killed,
    "SA2A-CHAOS-003" => :falsifier_killed,
    "SA2A-CHAOS-004" => :falsifier_killed,
    "SA2A-CHAOS-005" => :falsifier_killed,
    "SA2A-CHAOS-006" => :falsifier_killed,
    "SA2A-CHAOS-007" => :falsifier_killed,
    "SA2A-CHAOS-008" => :falsifier_killed,
    "SA2A-CHAOS-009" => :falsifier_killed,
    "SA2A-CHAOS-010" => :falsifier_killed,
    "SA2A-CHAOS-011" => :falsifier_killed,
    "SA2A-CHAOS-012" => :falsifier_killed,
    "SA2A-CHAOS-013" => :falsifier_killed,
    "SA2A-CHAOS-014" => :positive_control_passed,
    "SA2A-CHAOS-015" => :positive_control_passed,
    "SA2A-CHAOS-016" => :positive_control_passed,
    "SA2A-CHAOS-017" => :positive_control_passed,
    "SA2A-CHAOS-018" => :measured,
    "SA2A-CHAOS-019" => :falsifier_killed,
    "SA2A-CHAOS-020" => :falsifier_killed
  }

  describe "the SA2A-CHAOS court over the real SUT" do
    test "every falsifier reaches its verdict and every pass is corroborated by the independent OCEL consumer",
         %{tmp_dir: dir} do
      assert {:ok, run} =
               Runner.run(courts: [CrashReconciliation], profile: :do, evidence_dir: dir)

      by_id = Map.new(run.results, &{&1.falsifier_id, &1})
      assert Map.keys(by_id) |> Enum.sort() == Map.keys(@expected) |> Enum.sort()

      for {id, verdict} <- @expected do
        result = by_id[id]

        assert result.verdict == verdict,
               "#{id}: expected #{verdict}, got #{result.verdict} -- " <>
                 "#{inspect(result.detail)} / #{inspect(result.ocel_detail)}"

        assert result.ocel_corroborated? == true, "#{id}: #{inspect(result.ocel_detail)}"
      end

      assert run.ocel.dropped == 0

      receipt = JSON.decode!(File.read!(Path.join(dir, "standing_receipt.json")))
      assert receipt["results"]["falsifiers_killed"] == 15
      assert receipt["results"]["falsifiers_survived"] == 0
      assert receipt["results"]["positive_controls_passed"] == 4
      assert receipt["results"]["measured"] == 1
      assert receipt["results"]["unresolved_ids"] == []

      # SA2A-B10: every crash point reached, zero repeated external effects,
      # the six-state vocabulary actually exercised.
      b10 = by_id["SA2A-CHAOS-018"].measurements
      assert b10["crash_points_reached"] == 5
      assert b10["repeated_external_effects_total"] == 0

      assert Enum.map(b10["points"], & &1["prepared_receipt_state"]["classification"]) == [
               :not_attempted,
               :prepared_unknown_outcome,
               :prepared_unknown_outcome,
               :prepared_unknown_outcome,
               :executed
             ]

      assert Enum.map(b10["points"], & &1["reconciliation_result"]["resolved_as"]) == [
               nil,
               :not_executed,
               :executed,
               :executed,
               nil
             ]
    end
  end

  describe "AshA2A.Reconciliation over a real Memory store and a real outbox" do
    setup %{tmp_dir: dir} do
      previous = Application.get_env(:ash_a2a, :receipt_outbox_dir)
      outbox = Path.join(dir, "outbox")
      Application.put_env(:ash_a2a, :receipt_outbox_dir, outbox)
      on_exit(fn -> Application.put_env(:ash_a2a, :receipt_outbox_dir, previous) end)

      name = :"reconciliation_test_store_#{System.unique_integer([:positive])}"
      start_supervised!({Memory, name: name})
      %{store_opts: [name: name], outbox: outbox}
    end

    test "no evidence is not_attempted; an unreadable journal entry forbids it", %{
      store_opts: opts,
      outbox: outbox
    } do
      cid = Identity.command("never-#{System.unique_integer([:positive])}")

      assert {:ok, %{state: :not_attempted, source: :none}} =
               Reconciliation.classify(cid, Memory, opts)

      File.mkdir_p!(outbox)
      File.write!(Path.join(outbox, "runtime:torn.receipt"), <<131, 104>>)

      assert {:ok, %{state: :prepared_unknown_outcome, unreadable_outbox_entries: 1}} =
               Reconciliation.classify(cid, Memory, opts)
    end

    test "a pending anchor is prepared_unknown_outcome and a probe resolves it; :unknown leaves it",
         %{store_opts: opts} do
      {command, anchor} = claimed_anchor(opts)
      :ok = ReceiptOutbox.append(anchor)

      assert {:ok, %{state: :prepared_unknown_outcome, source: :outbox}} =
               Reconciliation.classify(command.command_id, Memory, opts)

      assert {:ok, %{outcome: :unresolved, after: %{state: :prepared_unknown_outcome}}} =
               Reconciliation.reconcile(command.command_id, Memory, opts,
                 probe: fn _ -> :unknown end
               )

      assert {:ok, %{outcome: :resolved, after: after_c}} =
               Reconciliation.reconcile(command.command_id, Memory, opts,
                 probe: fn _ -> {:executed, %{"seen" => 1}} end
               )

      assert %{state: :reconciled, resolved_as: :executed, source: :primary} = after_c
      assert after_c.receipt.receipt_id == anchor.receipt_id

      # Reconciliation is idempotent: a reconciled receipt is never re-resolved.
      assert {:ok, %{outcome: :unchanged, after: %{state: :reconciled}}} =
               Reconciliation.reconcile(command.command_id, Memory, opts,
                 probe: fn _ -> {:not_executed, %{}} end
               )
    end

    test "a finalized outboxed receipt outranks the pending anchor already in the primary store",
         %{store_opts: opts} do
      {command, anchor} = claimed_anchor(opts)
      :ok = Memory.commit(anchor, opts)
      finalized = Receipt.finalize(anchor, {:reply, []})
      :ok = ReceiptOutbox.append(finalized)

      assert {:ok, %{state: :executed, source: :outbox, durable_in_primary?: false}} =
               Reconciliation.classify(command.command_id, Memory, opts)
    end

    test "an unavailable primary store is an error, never a guessed state", %{store_opts: opts} do
      {command, _anchor} = claimed_anchor(opts)
      stop_supervised!(Memory)

      assert {:error, :receipt_store_unavailable} =
               Reconciliation.classify(command.command_id, Memory, opts)
    end

    test "only an executed consequence can be compensated", %{store_opts: opts} do
      {command, anchor} = claimed_anchor(opts)
      :ok = Memory.commit(anchor, opts)

      assert {:error, %{code: :compensation_not_applicable}} =
               Reconciliation.compensate(command.command_id, Memory, opts, fn _ ->
                 send(self(), :compensation_ran)
                 {:error, %{code: :must_not_run}}
               end)

      refute_received :compensation_ran

      :ok = Memory.commit(Receipt.finalize(anchor, {:reply, []}), opts)

      assert {:error, %{code: :compensation_unconfirmed}} =
               Reconciliation.compensate(command.command_id, Memory, opts, fn _ ->
                 {:error, %{code: :dispatch_crashed}}
               end)

      assert {:ok, %{state: :executed}} =
               Reconciliation.classify(command.command_id, Memory, opts)

      assert AshA2A.Chicago.refusal_codes()[:compensation_not_applicable] == :refused_consequence
    end
  end

  describe "ReceiptOutbox.reconcile finalized-supersedes-pending guard (SA2A-CHAOS-012 repair)" do
    setup %{tmp_dir: dir} do
      previous = Application.get_env(:ash_a2a, :receipt_outbox_dir)
      Application.put_env(:ash_a2a, :receipt_outbox_dir, Path.join(dir, "outbox"))
      on_exit(fn -> Application.put_env(:ash_a2a, :receipt_outbox_dir, previous) end)

      name = :"supersede_test_store_#{System.unique_integer([:positive])}"
      start_supervised!({Memory, name: name})
      %{store_opts: [name: name]}
    end

    test "a finalized entry replaces its own drained pending anchor", %{store_opts: opts} do
      {command, anchor} = claimed_anchor(opts)
      :ok = Memory.commit(anchor, opts)
      :ok = ReceiptOutbox.append(Receipt.finalize(anchor, {:reply, []}))

      assert {:ok, %{committed: 1, remaining: 0}} =
               CommandBus.reconcile_outboxed_receipts(Memory, opts)

      assert {:ok, %Receipt{status: :completed}} = Memory.fetch(command.command_id, opts)
      assert ReceiptOutbox.count() == 0
    end

    test "a stale pending entry never downgrades a finalized stored receipt", %{store_opts: opts} do
      {command, anchor} = claimed_anchor(opts)
      :ok = Memory.commit(Receipt.finalize(anchor, {:reply, []}), opts)
      :ok = ReceiptOutbox.append(anchor)

      assert {:ok, %{committed: 0, remaining: 0}} =
               CommandBus.reconcile_outboxed_receipts(Memory, opts)

      assert {:ok, %Receipt{status: :completed}} = Memory.fetch(command.command_id, opts)
    end
  end

  describe "fault-injection environment" do
    test "telemetry dispatches in attach order and an EKV crash/restart keeps what reached disk",
         %{tmp_dir: dir} do
      assert Env.attach_ordered?()

      env = Env.open(dir)

      try do
        opts = Env.store_opts(env)
        command = Env.command("env-restart-#{System.unique_integer([:positive])}", %{})
        assert {:execute, _} = Env.store().claim(command, opts)

        Env.crash_store(env)
        refute Env.store_alive?(env)
        assert %{primary: :unavailable} = Env.raw_evidence(env, command.command_id.value)

        Env.restart_store(env)
        assert Env.store_alive?(env)
        assert %{primary: :claimed} = Env.raw_evidence(env, command.command_id.value)
        assert {:error, :in_flight} = Env.store().claim(command, opts)
      after
        Env.close(env)
      end
    end
  end

  describe "ReceiptStore.Memory claim lease reclaim (closes the SA2A-CHAOS liveness gap)" do
    setup do
      previous = Application.get_env(:ash_a2a, :claim_lease_ms)

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:ash_a2a, :claim_lease_ms)
          value -> Application.put_env(:ash_a2a, :claim_lease_ms, value)
        end
      end)

      :ok
    end

    test "an abandoned claim (no outbox anchor) is reclaimable once the lease elapses" do
      Application.put_env(:ash_a2a, :claim_lease_ms, 20)
      name = :"claim_lease_memory_#{System.unique_integer([:positive])}"
      start_supervised!({Memory, name: name})
      opts = [name: name]
      command = unit_command("lease-memory")

      assert {:execute, first_execution_id} = Memory.claim(command, opts)
      assert {:error, :in_flight} = Memory.claim(command, opts)

      # SLEEP-CLASS: REAL-INTERVAL (audited AshA2A.TestSupport.Eventually.pause)
      AshA2A.TestSupport.Eventually.pause(60)

      assert {:execute, second_execution_id} = Memory.claim(command, opts)
      assert second_execution_id != first_execution_id

      # The reclaimed execution commits normally, and the command id then
      # replays -- reclaim behaves exactly like a fresh claim from here on.
      receipt = Receipt.from_reply(command, second_execution_id, :external_do, {:reply, []}, [])
      :ok = Memory.commit(receipt, opts)
      assert {:replay, %Receipt{replayed?: true}} = Memory.claim(command, opts)
    end

    test "a claim that reached receipt preparation is never reclaimed, no matter how long the lease has passed",
         %{tmp_dir: dir} do
      Application.put_env(:ash_a2a, :claim_lease_ms, 20)
      previous_outbox = Application.get_env(:ash_a2a, :receipt_outbox_dir)
      Application.put_env(:ash_a2a, :receipt_outbox_dir, Path.join(dir, "lease_anchor_outbox"))

      on_exit(fn ->
        case previous_outbox do
          nil -> Application.delete_env(:ash_a2a, :receipt_outbox_dir)
          value -> Application.put_env(:ash_a2a, :receipt_outbox_dir, value)
        end
      end)

      name = :"claim_lease_anchored_memory_#{System.unique_integer([:positive])}"
      start_supervised!({Memory, name: name})
      opts = [name: name]
      command = unit_command("lease-anchored")

      assert {:execute, execution_id} = Memory.claim(command, opts)
      anchor = Receipt.pending(command, execution_id, :external_do)
      :ok = ReceiptOutbox.append(anchor)

      # SLEEP-CLASS: REAL-INTERVAL (audited AshA2A.TestSupport.Eventually.pause)
      AshA2A.TestSupport.Eventually.pause(60)

      # Well past the lease, but a pending anchor exists: this claim may
      # already have actuated, so it must stay in_flight -- the lease alone
      # never reclaims it.
      assert {:error, :in_flight} = Memory.claim(command, opts)
    end
  end

  defp unit_command(prefix) do
    Command.new("AshA2A.Chicago.Fixtures.ChaosReconciliation.Effect.apply_effect",
      command_id: "#{prefix}-#{System.unique_integer([:positive])}",
      agent_id: "unit-agent",
      principal_id: "unit-principal",
      input: %{}
    )
  end

  defp claimed_anchor(opts) do
    command =
      Command.new("AshA2A.Chicago.Fixtures.ChaosReconciliation.Effect.apply_effect",
        command_id: "reconciliation-unit-#{System.unique_integer([:positive])}",
        agent_id: "unit-agent",
        principal_id: "unit-principal",
        input: %{}
      )

    {:execute, execution_id} = Memory.claim(command, opts)
    {command, Receipt.pending(command, execution_id, :external_do)}
  end
end

# --- SECTION 7: Original test/ash_a2a/chicago/cross_runtime_portability_test.exs ---
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

  @moduletag :serial
  @moduletag :serial_shard
  alias AshA2A.Chicago.{Query, Runner}
  alias AshA2A.Chicago.Courts.CrossRuntimePortability, as: Court
  alias AshA2A.Chicago.Fixtures.CrossRuntime, as: Fx
  alias AshA2A.GraphLaw.{RuntimeB, WasmexSession, WasmtimeRuntime}
  alias AshA2A.RuntimeIdentity.Execution
  alias AshA2A.SA2A.{Conformance, StateMachine}

  @moduletag :tmp_dir

  # A caller-named foreign wasm path resolves to `:unpinned`, which the host
  # admits only under runtime opt-in (EngineLoad.check_digest/2).
  setup do
    previous = Application.fetch_env(:ash_a2a, :graphlaw_allow_unpinned)
    Application.put_env(:ash_a2a, :graphlaw_allow_unpinned, true)

    on_exit(fn ->
      case previous do
        {:ok, v} -> Application.put_env(:ash_a2a, :graphlaw_allow_unpinned, v)
        :error -> Application.delete_env(:ash_a2a, :graphlaw_allow_unpinned)
      end
    end)

    :ok
  end

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

# --- SECTION 8: Original test/ash_a2a/chicago/crown_test.exs ---
defmodule AshA2A.Chicago.CrownTest do
  @moduledoc """
  RFC-SA2A-002 Chicago Crown assembly (`AshA2A.Chicago.Crown`), Chicago
  style: every assertion below is over real discovered court modules, a real
  `AshA2A.Chicago.Runner.run/1` execution, and the real, currently-executable
  `AshA2A.Semantic.Conformance.requirement_results/0` -- no mocked court, no
  hand-typed fake receipt.

  `async: false`: shares the observer-attribution discipline of the other
  Chicago test files that drive a real `AshA2A.Chicago.Runner.run/1`.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  alias AshA2A.Chicago

  alias AshA2A.Chicago.Courts.{
    CanonicalGraphIdentity,
    CanonicalMutation,
    ExactIdentity,
    ExecutableWorld,
    GeneratedProjection,
    PublicSemanticsNamespace,
    RealCollaborators
  }

  alias AshA2A.Chicago.{CourtManifest, Crown, Runner}
  alias AshA2A.Semantic.Conformance

  @moduletag :tmp_dir

  # The same real, currently-passing court set as
  # `AshA2A.Chicago.CanonicalIdentityProjectionTest` (51 falsifiers, ~2s):
  # reused here rather than re-run, so the marginal cost of this file is only
  # the Crown assertions layered on top of one real run.
  @projection_courts [
    CanonicalGraphIdentity,
    PublicSemanticsNamespace,
    GeneratedProjection,
    CanonicalMutation
  ]

  describe "§98 mandatory-corpus registry, over the full discovered corpus" do
    test "every one of the fourteen mandatory members resolves to a real declared falsifier" do
      coverage = Crown.mandatory_corpus_coverage()

      assert length(coverage) == 14

      assert Enum.all?(coverage, & &1["resolved"]),
             inspect(Enum.reject(coverage, & &1["resolved"]))

      assert Crown.mandatory_corpus_gaps() == []
    end
  end

  describe "§98 mandatory-corpus registry, over a real restricted court subset" do
    test "a court subset that only implements 3 of the 14 members surfaces exactly those real gaps" do
      courts = [CanonicalGraphIdentity, CanonicalMutation]
      coverage = Crown.mandatory_corpus_coverage(courts)
      gaps = Crown.mandatory_corpus_gaps(courts)

      resolved_ids =
        coverage |> Enum.filter(& &1["resolved"]) |> Enum.map(& &1["id"]) |> Enum.sort()

      assert resolved_ids ==
               Enum.sort([
                 "semantic_artifact_lacking_canonical_identity",
                 "projection_attempting_to_become_canonical_source",
                 "llm_output_marked_directly_as_admitted"
               ])

      assert length(gaps) == 11
      gap_ids = Enum.map(gaps, & &1["id"])
      refute "semantic_artifact_lacking_canonical_identity" in gap_ids
      assert "consequence_without_authority_requirement" in gap_ids
    end
  end

  describe "§31 gate coverage" do
    test "the full discovered corpus leaves no required Strict gate uncovered" do
      coverage = Crown.gate_coverage(:strict)

      assert length(coverage) == 12
      assert Enum.all?(coverage, & &1["required"])
      refute Enum.any?(coverage, &(&1["status"] == "NO_COURT")), inspect(coverage)
      assert Enum.find(coverage, &(&1["gate"] == 1))["title"] == "Exact Identity Fenced"
      assert Enum.find(coverage, &(&1["gate"] == 7))["title"] =~ "Sole DO Boundary"
    end

    test "a narrow real court subset shows a real NO_COURT gap for gates it does not cover" do
      coverage = Crown.gate_coverage(:strict, [CanonicalGraphIdentity])
      gate1 = Enum.find(coverage, &(&1["gate"] == 1))

      assert gate1["status"] == "NO_COURT"
      assert gate1["court_ids"] == []
    end
  end

  describe "§145 compliance matrix, §114 package completeness and Appendix C, over a real run" do
    @tag timeout: 600_000
    test "the compliance matrix maps a real RFC-SA2A-001 requirement to real courts, falsifiers and results",
         %{tmp_dir: dir} do
      assert {:ok, %{run: run, crown: crown}} =
               Crown.run(courts: @projection_courts, profile: :strict, evidence_dir: dir)

      matrix = crown["compliance_matrix"]

      assert length(matrix) == length(Conformance.requirement_results())

      # A requirement whose RFC-SA2A-001 section token (S12) is really shared
      # by SA2A-CANON's declared `rfc_sections/0`: every one of its falsifiers
      # really ran and really passed in this run (Chicago style: the pass
      # this asserts on is the pre-existing, independently-passing
      # `CanonicalIdentityProjectionTest` baseline, not a value this test
      # invents).
      row = Enum.find(matrix, &(&1["requirement_id"] == "canonical_graph_identity"))
      assert row["rfc_section"] == "S59/S12"
      assert "SA2A-CANON" in row["court_ids"]
      assert row["falsifier_ids"] != []
      assert row["result"] == "PASSED"
      assert row["exact_subject"] == get_in(run.receipt, ["subject", "identity"])
      assert row["evidence_artifact"] != nil

      # A requirement whose RFC-SA2A-001 section (S20) none of these 4
      # courts' real `rfc_sections/0` declare: a real, mechanically-detected
      # §145 open evidence gap, never silently dropped.
      no_court = Enum.find(matrix, &(&1["requirement_id"] == "safe_finite_datalog"))
      assert no_court["result"] == "NO_COURT"
      assert no_court["court_ids"] == []
      assert no_court["requirement_id"] in crown["compliance_matrix_open_gaps"]

      # §98: this 4-court set resolves exactly 3 of the 14 mandatory members
      # (SA2A-CANON-008, SA2A-CANONMUT-004, SA2A-CANONMUT-006) -- 11 real gaps.
      mandatory = crown["mandatory_corpus"]
      refute mandatory["complete?"]
      assert length(mandatory["gaps"]) == 11

      # §114: every artifact this run really produces is really reported present.
      completeness = crown["package_completeness"]

      present_names =
        completeness["artifacts"] |> Enum.filter(& &1["present"]) |> Enum.map(& &1["artifact"])

      for name <- [
            "exact-subject manifest",
            "OCEL 2.0 artifact",
            "OCEL validation receipt",
            "conformance-query results",
            "raw durable receipts",
            "final standing receipt"
          ] do
        assert name in present_names,
               "expected #{inspect(name)} present in #{inspect(present_names)}"
      end

      # An artifact this run genuinely does not track is reported absent, not fabricated.
      assert "commands and exit codes" in completeness["missing"]

      # Appendix C, answered mechanically by the real FreshConsumer, not reimplemented here.
      assert crown["fresh_consumer_outcome"] in ["reproduced", "diverged", "refused"]

      assert map_size(crown["evidence_questions"]) ==
               length(AshA2A.Chicago.FreshConsumer.questions())

      # crown.json is really written, and really hashes to its own digest.
      crown_path = Path.join(dir, "crown.json")
      assert File.exists?(crown_path)
      on_disk = JSON.decode!(File.read!(crown_path))
      assert on_disk["crown_digest"] == crown["crown_digest"]
      assert Crown.digest(on_disk) == on_disk["crown_digest"]
    end
  end

  describe "§98/§146 a mandatory-corpus gap blocks a Strict crown claim, never silently upgraded" do
    @tag :graphlaw_engine
    test "a real SA2A-CORE CONFORMANT run is reported PARTIAL_ALIVE, never CONFORMANT, when claimed Strict",
         %{tmp_dir: dir} do
      courts = [ExactIdentity, ExecutableWorld, RealCollaborators]
      # Self-admitted for this exact court set so §137 court-manifest drift
      # against the committed, possibly-stale `chicago_court_manifest.json`
      # cannot itself explain the standing this test asserts on.
      manifest = CourtManifest.build(courts)

      assert {:ok, run} =
               Runner.run(
                 profile: :core,
                 courts: courts,
                 evidence_dir: dir,
                 court_manifest: manifest
               )

      assert run.receipt["standing"] == "CONFORMANT"

      # Reporting honestly for the profile this run actually qualified is
      # never downgraded: the crown claim equals the run's own standing.
      honest = Crown.build(run)
      assert honest["standing"] == "CONFORMANT"
      assert honest["mandatory_corpus"]["gaps"] != []

      # The exact same real evidence, claimed Strict instead: none of these
      # three courts (gates 1-3 only) resolve any of the fourteen §98
      # mandatory members, so the Strict claim MUST NOT read CONFORMANT.
      over_claimed = Crown.build(%{run | profile: :strict})

      assert over_claimed["standing"] == "PARTIAL_ALIVE"
      assert over_claimed["claim"] =~ "mandatory RFC-SA2A-001 falsifier corpus"
      assert length(over_claimed["mandatory_corpus"]["gaps"]) == 14
      refute over_claimed["mandatory_corpus"]["complete?"]
    end
  end

  describe "discovery" do
    test "the crown module itself never registers as a discoverable court" do
      refute Crown in Chicago.courts()
    end
  end
end

# --- SECTION 9: Original test/ash_a2a/chicago/envelope_negotiation_transport_test.exs ---
defmodule AshA2A.Chicago.EnvelopeNegotiationTransportTest do
  @moduledoc """
  RFC-SA2A-002 §54/§55/§56/§75 courts, end to end: a real
  `AshA2A.Chicago.Runner` run over the real `SA2A-ENV`, `SA2A-NEG` and
  `SA2A-TRANSPORT` courts (real Peer in real AshA2A.Protocol.Agent GenServers, real
  praxis-graphlaw wasm, real AshA2A.Protocol.Plug on a real Bandit listener, real
  CommandBus over a real ETS resource, real authority broker), a durable
  OCEL artifact on disk, and the independent consumer's corroboration.

  `async: false` -- the observer attributes every telemetry event emitted
  between a stimulus start and stop to that falsifier.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  alias AshA2A.Chicago
  alias AshA2A.Chicago.{Court, Falsifier, Query, Runner}

  alias AshA2A.Chicago.Courts.{
    ExtensionNegotiation,
    SemanticBoundary,
    SemanticEnvelope,
    TransportIndependence
  }

  alias AshA2A.Chicago.Ocel.Mapping
  alias AshA2A.Semantic.{Extension, Peer, Refusal}

  @moduletag :tmp_dir
  @moduletag timeout: 300_000

  @courts [SemanticEnvelope, ExtensionNegotiation, TransportIndependence]

  @expected %{
    "SA2A-ENV-001" => :falsifier_killed,
    "SA2A-ENV-002" => :falsifier_killed,
    "SA2A-ENV-003" => :falsifier_killed,
    "SA2A-ENV-004" => :falsifier_killed,
    "SA2A-ENV-005" => :falsifier_killed,
    "SA2A-ENV-006" => :falsifier_killed,
    "SA2A-ENV-007" => :positive_control_passed,
    "SA2A-ENV-008" => :falsifier_killed,
    "SA2A-ENV-009" => :falsifier_killed,
    "SA2A-ENV-010" => :falsifier_killed,
    "SA2A-ENV-011" => :falsifier_killed,
    "SA2A-ENV-012" => :falsifier_killed,
    "SA2A-ENV-013" => :positive_control_passed,
    "SA2A-ENV-014" => :positive_control_passed,
    "SA2A-NEG-001" => :falsifier_killed,
    "SA2A-NEG-002" => :falsifier_killed,
    "SA2A-NEG-003" => :falsifier_killed,
    "SA2A-NEG-004" => :falsifier_killed,
    "SA2A-NEG-005" => :falsifier_killed,
    "SA2A-NEG-006" => :falsifier_killed,
    "SA2A-NEG-007" => :falsifier_killed,
    "SA2A-NEG-008" => :positive_control_passed,
    "SA2A-NEG-009" => :positive_control_passed,
    "SA2A-TRANSPORT-001" => :positive_control_passed,
    "SA2A-TRANSPORT-002" => :falsifier_killed,
    "SA2A-TRANSPORT-003" => :falsifier_killed,
    "SA2A-TRANSPORT-004" => :falsifier_killed,
    "SA2A-TRANSPORT-005" => :positive_control_passed
  }

  describe "a real run of the three courts" do
    @tag :graphlaw_engine
    test "every falsifier reaches its final verdict and every pass is OCEL-corroborated", %{
      tmp_dir: dir
    } do
      assert {:ok, run} = Runner.run(courts: @courts, profile: :core, evidence_dir: dir)

      verdicts = Map.new(run.results, &{&1.falsifier_id, &1.verdict})

      assert verdicts == @expected,
             "verdicts differ:\n" <>
               Enum.map_join(run.results, "\n", fn r ->
                 "#{r.falsifier_id} #{r.verdict} corroborated=#{inspect(r.ocel_corroborated?)} " <>
                   "detail=#{inspect(r.detail)} ocel=#{inspect(r.ocel_detail)} " <>
                   "evidence=#{inspect(r.evidence, limit: 30, printable_limit: 400)}"
               end)

      for result <- run.results do
        assert result.attempt_observed? == true, "#{result.falsifier_id}: attempt not observed"

        assert result.ocel_corroborated? == true,
               "#{result.falsifier_id}: #{inspect(result.ocel_detail)}"

        assert Chicago.Result.counts_as_pass?(result)
      end

      assert run.ocel.dropped == 0
      assert {:ok, _index} = Query.load(Path.join(dir, "ocel.json"), run.ocel.sha256)
    end
  end

  describe "court declarations" do
    test "the three courts are discoverable :core courts with §11-complete falsifiers" do
      discovered = Chicago.courts()

      for court <- @courts do
        assert Court.discoverable?(court)
        assert court in discovered
        assert court.profile() == :core

        for %Falsifier{} = f <- court.falsifiers() do
          assert String.starts_with?(f.id, court.id() <> "-")
          assert f.attempt_predicate, "#{f.id} has no attempt predicate"
          assert f.outcome_predicate, "#{f.id} has no outcome predicate"
        end
      end

      ids = Enum.flat_map(@courts, fn c -> Enum.map(c.falsifiers(), & &1.id) end)
      assert Enum.sort(ids) == Enum.sort(Map.keys(@expected))
    end

    test "each court admits its own court-scoped mapping of the peer boundary events" do
      for {court, prefix} <- [
            {SemanticEnvelope, "sa2a.env"},
            {ExtensionNegotiation, "sa2a.neg"},
            {TransportIndependence, "sa2a.transport"}
          ] do
        activities = Enum.map(court.ocel_mappings(), & &1.activity)
        assert (prefix <> ".decision") in activities
        assert Enum.all?(court.ocel_mappings(), &(&1.source == court))
      end
    end
  end

  describe "SemanticBoundary.outcome_id/1" do
    test "is equal for equal decisions and differs when any semantic field differs" do
      base = %{envelope_id: "urn:uuid:1", standing: :admitted, code: nil, graph_digest: "abc"}

      assert SemanticBoundary.outcome_id(base) ==
               SemanticBoundary.outcome_id(Map.put(base, :peer, "other-peer"))

      for {k, v} <- [envelope_id: "urn:uuid:2", standing: :refused, code: :x, graph_digest: "d"] do
        refute SemanticBoundary.outcome_id(base) ==
                 SemanticBoundary.outcome_id(Map.put(base, k, v))
      end
    end

    test "the decision mapping relates the outcome object computed from real peer metadata" do
      [_, _, decision] = SemanticBoundary.peer_mappings("sa2a.test", __MODULE__)
      meta = %{peer: "p", envelope_id: "urn:uuid:1", standing: :admitted, graph_digest: "abc"}
      {objects, nil} = Mapping.objects(decision, %{}, meta)

      assert {"sa2a_outcome", SemanticBoundary.outcome_id(meta), "outcome"} in objects
      assert {"sa2a_envelope", "urn:uuid:1", "envelope"} in objects
    end
  end

  describe "Query {:distinct_objects, ...}" do
    test "counts distinct related objects of one type over one activity", %{tmp_dir: dir} do
      path = Path.join(dir, "ocel.json")

      doc = %{
        "objectTypes" => [],
        "eventTypes" => [],
        "objects" => [
          %{"id" => "o:1", "type" => "out"},
          %{"id" => "o:2", "type" => "out"},
          %{"id" => "p:1", "type" => "peer"},
          %{"id" => "falsifier:F-001", "type" => "falsifier"}
        ],
        "events" =>
          for {id, out, seq} <- [{"e1", "o:1", 1}, {"e2", "o:1", 2}, {"e3", "o:2", 3}] do
            %{
              "id" => id,
              "type" => "decision",
              "time" => "2026-09-16T00:00:00Z",
              "attributes" => [%{"name" => "chicago_seq", "value" => seq}],
              "relationships" => [
                %{"objectId" => out, "qualifier" => "outcome"},
                %{"objectId" => "p:1", "qualifier" => "peer"},
                %{"objectId" => "falsifier:F-001", "qualifier" => "under_stimulus"}
              ]
            }
          end
      }

      File.write!(path, JSON.encode!(doc))
      {:ok, index} = Query.load(path)

      assert {true, _} =
               Query.eval(index, "F-001", {:distinct_objects, "decision", "out", :eq, 2})

      assert {true, _} =
               Query.eval(index, "F-001", {:distinct_objects, "decision", "peer", :eq, 1})

      assert {false, _} =
               Query.eval(index, "F-001", {:distinct_objects, "decision", "out", :gte, 3})

      assert {true, _} = Query.eval(index, "F-001", {:distinct_objects, "absent", "out", :lte, 0})

      assert :ok = Query.validate_predicate({:distinct_objects, "decision", "out", :eq, 1})

      assert {:error, _} =
               Query.validate_predicate({:distinct_objects, "decision", "out", :gt, 1})
    end
  end

  describe "permanent guards for the defects the courts found" do
    alias AshA2A.Chicago.Fixtures.EnvelopeNegotiationTransport.{Ordering, OrderingAgent}
    alias AshA2A.Semantic.Envelope

    defp card(interfaces) do
      %AshA2A.Protocol.AgentCard{
        name: "c",
        description: "c",
        url: "http://127.0.0.1:1",
        version: "1",
        skills: [],
        supported_interfaces: interfaces
      }
    end

    test "SA2A-NEG-002: a binding at another protocolVersion is not an advertisement" do
      binding = Extension.profile_id()

      assert Extension.advertisement(
               card([%{protocol_binding: binding, protocol_version: "v26.9.20"}])
             ) == :compatible

      assert Extension.advertisement(
               card([%{protocol_binding: binding, protocol_version: "v25.1.0"}])
             ) == {:incompatible, ["v25.1.0"]}

      assert Extension.advertisement(card([%{protocol_binding: binding}])) ==
               {:incompatible, [nil]}

      assert Extension.advertisement(nil) == :absent
      refute Extension.advertised?(nil)

      compatible = card([%{protocol_binding: binding, protocol_version: "v26.9.20"}])
      old = card([%{protocol_binding: binding, protocol_version: "v25.1.0"}])

      assert {:error, %{code: :profile_version_incompatible}} =
               Extension.negotiate(compatible, old)

      assert {:ok, ^binding} = Extension.negotiate(compatible, compatible)
    end

    test "SA2A-ENV-004/006/010/011: admission pre-checks refuse before the engine is asked" do
      peer = Peer.new(name: "guard-peer")

      base = [
        envelope_id: "urn:uuid:guard",
        kind: "sa2a:Request",
        semantic_basis: ["urn:sa2a:basis:x"],
        provenance: %{"agent" => "urn:agent:a"},
        graph: %{media_type: "text/turtle", digest: "d", content: "<urn:a> <urn:b> <urn:c> ."}
      ]

      for {overrides, code} <- [
            {[semantic_basis: []], :semantic_basis_missing},
            {[semantic_basis: [""]], :semantic_basis_missing},
            {[provenance: %{}], :provenance_missing},
            {[provenance: %{"agent" => ""}], :provenance_missing},
            {[consequence_class: "change"], :consequence_without_authority_requirement},
            {[receipts: [%{"receiptId" => "runtime:x"}]], :receipt_reference_unverified},
            {[graph: nil], :semantic_graph_missing}
          ] do
        envelope = Envelope.new!(Keyword.merge(base, overrides))
        outcome = Peer.admit(peer, envelope)
        assert {outcome.standing, outcome.code} == {:refused, code}
      end
    end

    test "SA2A-NEG-005: activated traffic to a peer with no advertised card is UNSUPPORTED" do
      message =
        "x"
        |> AshA2A.Protocol.Message.new_user()
        |> Extension.activate(%{"envelopeId" => "urn:uuid:y", "kind" => "sa2a:Request"})

      outcome = Peer.receive_message(Peer.new(name: "no-card"), message)
      assert {outcome.standing, outcome.code} == {:unsupported, :profile_not_advertised}
    end

    # Re-pinned: the wire shape (string keys) resolves to the verified identity
    # in-process; ingress forgery is closed by every transport dropping
    # client-supplied "a2a.auth" before binding the verified value.
    test "SA2A-TRANSPORT-004: a string-keyed a2a.auth resolves to the same verified identity as atom-keyed" do
      principal = "guard-granted-#{System.unique_integer([:positive])}"
      subject = AshA2A.Identity.principal(principal)
      # SA2A-AUTH-017 (RFC-SA2A-002 S66): the real dispatch path
      # (`AshA2A.Agent.build_command/4`) resolves the dispatched skill's
      # canonical capability id before calling `Grant.authorize/3`, so this
      # grant must be issued under `Ordering`'s canonical id, not the bare
      # wire selector "place_order".
      {:ok, %{id: place_order_id}} = AshA2A.Info.skill(Ordering, "place_order")
      _ = AshA2A.Authority.Grant.grant(subject, place_order_id)
      assert AshA2A.Authority.Grant.granted?(subject, place_order_id)

      agent = :"guard_ordering_#{System.unique_integer([:positive])}"
      {:ok, pid} = OrderingAgent.start_link(name: agent)
      on_exit(fn -> AshA2A.TestSupport.SafeStop.stop(pid) end)

      order = fn item ->
        %{
          AshA2A.Protocol.Message.new_user([
            AshA2A.Protocol.Part.Data.new(%{"item" => item, "quantity" => 1})
          ])
          | metadata: %{"skill" => "place_order"}
        }
      end

      forged = "guard-forged-#{System.unique_integer([:positive])}"
      verified = "guard-verified-#{System.unique_integer([:positive])}"

      {:ok, _} =
        AshA2A.Protocol.call(agent, order.(forged),
          metadata: %{"a2a.auth" => %{"identity" => principal}}
        )

      {:ok, _} =
        AshA2A.Protocol.call(agent, order.(verified),
          metadata: %{"a2a.auth" => %{identity: principal}}
        )

      items = Ordering |> Ash.read!() |> Enum.map(& &1.item)
      assert forged in items
      assert verified in items
    end
  end

  describe "refusal codes introduced at the semantic boundary are classified" do
    test "Peer and Extension codes map to S42 classes" do
      mapping = Refusal.mapping()

      for {code, class} <-
            Map.merge(Peer.__sa2a_refusal_codes__(), Extension.__sa2a_refusal_codes__()) do
        assert Refusal.class?(class)
        assert Map.fetch!(mapping, code) in Refusal.classes()
      end
    end
  end
end

# --- SECTION 10: Original test/ash_a2a/chicago/falsifier_wasm_default_reachability_test.exs ---
defmodule AshA2A.Chicago.FalsifierWasmDefaultReachabilityTest do
  @moduledoc """
  Falsifier (`errc/ash-a2a-format`, lens: falsifier) for the claim that the
  praxis-graphlaw engine is "unreachable on the hosted runner", which was the
  stated reason 103 tests were excluded under `:graphlaw_engine` instead of
  running (ash_a2a#27).

  Real files only: the repo's own git-tracked `priv/graphlaw/` tree and the
  `lib/` sources, read from disk. No collaborator is faked.

  1. Positive control: the wasm every hosted checkout contains,
     `priv/graphlaw/praxis_graphlaw.wasm`, is byte-identical to the digest
     `priv/graphlaw/MANIFEST.json` pins (and, on a machine that has the praxis
     checkout, to that build). The engine is reachable from a bare checkout;
     no exclusion is forced by absence of the artifact.
  2. Falsifier: no module under `lib/` defaults a wasm resolver to an absolute
     path under a developer home. At 55753a5 it FAILED: six `@default_*wasm*`
     offenders (`graph_law/wasm.ex`, `graph_law/wasm_driver.ex`,
     `sa2a/graphlaw.ex`, `semantic/graph_law/wasm.ex`,
     `semantic/graph_law_bridge.ex`, `semantic/root_manifest/engine_probe.ex`)
     plus, under the `~/praxis` pattern added afterwards, `graph_law/runtime.ex`.
     That default, not the absence of the engine, made the 103 hosted-runner
     tests fail. It is retained as the permanent guard against reintroducing
     such a default. The resolved-state counterpart is
     `AshA2A.Chicago.WasmDefaultResolutionTest`.
  """

  use ExUnit.Case, async: true

  @root Path.expand("../../..", __DIR__)
  @vendored Path.join(@root, "priv/graphlaw/praxis_graphlaw.wasm")
  @manifest Path.join(@root, "priv/graphlaw/MANIFEST.json")

  test "positive control: the git-tracked vendored wasm exists and matches the digest MANIFEST.json pins" do
    assert File.regular?(@vendored)

    pinned = @manifest |> File.read!() |> Jason.decode!() |> get_in(["artifact", "sha256"])
    actual = :crypto.hash(:sha256, File.read!(@vendored)) |> Base.encode16(case: :lower)

    assert actual == pinned

    {tracked, 0} =
      System.cmd("git", ["ls-files", "--error-unmatch", "priv/graphlaw/praxis_graphlaw.wasm"],
        cd: @root
      )

    assert String.trim(tracked) == "priv/graphlaw/praxis_graphlaw.wasm"
  end

  test "falsifier: no lib module defaults a wasm resolver to an absolute path under a developer home" do
    offenders =
      @root
      |> Path.join("lib/**/*.ex")
      |> Path.wildcard()
      |> Enum.flat_map(fn file ->
        file
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _n} ->
          # An attribute default under a developer home, or an expanded `~/praxis`
          # default (GraphLaw.Runtime used the latter, which the attribute form
          # alone would not catch).
          Regex.match?(~r/@default_\w*wasm\w*\s+"\/(Users|home)\//, line) or
            Regex.match?(~r/Path\.expand\("~\/praxis/, line)
        end)
        |> Enum.map(fn {_line, n} -> "#{Path.relative_to(file, @root)}:#{n}" end)
      end)

    assert offenders == [],
           "wasm resolvers whose default is a developer-home path although the identical " <>
             "artifact is vendored at priv/graphlaw/praxis_graphlaw.wasm: #{inspect(offenders)}"
  end
end

# --- SECTION 11: Original test/ash_a2a/chicago/federated_delegation_test.exs ---
defmodule AshA2A.Chicago.FederatedDelegationTest do
  @moduledoc """
  `SA2A-FED` Federated Delegation Court run end to end (RFC-SA2A-001 §54
  Confused Deputy Prevention; RFC-SA2A-002 §75, §38, §68).

  Real collaborators throughout: two genuinely distinct, real supervised
  `AshA2A.Protocol.Agent` GenServer processes (peer A, peer B), each with its own real
  `AshA2A.CommandBus` / `AshA2A.Dispatcher` / `AshA2A.Authority.Grant`
  admission path, a real cross-process `AshA2A.Protocol.call/3` hop between them, real
  ETS resources read back through `Ash.read!/1`, real telemetry, and the
  durable OCEL artifact read by the independent consumer. No Mock/Mox/:meck/
  patch.

  `async: false` -- the court points `:authority_policy` / `:authority_broker`
  at a real, isolated broker for the duration of the run.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  alias AshA2A.Chicago
  alias AshA2A.Chicago.{Query, Runner}
  alias AshA2A.Chicago.Courts.FederatedDelegation

  @moduletag :tmp_dir

  @expected %{
    "SA2A-FED-001" => :positive_control_passed,
    "SA2A-FED-002" => :falsifier_killed,
    "SA2A-FED-003" => :falsifier_killed
  }

  describe "SA2A-FED end to end over the real SUT" do
    @tag timeout: 120_000
    test "every falsifier reaches its verdict and every pass is corroborated by the independent OCEL consumer",
         %{tmp_dir: dir} do
      assert {:ok, run} =
               Runner.run(courts: [FederatedDelegation], profile: :core, evidence_dir: dir)

      by_id = Map.new(run.results, &{&1.falsifier_id, &1})
      assert Enum.sort(Map.keys(by_id)) == Enum.sort(Map.keys(@expected))

      for {id, verdict} <- @expected do
        result = by_id[id]
        assert result.verdict == verdict, "#{id}: #{inspect(result, pretty: true)}"
        assert result.attempt_observed? == true, "#{id}: #{inspect(result, pretty: true)}"
        assert result.ocel_corroborated? == true, "#{id}: #{result.ocel_detail}"
      end

      assert run.ocel.dropped == 0
    end

    test "the independent consumer answers the federation question from the durable artifact alone",
         %{tmp_dir: dir} do
      {:ok, run} = Runner.run(courts: [FederatedDelegation], profile: :core, evidence_dir: dir)
      assert {:ok, index} = Query.load(Path.join(dir, "ocel.json"), run.ocel.sha256)

      # The lawful cross-peer hop: both peers' own CommandBus admitted and
      # committed -- two distinct receipted DOs, not one.
      assert {true, _} = Query.eval(index, "SA2A-FED-001", {:count, "brce.admission", :gte, 2})
      assert {true, _} = Query.eval(index, "SA2A-FED-001", {:count, "brce.commit", :gte, 2})

      # Confused deputy: peer A's own admission is reached, but peer B never
      # acquires a second committed receipt on its own.
      assert {true, _} = Query.eval(index, "SA2A-FED-002", {:count, "brce.admission", :gte, 2})
      assert {false, _} = Query.eval(index, "SA2A-FED-002", {:count, "brce.commit", :gte, 2})

      # Bypass: the dispatcher was reached, but nothing actuated without a
      # preceding receipted prepare sharing command and receipt.
      assert {true, _} = Query.eval(index, "SA2A-FED-003", {:observed, "dispatch.start"})
    end
  end

  describe "court declaration (§11, discovery)" do
    test "SA2A-FED is a discoverable core court with fully declared falsifiers" do
      assert FederatedDelegation in Chicago.courts_for(:core)
      assert FederatedDelegation.gate() == nil

      falsifiers = FederatedDelegation.falsifiers()
      assert Enum.map(falsifiers, & &1.id) == Enum.sort(Map.keys(@expected))

      for f <- falsifiers do
        assert f.court_id == "SA2A-FED"
        assert f.attempt_predicate != nil, f.id
        assert f.outcome_predicate != nil, f.id
        assert :ok = Query.validate_predicate(f.attempt_predicate)
        assert :ok = Query.validate_predicate(f.outcome_predicate)
      end

      kinds = Enum.frequencies_by(falsifiers, & &1.kind)
      assert kinds == %{negative: 2, positive_control: 1}
    end
  end
end

# --- SECTION 12: Original test/ash_a2a/chicago/fibo_finance_test.exs ---
defmodule AshA2A.Chicago.FiboFinanceTest do
  @moduledoc """
  Qualifies the `CHI-FIN` court, Chicago style: the real graphlaw JSON ABI
  (compiled wasm, `GRAPHLAW_ABI_WASM`, run by Wasmtime), a real ETS ledger, a
  real journal file, a real `:kill` of a real process, and the durable OCEL
  artifact read back by the independent consumer. Nothing on the path is
  replaced by a double.

  Standing ceiling: finite published corpus passes on exact subject; authority
  NONE; synthetic subject; no general financial safety claim. The `$10M`
  ceiling is this court's policy, not FIBO's; there is no payment rail.

  Each negative falsifier is proven non-vacuous: with exactly its guard removed
  (`without: [guard]`) the forbidden outcome is observed.

  `async: false`: the observer attributes every telemetry event emitted between
  a stimulus start and stop to that falsifier.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  @moduletag :tmp_dir
  @moduletag capture_log: true
  @moduletag timeout: 600_000

  alias AshA2A.Chicago.Courts.FiboFinance, as: Court
  alias AshA2A.Chicago.Fixtures.FiboFinance, as: Fx
  alias AshA2A.Chicago.Fixtures.FiboFinance.Abi
  alias AshA2A.Chicago.Runner

  @expected %{
    "CHI-FIN-001" => :falsifier_killed,
    "CHI-FIN-002" => :positive_control_passed,
    "CHI-FIN-003" => :falsifier_killed,
    "CHI-FIN-004" => :positive_control_passed,
    "CHI-FIN-005" => :falsifier_killed,
    "CHI-FIN-006" => :positive_control_passed,
    "CHI-FIN-007" => :falsifier_killed,
    "CHI-FIN-008" => :falsifier_killed,
    "CHI-FIN-009" => :falsifier_killed,
    "CHI-FIN-010" => :positive_control_passed,
    "CHI-FIN-011" => :falsifier_killed,
    "CHI-FIN-012" => :falsifier_killed,
    "CHI-FIN-013" => :positive_control_passed
  }

  setup_all do
    case Fx.start_abi() do
      {:ok, abi} ->
        on_exit(fn -> Abi.stop(abi) end)
        {:ok, abi: abi}

      {:blocked, reason} ->
        flunk(
          "BLOCKED[wasm-artifact]: #{reason} (set #{Abi.env()} to the HEAD-rebuilt graphlaw ABI wasm)"
        )
    end
  end

  describe "the CHI-FIN court over the real SUT" do
    test "the declared falsifier ids are contiguous and unique" do
      ids = Enum.map(Court.falsifiers(), & &1.id)
      assert ids == Enum.sort(ids)
      assert ids == Enum.uniq(ids)
      assert Enum.sort(ids) == Enum.sort(Map.keys(@expected))
    end

    test "every falsifier reaches its verdict and every pass is OCEL-corroborated", %{
      tmp_dir: dir
    } do
      assert {:ok, run} = Runner.run(courts: [Court], profile: :core, evidence_dir: dir)

      by_id = Map.new(run.results, &{&1.falsifier_id, &1})
      assert by_id |> Map.keys() |> Enum.sort() == @expected |> Map.keys() |> Enum.sort()

      for {id, verdict} <- @expected do
        result = by_id[id]

        assert result.verdict == verdict,
               "#{id}: expected #{verdict}, got #{result.verdict} -- " <>
                 "#{inspect(result.detail)} / #{inspect(result.ocel_detail)}"

        assert result.ocel_corroborated? == true, "#{id}: #{inspect(result.ocel_detail)}"
        assert result.evidence["graphlaw_abi_wasm_sha256"] =~ ~r/^[0-9a-f]{64}$/
      end

      assert run.ocel.dropped == 0

      receipt = JSON.decode!(File.read!(Path.join(dir, "standing_receipt.json")))
      assert receipt["results"]["falsifiers_killed"] == 8
      assert receipt["results"]["falsifiers_survived"] == 0
      assert receipt["results"]["positive_controls_passed"] == 5
      assert receipt["results"]["unresolved_ids"] == []
    end
  end

  describe "positive controls are real effects" do
    test "an in-envelope transfer writes exactly one row and completes", %{abi: abi} do
      s = Fx.within_envelope(abi)
      assert [%{outcome: :completed, observed_rows: 1}] = s.results
      assert [%{amount: amount}] = s.rows
      assert amount == Fx.usd(5)
    end

    test "the ceiling is inclusive at exactly $10M", %{abi: abi} do
      s = Fx.ceiling_boundary(abi)
      assert [%{outcome: :completed}] = s.results
      assert [%{amount: 10_000_000_000_000}] = s.rows
    end

    test "the exact $100M authority completes with the sealed counterparty", %{abi: abi} do
      s = Fx.exact_authority(abi)
      assert [%{outcome: :completed}] = s.results
      assert [%{amount: 100_000_000_000_000, counterparty: "urn:party:acme"}] = s.rows
    end
  end

  describe "refusals name the gate that decided" do
    test "each attack is refused at its own gate and writes nothing", %{abi: abi} do
      assert %{
               results: [%{outcome: {:refused, "envelope", :money_micros_envelope_exceeded}}],
               rows: []
             } =
               Fx.envelope_breach(abi)

      assert %{results: [%{outcome: {:refused, "ceiling", :grant_ceiling_exceeded}}], rows: []} =
               Fx.ceiling_breach(abi)

      assert %{results: [%{outcome: {:refused, "seal", :effect_mutated_after_seal}}], rows: []} =
               Fx.counterparty_mutation(abi)

      assert %{results: [%{outcome: {:refused, "key_status", :signing_key_revoked}}], rows: []} =
               Fx.revoked_key_submission(abi)
    end

    test "a replay is refused by the plan's pre_not and the ledger keeps one row", %{abi: abi} do
      s = Fx.replay(abi)

      assert [%{outcome: :completed}, %{outcome: {:refused, "plan", :already_settled}}] =
               s.results

      assert length(s.rows) == 1
    end

    test "a lying processor is withheld, not completed", %{abi: abi} do
      s = Fx.lying_processor(abi)
      assert [%{outcome: :withheld, observed_rows: 0}] = s.results
      assert s.rows == []
    end

    test "a crash after the effect is reconciled, not re-executed", %{abi: abi} do
      s = Fx.crash_after_do(abi)
      assert [%{outcome: :crashed}] = s.results
      assert [%{outcome: :reconciled}] = s.recovered
      assert length(s.rows) == 1
    end

    test "the cascade stops at the depth bound and a short one runs to its end", %{abi: abi} do
      bounded = Fx.cascade(abi, 10)
      assert bounded.stop == "depth_bound"
      assert length(bounded.rows) == 3

      short = Fx.cascade(abi, 3)
      assert short.stop == "chain_end"
      assert length(short.rows) == 3
    end
  end

  describe "non-vacuity: removing exactly one guard makes the forbidden outcome happen" do
    test "no envelope guard: the $25M transfer is debited", %{abi: abi} do
      s = Fx.envelope_breach(abi, [:envelope])
      assert [%{outcome: :completed}] = s.results
      assert [%{amount: 25_000_000_000_000}] = s.rows
    end

    test "no ceiling guard: the $25M transfer under a $10M ceiling is debited", %{abi: abi} do
      s = Fx.ceiling_breach(abi, [:ceiling])
      assert [%{outcome: :completed}] = s.results
      assert [%{amount: 25_000_000_000_000}] = s.rows
    end

    test "no seal guard: the mutated counterparty is paid", %{abi: abi} do
      s = Fx.counterparty_mutation(abi, [:seal])
      assert [%{outcome: :completed}] = s.results
      assert [%{counterparty: "urn:party:mallory"}] = s.rows
    end

    test "no key-status guard: the revoked key's transfer is debited", %{abi: abi} do
      s = Fx.revoked_key_submission(abi, [:key_status])
      assert [%{outcome: :completed}] = s.results
      assert length(s.rows) == 1
    end

    test "no replay guard: the replay debits twice (the observer then withholds the second)", %{
      abi: abi
    } do
      s = Fx.replay(abi, [:replay])
      assert [%{outcome: :completed}, %{outcome: :withheld, observed_rows: 2}] = s.results
      assert length(s.rows) == 2
    end

    test "no observer guard: the lying processor is completed with an empty ledger", %{abi: abi} do
      s = Fx.lying_processor(abi, [:observer])
      assert [%{outcome: :completed}] = s.results
      assert s.rows == []
    end

    test "no reconcile guard: recovery re-executes and the ledger holds two rows", %{abi: abi} do
      s = Fx.crash_after_do(abi, [:reconcile])
      assert [%{outcome: :reexecuted}] = s.recovered
      assert length(s.rows) == 2
    end

    test "no depth guard: the cascade runs past the bound", %{abi: abi} do
      s = Fx.cascade(abi, 10, [:depth])
      assert length(s.rows) > 3
    end
  end

  describe "the engine is a precondition, never assumed" do
    test "a missing ABI artifact is BLOCKED for every falsifier, never a pass", %{tmp_dir: dir} do
      previous = System.get_env(Abi.env())
      System.put_env(Abi.env(), Path.join(dir, "absent.wasm"))

      try do
        assert {:ok, run} = Runner.run(courts: [Court], profile: :core, evidence_dir: dir)
        assert length(run.results) == map_size(@expected)
        assert Enum.all?(run.results, &(&1.verdict == :blocked))
        refute Enum.any?(run.results, & &1.ocel_corroborated?)
      after
        if previous, do: System.put_env(Abi.env(), previous), else: System.delete_env(Abi.env())
      end
    end
  end
end

# --- SECTION 13: Original test/ash_a2a/chicago/fibo_high_value_finance_test.exs ---
defmodule AshA2A.Chicago.FiboHighValueFinanceTest do
  @moduledoc """
  v26.9.29 Chicago 80/20 court for high-value FIBO-shaped financial subjects.

  This court does not claim payment-rail conformance and never moves real money.
  It qualifies the SA2A invariants that a later FIBO transaction runtime depends on:

    * exact canonical transaction identity;
    * amount/currency/counterparty/agreement drift changes the prepared subject;
    * integer-only micro-unit accounting at and above the USD 10M boundary;
    * finite financial envelopes fail closed;
    * semantic evidence constrains identity but never manufactures authority.

  The transaction vocabulary is shaped from FIBO concepts already vendored by
  GraphLaw: MarketTransaction, MonetaryAmount, Currency, payment terms,
  contractual basis, counterparties and settlement.
  """

  use ExUnit.Case, async: true

  alias AshA2A.{EffectInstance, PreparedEffect}
  alias AshA2A.Chicago
  alias AshA2A.Semantic.Allocator

  @fibo_market_transaction "https://spec.edmcouncil.org/fibo/ontology/FND/TransactionsExt/MarketTransactions/MarketTransaction"
  @fibo_monetary_amount "https://spec.edmcouncil.org/fibo/ontology/FND/Accounting/CurrencyAmount/MonetaryAmount"
  @fibo_usd "https://spec.edmcouncil.org/fibo/ontology/FND/Accounting/ISO4217-CurrencyCodes/USDollar"

  @usd_10m_micros 10_000_000_000_000
  @usd_25m_micros 25_000_000_000_000

  defp transaction(overrides \\ %{}) do
    base = %{
      "id" => "urn:sa2a:fibo:transaction:tx-25m-usd-001",
      "type" => @fibo_market_transaction,
      "principal" => "urn:lei:principal-bank",
      "counterparty" => "urn:lei:counterparty-bank",
      "consideration" => %{
        "type" => @fibo_monetary_amount,
        "amount" => "25000000.000000",
        "currency" => @fibo_usd
      },
      "paymentTerms" => "urn:sa2a:fibo:payment-terms:pt-001",
      "settlement" => "urn:sa2a:fibo:settlement:set-001",
      "masterAgreement" => "urn:sa2a:fibo:master-agreement:ma-001"
    }

    deep_merge(base, overrides)
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, l, r ->
      if is_map(l) and is_map(r), do: deep_merge(l, r), else: r
    end)
  end

  defp effect_instance(subject) do
    {:ok, instance} =
      EffectInstance.new(%{
        request: %{
          "request_id" => "urn:sa2a:fibo:request:settle-001",
          "purpose" => "settle admitted FIBO market transaction"
        },
        subject: subject,
        effect: %{
          "op" => "settle",
          "rail" => "synthetic-chicago-ledger"
        },
        generation: 29,
        policy_epoch: 29
      })

    instance
  end

  defp evidence_ref(graph_char \\ "b") do
    %{
      "schema" => "sa2a.semantic-evidence-envelope.v1",
      "contractVersion" => "v26.9.29",
      "subject" => "urn:sa2a:fibo:transaction:tx-25m-usd-001",
      "sourceDigest" => "sha256:" <> String.duplicate("a", 64),
      "graphDigest" => "sha256:" <> String.duplicate(graph_char, 64),
      "replayIdentity" => "replay:fibo:tx-25m-usd-001:v26.9.29",
      "envelopeDigest" => "sha256:" <> String.duplicate("c", 64),
      "authority" => "NONE",
      "consequence" => "EVIDENCE_ONLY"
    }
  end

  defp prepared(subject, evidence \\ evidence_ref()) do
    instance = effect_instance(subject)

    {:ok, prepared} =
      PreparedEffect.new(
        instance,
        %{
          "op" => "settle",
          "transaction" => subject["id"],
          "amount_micros" => @usd_25m_micros
        },
        :external_do,
        semantic_evidence: evidence,
        authority_epoch: 29
      )

    prepared
  end

  test "FIBO-shaped transaction identity is canonical across map construction order" do
    tx = transaction()

    reordered =
      tx
      |> Enum.reverse()
      |> Map.new()
      |> Map.update!("consideration", fn amount ->
        amount |> Enum.reverse() |> Map.new()
      end)

    left = effect_instance(tx)
    right = effect_instance(reordered)

    assert left.subject_digest == right.subject_digest
    assert prepared(tx).prepared_digest == prepared(reordered).prepared_digest
  end

  test "behaviorally meaningful FIBO transaction mutations change prepared identity" do
    baseline = prepared(transaction()).prepared_digest

    mutations = [
      transaction(%{"counterparty" => "urn:lei:different-counterparty"}),
      transaction(%{"consideration" => %{"amount" => "25000000.000001"}}),
      transaction(%{"consideration" => %{"currency" => "urn:iso4217:EUR"}}),
      transaction(%{"masterAgreement" => "urn:sa2a:fibo:master-agreement:ma-002"}),
      transaction(%{"settlement" => "urn:sa2a:fibo:settlement:set-002"})
    ]

    for mutated <- mutations do
      refute prepared(mutated).prepared_digest == baseline
    end
  end

  test "USD 25M is represented exactly as integer money micros and can consume an exact envelope" do
    assert @usd_25m_micros == 25_000_000 * 1_000_000

    budget =
      Allocator.new!([money_micros: @usd_25m_micros],
        issued_by: {:host, __MODULE__}
      )

    assert {:ok, spent} =
             Allocator.allocate(budget, :money_micros, @usd_25m_micros)

    assert spent.consumed.money_micros == @usd_25m_micros
    assert Allocator.remaining(spent).money_micros == 0
  end

  test "a USD 25M consequence is refused by a USD 10M financial envelope" do
    budget =
      Allocator.new!([money_micros: @usd_10m_micros],
        issued_by: {:host, __MODULE__}
      )

    assert {:error,
            %{
              code: :budget_exhausted,
              dimension: :money_micros,
              limit: @usd_10m_micros,
              requested: @usd_25m_micros
            }} = Allocator.allocate(budget, :money_micros, @usd_25m_micros)
  end

  test "the USD 10M boundary is exact: the boundary fits and one micro above refuses" do
    exact =
      Allocator.new!([money_micros: @usd_10m_micros],
        issued_by: {:host, __MODULE__}
      )

    assert {:ok, exact_spent} =
             Allocator.allocate(exact, :money_micros, @usd_10m_micros)

    assert Allocator.remaining(exact_spent).money_micros == 0

    above =
      Allocator.new!([money_micros: @usd_10m_micros],
        issued_by: {:host, __MODULE__}
      )

    assert {:error, %{code: :budget_exhausted, requested: requested}} =
             Allocator.allocate(above, :money_micros, @usd_10m_micros + 1)

    assert requested == @usd_10m_micros + 1
  end

  test "financial budget never manufactures transaction authority" do
    budget =
      Allocator.new!(
        [
          money_micros: @usd_25m_micros,
          tokens: 1_000_000,
          external_requests: 16
        ],
        issued_by: {:host, __MODULE__}
      )

    refute :authority in Allocator.dimensions()

    assert {:error, %{code: :authority_not_allocatable}} =
             Allocator.allocate(budget, :authority, @usd_25m_micros)
  end

  test "FIBO semantic evidence changes prepared identity but remains authority NONE" do
    tx = transaction()

    a = prepared(tx, evidence_ref("b"))
    b = prepared(tx, evidence_ref("d"))

    refute a.prepared_digest == b.prepared_digest
    assert a.semantic_evidence["authority"] == "NONE"
    assert b.semantic_evidence["authority"] == "NONE"
  end

  test "v26.9.29 FIBO profile is backed by the canonical Chicago agent courts" do
    profile =
      "priv/sa2a/fibo_v26_9_29_chicago_profile.json"
      |> File.read!()
      |> JSON.decode!()

    discovered = Map.new(Chicago.courts(), &{&1.id(), &1})

    assert profile["schema"] == "sa2a.fibo-chicago-profile.v1"
    assert profile["version"] == "v26.9.29"
    assert profile["inherits"] == ["chicago.universal.v1"]
    assert profile["authority"] == "NONE"
    assert profile["consequence"] == "EVIDENCE_ONLY"
    assert profile["policyBoundary"]["currency"] == "USD"
    assert profile["policyBoundary"]["amountMicros"] == @usd_10m_micros

    for id <- profile["requiredCourtIds"] do
      assert Map.has_key?(discovered, id), "required Chicago court #{id} is not discoverable"
      court = Map.fetch!(discovered, id)
      assert court.falsifiers() != [], "required Chicago court #{id} has no falsifiers"
    end

    for mapping <- profile["researchMappings"] do
      assert mapping["precedent"] not in [nil, ""]
      assert mapping["courtIds"] != []

      for id <- mapping["courtIds"] do
        assert id in profile["requiredCourtIds"],
               "#{mapping["precedent"]} names court #{id} outside the FIBO profile"
      end
    end
  end

  test "the finance profile requires the full semantic-to-consequence chain, not money checks alone" do
    profile =
      "priv/sa2a/fibo_v26_9_29_chicago_profile.json"
      |> File.read!()
      |> JSON.decode!()

    required = MapSet.new(profile["requiredCourtIds"])

    for id <- [
          "SA2A-ENGINE",
          "SA2A-LOGIC",
          "SA2A-HOOK",
          "SA2A-CASCADE",
          "CHI-PLAN-AUTH",
          "CHI-PREFLIGHT",
          "SA2A-PLAN",
          "CHI-AUTO",
          "SA2A-BOUNDS",
          "SA2A-AUTH",
          "SA2A-AUTH-GRANT",
          "SA2A-FED",
          "CHI-BRCE",
          "CHI-POST",
          "CHI-RECEIPT",
          "CHI-REPLAY",
          "SA2A-CHAOS",
          "SA2A-ATTEST",
          "SA2A-OCEL",
          "CHI-FRESH"
        ] do
      assert MapSet.member?(required, id), "missing finance-chain court #{id}"
    end
  end

  test "high-value semantic evidence cannot smuggle DO authority into PreparedEffect" do
    tx = transaction()
    instance = effect_instance(tx)
    smuggled = Map.put(evidence_ref(), "authority", "DO")

    assert {:error, %{code: :refused_semantic_evidence, subject: :authority}} =
             PreparedEffect.new(
               instance,
               %{
                 "op" => "settle",
                 "transaction" => tx["id"],
                 "amount_micros" => @usd_25m_micros
               },
               :external_do,
               semantic_evidence: smuggled,
               authority_epoch: 29
             )
  end
end

# --- SECTION 14: Original test/ash_a2a/chicago/foundation_test.exs ---
defmodule AshA2A.Chicago.FoundationTest do
  @moduledoc """
  Qualifies the RFC-SA2A-002 court machinery itself, Chicago style: real
  CommandBus, real ETS resource, real receipt store, real telemetry, a real
  OCEL artifact on disk read back by an independent consumer.

  `async: false` -- the observer attributes every telemetry event emitted
  between a stimulus start and stop to that falsifier, so concurrent tests
  driving the same boundaries would pollute attribution.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  alias AshA2A.Chicago

  alias AshA2A.Chicago.{
    Context,
    Falsifier,
    Observer,
    Profile,
    Query,
    Result,
    Runner,
    StandingReceipt,
    Subject
  }

  alias AshA2A.Chicago.Ocel.Mapping
  alias AshA2A.Semantic.Refusal
  alias AshA2A.Test.ChicagoSelfTest

  @moduletag :tmp_dir

  describe "a real run over the real CommandBus" do
    test "kills the no-grant falsifier, passes the positive control, and both are OCEL-corroborated",
         %{tmp_dir: dir} do
      assert {:ok, run} =
               Runner.run(profile: :core, courts: [ChicagoSelfTest.Court], evidence_dir: dir)

      by_id = Map.new(run.results, &{&1.falsifier_id, &1})

      negative = by_id["CHI-SELFTEST-001"]
      assert negative.verdict == :falsifier_killed
      assert negative.attempt_observed? == true
      assert negative.ocel_corroborated? == true, negative.ocel_detail

      positive = by_id["CHI-SELFTEST-002"]
      assert positive.verdict == :positive_control_passed
      assert positive.ocel_corroborated? == true, positive.ocel_detail

      # The artifact is durable and content-addressed: a fresh read of the
      # bytes on disk hashes to the digest the receipt binds.
      assert File.exists?(Path.join(dir, "ocel.json"))
      assert Subject.file_sha256(Path.join(dir, "ocel.json")) == run.ocel.sha256
      assert run.ocel.dropped == 0

      receipt = JSON.decode!(File.read!(Path.join(dir, "standing_receipt.json")))
      assert receipt["evidence"]["ocel_digest"] == run.ocel.sha256
      assert :ok = StandingReceipt.verify_digest(receipt)
      assert receipt["results"]["falsifiers_killed"] == 1
      assert receipt["results"]["positive_controls_passed"] == 1

      # Core requires gates 1-3; none are covered by the self-test court, so
      # standing is honestly PARTIAL_ALIVE, never CONFORMANT.
      assert receipt["standing"] == "PARTIAL_ALIVE"
      assert receipt["results"]["gates_missing"] == 3
      assert receipt["claim"] =~ "SA2A-CORE PARTIAL_ALIVE"
    end

    test "the independent consumer answers semantic questions from disk only", %{tmp_dir: dir} do
      {:ok, run} = Runner.run(profile: :core, courts: [ChicagoSelfTest.Court], evidence_dir: dir)

      assert {:ok, index} = Query.load(Path.join(dir, "ocel.json"), run.ocel.sha256)

      # No actuation was attributed to the denied stimulus...
      assert {false, _} = Query.eval(index, "CHI-SELFTEST-001", {:observed, "brce.actuate.start"})
      # ...while the authorized one prepared its receipt before actuating.
      assert {true, _} =
               Query.eval(
                 index,
                 "CHI-SELFTEST-002",
                 {:precedes, "brce.prepare", "brce.actuate.start", "command"}
               )

      # Tampered bytes are refused, not silently re-hashed.
      assert {:error, {:ocel_digest_mismatch, _}} =
               Query.load(Path.join(dir, "ocel.json"), String.duplicate("0", 64))
    end

    test "the OCEL artifact is object-centric OCEL 2.0 JSON", %{tmp_dir: dir} do
      {:ok, _run} = Runner.run(profile: :core, courts: [ChicagoSelfTest.Court], evidence_dir: dir)
      doc = JSON.decode!(File.read!(Path.join(dir, "ocel.json")))

      assert Enum.sort(Map.keys(doc)) == ["eventTypes", "events", "objectTypes", "objects"]
      object_ids = MapSet.new(doc["objects"], & &1["id"])

      for event <- doc["events"], rel <- event["relationships"] do
        assert MapSet.member?(object_ids, rel["objectId"])
      end

      admission = Enum.find(doc["events"], &(&1["type"] == "brce.admission"))

      related_types =
        admission["relationships"]
        |> Enum.map(& &1["objectId"])
        |> Enum.map(&hd(String.split(&1, ":")))

      assert "command" in related_types
      assert "capability" in related_types
      assert "falsifier" in related_types
    end
  end

  describe "the verdict algebra cannot be gamed" do
    test "a court that reports a kill it never attempted is downgraded to UNKNOWN", %{
      tmp_dir: dir
    } do
      {:ok, run} =
        Runner.run(profile: :core, courts: [ChicagoSelfTest.LyingCourt], evidence_dir: dir)

      by_id = Map.new(run.results, &{&1.falsifier_id, &1})

      assert by_id["CHI-LIAR-001"].verdict == :unknown
      assert by_id["CHI-LIAR-001"].failure_class == :ocel_evidence_incomplete
      assert by_id["CHI-LIAR-002"].verdict == :unknown
      assert by_id["CHI-LIAR-002"].detail =~ "vacuity guard"
      assert run.receipt["standing"] == "UNKNOWN"
    end

    test "a crashing court yields UNKNOWN for every declared falsifier, never a pass", %{
      tmp_dir: dir
    } do
      {:ok, run} =
        Runner.run(profile: :core, courts: [ChicagoSelfTest.CrashingCourt], evidence_dir: dir)

      assert [%Result{falsifier_id: "CHI-CRASH-001", verdict: :unknown, detail: detail}] =
               run.results

      assert detail =~ "court exploded"
      assert Enum.find(run.receipt["gates"], &(&1["gate"] == 7))["status"] == "OPEN"
    end

    test "attempt not observed is UNKNOWN, forbidden observed is SURVIVED" do
      [f | _] = ChicagoSelfTest.Court.falsifiers()

      assert Result.negative(f, attempt_observed?: false, forbidden_outcome_observed?: false).verdict ==
               :unknown

      assert Result.negative(f, attempt_observed?: :unknown, forbidden_outcome_observed?: false).verdict ==
               :unknown

      assert Result.negative(f, attempt_observed?: true, forbidden_outcome_observed?: :unknown).verdict ==
               :unknown

      survived = Result.negative(f, attempt_observed?: true, forbidden_outcome_observed?: true)
      assert survived.verdict == :falsifier_survived
      assert survived.failure_class == :authority_failure

      killed = Result.negative(f, attempt_observed?: true, forbidden_outcome_observed?: false)
      assert killed.verdict == :falsifier_killed
      refute Result.counts_as_pass?(killed)
    end

    test "a §11-incomplete falsifier declaration is refused at construction" do
      assert_raise ArgumentError, ~r/guard must be a non-empty string/, fn ->
        Falsifier.new!(
          id: "CHI-X-001",
          court_id: "CHI-X",
          kind: :negative,
          invariant: "i",
          stimulus: "s",
          boundary: "b",
          forbidden_outcome: "f",
          attempt_evidence: "a",
          survival_evidence: "s"
        )
      end

      assert_raise ArgumentError, ~r/falsifier id must match/, fn ->
        Falsifier.new!(
          id: "bad",
          court_id: "CHI-X",
          kind: :measurement,
          invariant: "i",
          stimulus: "s",
          boundary: "b"
        )
      end

      assert_raise ArgumentError, ~r/not a valid Chicago query predicate/, fn ->
        Falsifier.new!(
          id: "CHI-X-002",
          court_id: "CHI-X",
          kind: :measurement,
          invariant: "i",
          stimulus: "s",
          boundary: "b",
          attempt_evidence: "a",
          attempt_predicate: {:golden_trace, "ocel.json"}
        )
      end
    end
  end

  describe "observer evidence discipline" do
    test "a raising mapping never detaches the handler or loses the event" do
      event = [:ash_a2a, :chicago, :foundation_test, :probe]

      mapping =
        Mapping.new!(
          event: event,
          activity: "probe",
          source: __MODULE__,
          objects: fn _, _ -> raise "boom" end
        )

      {:ok, observer} = Observer.start_link(run_id: "probe-run", mappings: [mapping])

      :telemetry.execute(event, %{}, %{})
      :telemetry.execute(event, %{}, %{})

      records = Observer.records(observer)
      assert length(records) == 2
      assert Enum.all?(records, &(&1.attributes["chicago_mapping_error"] == "boom"))
      assert Observer.dropped(observer) == 0
      assert records |> Enum.map(& &1.seq) |> then(&(&1 == Enum.sort(&1)))

      Observer.stop(observer)
    end

    test "stimulus attribution scopes SUT events to the falsifier under attack" do
      event = [:ash_a2a, :chicago, :foundation_test, :sut]
      mapping = Mapping.new!(event: event, activity: "sut", source: __MODULE__)
      {:ok, observer} = Observer.start_link(run_id: "attr-run", mappings: [mapping])
      [f | _] = ChicagoSelfTest.Court.falsifiers()

      ctx = %Context{
        run_id: "attr-run",
        profile: :core,
        subject: nil,
        evidence_dir: "",
        observer: observer
      }

      :telemetry.execute(event, %{}, %{})
      Context.stimulus(ctx, f, fn -> :telemetry.execute(event, %{}, %{}) end)
      :telemetry.execute(event, %{}, %{})

      assert [
               %{activity: "chicago.stimulus.start"},
               %{activity: "sut"},
               %{activity: "chicago.stimulus.stop"}
             ] =
               Context.observed(ctx, f)

      assert length(Observer.records(observer)) == 5
      Observer.stop(observer)
    end
  end

  describe "exact subject identity" do
    test "capture binds the real revision and verify names every substituted identity" do
      subject = Subject.capture()
      {rev, 0} = System.cmd("git", ["rev-parse", "HEAD"])
      assert subject.source_revision == String.trim(rev)
      assert map_size(subject.artifact_digests) > 0

      clean = %{subject | dirty?: false}
      assert :ok = Subject.verify(clean, clean)

      [artifact | _] = Map.keys(subject.artifact_digests)

      substituted = %{
        clean
        | artifact_digests: Map.put(subject.artifact_digests, artifact, String.duplicate("f", 64))
      }

      assert {:error, {:subject_mismatch, [:artifact_digests]}} =
               Subject.verify(substituted, clean)

      moved = %{clean | source_revision: String.duplicate("a", 40)}
      assert {:error, {:subject_mismatch, [:source_revision]}} = Subject.verify(moved, clean)

      assert {:error, {:subject_mismatch, [:dirty?]}} =
               Subject.verify(clean, %{clean | dirty?: true})

      refute Subject.digest(substituted) == Subject.digest(clean)
    end
  end

  describe "profiles, discovery and refusal providers" do
    test "profiles are cumulative and strict requires all twelve gates" do
      assert Profile.applicable?(:core, :strict)
      refute Profile.applicable?(:do, :plan)
      assert Profile.required_gates(:strict) == Enum.to_list(1..12)
      assert Profile.parse("SA2A-DO") == {:ok, :do}
    end

    test "non-discoverable self-test courts never enter a real qualification run" do
      refute ChicagoSelfTest.Court in Chicago.courts()
      refute ChicagoSelfTest.LyingCourt in Chicago.courts()
    end

    test "a court's refusal codes classify without editing the Refusal table" do
      assert Refusal.classify(:chicago_selftest_refusal) == :refused_authority
      assert Refusal.mapping()[:chicago_selftest_refusal] == :refused_authority
    end
  end
end

# --- SECTION 15: Original test/ash_a2a/chicago/fresh_consumer_test.exs ---
defmodule AshA2A.Chicago.FreshConsumerTest do
  @moduledoc """
  Gate 11 fresh-consumer qualification (RFC-SA2A-002 §42, §74, §19, §139),
  Chicago style: real producer courts over the real CommandBus, real durable
  packages on disk, a real fresh `elixir` OS process as the consumer, real
  file mutations as fault injection, and the independent OCEL consumer
  corroborating every verdict.

  `async: false` -- the observer attributes telemetry emitted between a
  stimulus start and stop to that falsifier.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  import ExUnit.CaptureIO

  alias AshA2A.Chicago.{FreshConsumer, Result, Runner, StandingReceipt, Subject}
  alias AshA2A.Chicago.Courts.FreshConsumer, as: Court
  alias AshA2A.Chicago.Fixtures.FreshConsumer, as: F

  @moduletag :tmp_dir
  @moduletag timeout: 1_200_000

  describe "CHI-FRESH court, end to end" do
    test "every falsifier reaches its verdict and every pass is OCEL-corroborated", %{
      tmp_dir: dir
    } do
      assert {:ok, run} = Runner.run(courts: [Court], profile: :do, evidence_dir: dir)
      by_id = Map.new(run.results, &{&1.falsifier_id, &1})

      assert Enum.sort(Map.keys(by_id)) ==
               ~w(CHI-FRESH-001 CHI-FRESH-002 CHI-FRESH-003 CHI-FRESH-004 CHI-FRESH-005 CHI-FRESH-006)

      assert by_id["CHI-FRESH-001"].verdict == :positive_control_passed,
             inspect(by_id["CHI-FRESH-001"], pretty: true, limit: :infinity)

      for id <- ~w(CHI-FRESH-002 CHI-FRESH-003 CHI-FRESH-004 CHI-FRESH-005 CHI-FRESH-006) do
        assert by_id[id].verdict == :falsifier_killed,
               "#{id}: " <> inspect(by_id[id], pretty: true, limit: :infinity)
      end

      for result <- run.results do
        assert result.ocel_corroborated? == true, "#{result.falsifier_id}: #{result.ocel_detail}"
        assert Result.counts_as_pass?(result)
      end

      positive = by_id["CHI-FRESH-001"].evidence
      assert positive["outcome"] == "reproduced"
      assert positive["producer_observer_handlers_after_kill"] == 0
      assert positive["independent_reader_allowed_present"] == true
      assert positive["independent_reader_denied_absent"] == true
      assert positive["question_status"]["replayable_without_do"] == "ANSWERED"
      assert positive["question_status"]["plan"] == "UNKNOWN"

      # The fresh OS process is the load-bearing guard: in the producer VM,
      # where the hidden state still lives, the same package reproduces.
      hidden = by_id["CHI-FRESH-002"].evidence
      assert hidden["in_process_outcome"] == "reproduced"
      assert hidden["verdict"]["outcome"] == "diverged"
      assert "falsifier_corpus_digest_mismatch" in hidden["verdict"]["reasons"]

      deleted = by_id["CHI-FRESH-003"].evidence

      for file <- FreshConsumer.package_files() do
        assert deleted[file]["outcome"] == "refused"
        assert ("package_file_missing:" <> file) in deleted[file]["reasons"]
      end

      assert by_id["CHI-FRESH-005"].evidence["untampered_misaimed_control_outcome"] ==
               "reproduced"

      forged = by_id["CHI-FRESH-006"].evidence["forged"]
      assert forged["forged_digests_hold"] == true
      assert forged["reasons"] == ["ocel_run_mismatch"]

      assert Enum.find(run.receipt["gates"], &(&1["gate"] == 11))["status"] == "PASSED"
      assert run.receipt["evidence"]["fresh_consumer"] == "PASS"
      assert run.receipt["results"]["survived_ids"] == []

      # Self-application: this court's own qualification package reproduces
      # in a fresh consumer, and the verdict is observable at the boundary.
      :ok = attach(self())
      assert {:ok, verdict} = FreshConsumer.verify(dir)
      detach(self())
      assert verdict["outcome"] == "reproduced", inspect(verdict["checks"], pretty: true)
      assert verdict["standing"]["reconstructed"] == run.receipt["standing"]
      assert_received {:verified, %{outcome: :reproduced, fresh_process: true}}
    end
  end

  describe "StandingReceipt.recompute/1" do
    test "reproduces exactly what build/1 issued for a real run", %{tmp_dir: dir} do
      {:ok, run} = Runner.run(courts: [F.ProducerCourt], profile: :core, evidence_dir: dir)

      computed =
        StandingReceipt.recompute(%{
          profile: :core,
          courts: [%{id: F.ProducerCourt.id(), gate: F.ProducerCourt.gate()}],
          results: run.results,
          ocel_validation_status: run.ocel_validation.status,
          ocel_dropped: run.ocel.dropped,
          source_revision: run.subject.source_revision,
          court_revision: run.receipt["court"]["revision"]
        })

      assert computed.tallies == run.receipt["results"]
      assert computed.gate_rows == run.receipt["gates"]
      assert AshA2A.Chicago.FailureClass.wire(computed.standing) == run.receipt["standing"]
      assert computed.claim == run.receipt["claim"]
      assert computed.gate_evidence["fresh_consumer"] == run.receipt["evidence"]["fresh_consumer"]
      assert run.receipt["standing"] == "PARTIAL_ALIVE"
    end

    # Merge reconciliation with CHI-ID (§32): build/1 can issue REFUSED for a
    # claimed subject that does not verify, so recompute/1 -- and therefore a
    # fresh consumer -- must reproduce that standing, not re-derive one the
    # producer never issued.
    test "reproduces a §32 REFUSED standing; dropping the verification does not", %{
      tmp_dir: dir
    } do
      pkg = Path.join(dir, "refused")

      stale_claim =
        Subject.capture() |> Subject.to_map() |> Map.put("identity", String.duplicate("0", 64))

      {:ok, run} =
        Runner.run(
          courts: [F.ProducerCourt],
          profile: :core,
          claimed_subject: stale_claim,
          evidence_dir: pkg
        )

      assert run.receipt["standing"] == "REFUSED"
      assert run.receipt["subject"]["verification"]["outcome"] == "mismatch"

      facts = %{
        profile: :core,
        courts: [%{id: F.ProducerCourt.id(), gate: F.ProducerCourt.gate()}],
        results: run.results,
        ocel_validation_status: run.ocel_validation.status,
        ocel_dropped: run.ocel.dropped,
        ocel_gaps: run.receipt["evidence"]["ocel_gaps"],
        source_revision: run.subject.source_revision,
        court_revision: run.receipt["court"]["revision"]
      }

      verification =
        StandingReceipt.verification_from_map(run.receipt["subject"]["verification"])

      assert {:mismatch, nil, ["claimed_subject"]} = verification

      computed = StandingReceipt.recompute(Map.put(facts, :subject_verification, verification))

      assert AshA2A.Chicago.FailureClass.wire(computed.standing) == "REFUSED"
      assert computed.claim == run.receipt["claim"]
      assert computed.tallies == run.receipt["results"]
      assert computed.gate_rows == run.receipt["gates"]

      unverified = StandingReceipt.recompute(facts)
      refute AshA2A.Chicago.FailureClass.wire(unverified.standing) == "REFUSED"
      refute unverified.claim == run.receipt["claim"]

      verdict = FreshConsumer.verify_package(pkg)
      assert verdict["outcome"] == "reproduced", inspect(verdict["checks"], pretty: true)
      assert verdict["standing"]["recorded"] == "REFUSED"
      assert verdict["standing"]["reconstructed"] == "REFUSED"
    end

    test "a malformed receipt verification decodes fail-closed to :not_claimed" do
      assert StandingReceipt.verification_from_map(nil) == :not_claimed
      assert StandingReceipt.verification_from_map(%{"outcome" => "not_claimed"}) == :not_claimed

      assert StandingReceipt.verification_from_map(%{
               "outcome" => "mismatch",
               "claimed_identity" => 5,
               "fields" => ["tag"]
             }) == :not_claimed

      assert StandingReceipt.verification_from_map(%{
               "outcome" => "mismatch",
               "claimed_identity" => "abc",
               "fields" => [1]
             }) == :not_claimed

      assert StandingReceipt.verification_from_map(%{
               "outcome" => "match",
               "claimed_identity" => "abc",
               "fields" => []
             }) == {:match, "abc"}
    end
  end

  describe "FreshConsumer.verify_package/1 (pure, in-process)" do
    setup %{tmp_dir: dir} do
      pkg = Path.join(dir, "pkg")
      {:ok, run} = Runner.run(courts: [F.ProducerCourt], profile: :core, evidence_dir: pkg)
      %{pkg: pkg, run: run}
    end

    test "an intact package reproduces and answers the §74 questions from disk", %{
      pkg: pkg,
      run: run
    } do
      verdict = FreshConsumer.verify_package(pkg)

      assert verdict["outcome"] == "reproduced", inspect(verdict["checks"], pretty: true)
      assert verdict["reasons"] == []
      assert verdict["package"]["run_id"] == run.run_id
      assert verdict["standing"]["reconstructed"] == "PARTIAL_ALIVE"

      q = verdict["questions"]
      assert q["semantic_object"]["status"] == "ANSWERED"
      assert q["semantic_object"]["answer"]["capabilities"] == ["capability:" <> F.capability()]
      assert [_record] = q["semantic_object"]["answer"]["acted_on"]
      assert q["prepared_before_actuation"]["answer"] == true
      assert q["plan"]["status"] == "UNKNOWN"
      assert q["authority_grant"]["status"] == "UNKNOWN"
      assert q["independent_consequence"]["status"] == "UNKNOWN"
      # In the producer VM :ash_a2a is started, so DO-free replay is not shown.
      assert q["replayable_without_do"]["status"] == "UNKNOWN"
    end

    test "a missing file is refused with no standing inferred", %{pkg: pkg} do
      File.rm!(Path.join(pkg, "subject.json"))
      verdict = FreshConsumer.verify_package(pkg)

      assert verdict["outcome"] == "refused"
      assert verdict["reasons"] == ["package_file_missing:subject.json"]
      assert verdict["standing"]["reconstructed"] == nil
      assert Enum.all?(verdict["questions"], fn {_q, a} -> a["status"] == "UNKNOWN" end)
    end

    test "a rewritten verdict diverges on the recorded standing", %{pkg: pkg} do
      path = Path.join(pkg, "results.json")

      results =
        path
        |> File.read!()
        |> JSON.decode!()
        |> Enum.map(fn
          %{"verdict" => "POSITIVE_CONTROL_PASSED"} = r ->
            %{r | "verdict" => "POSITIVE_CONTROL_FAILED"}

          r ->
            r
        end)

      File.write!(path, AshA2A.Chicago.Json.canonical(results))
      verdict = FreshConsumer.verify_package(pkg)

      assert verdict["outcome"] == "diverged"
      assert verdict["standing"]["recorded"] == "NONCONFORMANT"
      assert Enum.any?(verdict["reasons"], &(&1 =~ ~r/^recorded_projection_mismatch:.*standing/))
    end

    test "an undecodable verdict is refused", %{pkg: pkg} do
      path = Path.join(pkg, "results.json")

      results =
        path |> File.read!() |> JSON.decode!() |> Enum.map(&Map.put(&1, "verdict", "PASSED"))

      File.write!(path, AshA2A.Chicago.Json.canonical(results))
      verdict = FreshConsumer.verify_package(pkg)

      assert verdict["outcome"] == "refused"
      assert verdict["reasons"] == ["results_undecodable"]
    end

    test "main/1 prints exactly one parseable verdict line", %{pkg: pkg} do
      output = capture_io(fn -> FreshConsumer.main([pkg]) end)
      assert [line] = String.split(output, "\n", trim: true)
      assert "SA2A-FRESH-CONSUMER-VERDICT " <> json = line
      assert %{"outcome" => "reproduced", "schema" => schema} = JSON.decode!(json)
      assert schema == FreshConsumer.schema()

      output = capture_io(fn -> FreshConsumer.main([]) end)
      assert output =~ ~s("outcome":"refused")
    end
  end

  describe "FreshConsumer.verify/2 local acceptance boundary" do
    setup do
      test_pid = self()
      :ok = attach(test_pid)
      on_exit(fn -> detach(test_pid) end)
    end

    test "a genuinely fresh OS process reproduces a package whose producer is dead", %{
      tmp_dir: dir
    } do
      pkg = Path.join(dir, "pkg")
      parent = self()

      producer =
        spawn(fn ->
          send(parent, {:produced, Runner.run(courts: [F.ProducerCourt], evidence_dir: pkg)})
        end)

      assert_receive {:produced, {:ok, _run}}, 120_000
      ref = Process.monitor(producer)
      assert_receive {:DOWN, ^ref, :process, ^producer, _}

      assert {:ok, verdict} = FreshConsumer.verify(pkg, producer: producer)
      assert verdict["outcome"] == "reproduced", inspect(verdict, pretty: true)
      assert verdict["fresh_process_accepted"] == true
      assert verdict["producer_terminated"] == true
      assert verdict["child"]["os_pid"] != nil
      assert verdict["fresh_process"]["os_pid"] != System.pid()
      assert verdict["fresh_process"]["ash_a2a_started"] == false
      assert verdict["fresh_process"]["do_boundary_loaded"] == false
      assert verdict["questions"]["replayable_without_do"]["answer"] == true

      assert_received {:verified,
                       %{outcome: :reproduced, fresh_process: true, producer_terminated: true}}
    end

    test "a consumer that exits without a verdict is refused", %{tmp_dir: dir} do
      assert {:ok, verdict} = FreshConsumer.verify(dir, elixir: System.find_executable("false"))
      assert verdict["outcome"] == "refused"
      assert verdict["reasons"] == ["fresh_consumer_no_verdict"]
      assert_received {:verified, %{outcome: :refused, fresh_process: false}}
    end

    test "a verdict not provably from the spawned fresh process is refused", %{tmp_dir: dir} do
      # A lying consumer executable: claims `reproduced` from the producer's
      # own OS pid with the application started.
      liar = Path.join(dir, "lying_consumer.sh")

      verdict =
        JSON.encode!(%{
          "schema" => FreshConsumer.schema(),
          "outcome" => "reproduced",
          "reasons" => [],
          "fresh_process" => %{"os_pid" => System.pid(), "ash_a2a_started" => true}
        })

      File.write!(liar, "#!/bin/sh\nprintf '%s\\n' 'SA2A-FRESH-CONSUMER-VERDICT #{verdict}'\n")
      File.chmod!(liar, 0o755)

      assert {:ok, accepted} = FreshConsumer.verify(dir, elixir: liar)
      assert accepted["outcome"] == "refused"
      assert "not_a_fresh_process:producer_os_pid" in accepted["reasons"]
      assert "not_a_fresh_process:os_pid_unbound" in accepted["reasons"]
      assert "not_a_fresh_process:ash_a2a_started" in accepted["reasons"]
      assert_received {:verified, %{outcome: :refused}}
    end
  end

  defp attach(pid) do
    :telemetry.attach(
      {__MODULE__, pid},
      FreshConsumer.event(),
      &__MODULE__.forward_verified/4,
      pid
    )
  end

  defp detach(pid), do: :telemetry.detach({__MODULE__, pid})

  @doc false
  def forward_verified(_event, _measurements, metadata, test_pid),
    do: send(test_pid, {:verified, metadata})
end

# --- SECTION 16: Original test/ash_a2a/chicago/graphlaw_engine_stop_host_test.exs ---
defmodule AshA2A.Chicago.GraphlawEngineStopHostTest do
  @moduledoc """
  Permanent guard for a TOCTOU race in `AshA2A.Chicago.Fixtures.GraphlawEngine.stop_host/1`
  (`errc/ash-a2a-format`): the host is linked to the test process, so it can die between
  `Process.whereis/1` and `GenServer.stop/3`, failing an otherwise-passing test with
  `** (exit) no process` from its `on_exit` callback (seen once in a full `mix test` under
  load; not reproducible in isolation, hence this deterministic reconstruction).

  Real processes only: a real `WasmexHost` over the real vendored wasm, a real `Process.exit/2`
  kill, and a real dead pid. No collaborator is faked.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Chicago.Fixtures.GraphlawEngine, as: F

  test "stop_pid/1 on a pid that has already exited returns :ok instead of exiting :noproc" do
    name = F.start_host()
    pid = Process.whereis(name)
    ref = Process.monitor(pid)

    Process.unlink(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 5_000
    refute Process.alive?(pid)

    # The exact interleaving the race produces: a pid captured while alive, stopped after it died.
    assert F.stop_pid(pid) == :ok
  end

  test "stop_host/1 stops a live host and leaves no process behind" do
    name = F.start_host()
    pid = Process.whereis(name)
    assert is_pid(pid) and Process.alive?(pid)

    Process.unlink(pid)
    assert F.stop_host(name) == :ok
    refute Process.alive?(pid)
    assert Process.whereis(name) == nil
  end

  test "stop_host/1 on a name that is not registered returns :ok" do
    assert F.stop_host(Module.concat(F, "NeverStarted#{System.unique_integer([:positive])}")) ==
             :ok
  end
end

# --- SECTION 17: Original test/ash_a2a/chicago/graphlaw_engine_test.exs ---
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

  @moduletag :serial
  @moduletag :serial_shard
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

# --- SECTION 18: Original test/ash_a2a/chicago/hooks_cascade_test.exs ---
