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
