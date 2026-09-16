defmodule AshA2A.Chicago.Courts.Benchmarks do
  @moduledoc """
  RFC-SA2A-002 benchmark court `SA2A-BENCH` (§84, §85, §89, §93, §102, §122,
  §135, Appendix E).

  Runs benchmarks B1 (admission), B5 (authority / BRCE) and B9 (OCEL evidence
  overhead) against the real SUT as `:measurement` falsifiers. Each benchmark
  is one `AshA2A.Chicago.Context.stimulus/3`, so every real boundary event it
  causes is attributed to its falsifier in the independent OCEL artifact, and
  the attempt predicates require the real SUT activities (admission stages,
  grant decisions, prepared receipts, actuations, commits) -- a benchmark that
  never exercised the SUT cannot be corroborated.

  Each raw result is written content-addressed under
  `<evidence_dir>/bench/` with the §102 environment receipt and the run's exact
  subject, re-verified from disk (§135), and its digest is carried in the
  result's measurements (and therefore bound by the standing receipt).

  A benchmark is reported `:measured` only when it executed, produced zero
  semantic invariant failures, and its raw result verifies (§84: no throughput
  number compensates for a violated invariant). An invariant failure is
  reported as `:unknown` with the failed transition's class and the raw
  result still written -- never hidden. A host without the real GraphLaw
  engine reports B1 `:blocked`, never a substituted engine.

  Context options (`AshA2A.Chicago.Runner.run/1` passes unknown options
  through): `:bench_iterations` (default 5), `:bench_warmup` (default 1),
  `:bench_b1_cases` (B1 corpus override; the corpus digest is recorded).
  """

  use AshA2A.Chicago.Court

  alias AshA2A.Chicago.{Bench, Context, Falsifier, Result}
  alias AshA2A.Chicago.Bench.{B1Admission, B5Authority, B9OcelOverhead, Environment}
  alias AshA2A.Chicago.Courts.AuthorityHarness

  @court "SA2A-BENCH"

  @impl true
  def id, do: @court

  @impl true
  def title, do: "Benchmark harness: B1 admission, B5 authority/BRCE, B9 OCEL evidence overhead"

  @impl true
  def gate, do: nil

  @impl true
  def profile, do: :core

  @impl true
  def rfc_sections, do: ["§84", "§85", "§89", "§93", "§102", "§122", "§135", "Appendix E"]

  @doc """
  Refusal codes introduced by `AshA2A.Chicago.Bench` (raw-result integrity,
  §135; benchmark selection) and `AshA2A.Chicago.Bench.Regression` (§122
  comparability), classified without editing `AshA2A.Semantic.Refusal`.
  """
  @impl true
  def refusal_codes do
    %{
      not_a_bench_raw_result: :refused_structure,
      raw_result_non_json: :refused_structure,
      raw_result_digest_mismatch: :refused_identity,
      content_address_mismatch: :refused_identity,
      unknown_benchmarks: :refused_capability,
      not_comparable: :refused_identity
    }
  end

  # The grant decision is the ONE `[:ash_a2a, :authority, :decision]` event
  # `AshA2A.Authority.Grant.authorize/3` emits (union metadata: `:outcome`,
  # `:reason`, `:code`, `:policy`, ...); its OCEL mapping is the shared
  # `AshA2A.Chicago.Courts.AuthorityHarness` one, so a run with this court,
  # CHI-REAL and the SA2A-AUTH courts admits it once (one emission, one OCEL
  # event).
  @impl true
  def ocel_mappings do
    Enum.filter(AuthorityHarness.mappings(), &(&1.event == B5Authority.grant_event()))
  end

  @impl true
  def falsifiers do
    [
      Falsifier.new!(
        id: "SA2A-BENCH-001",
        court_id: @court,
        kind: :measurement,
        invariant:
          "B1: admission latency and throughput are reported for valid AND invalid candidates through the real AdmissionPipeline + GraphLaw, and every admission decision matches its corpus expectation (§84, §85)",
        stimulus:
          "AshA2A.Chicago.Bench.B1Admission.run/1: warmup + N iterations over the admission corpus (1 lawful, 5 invalid: parse, ShEx, SHACL, falsifier, provenance)",
        boundary: "AshA2A.Semantic.AdmissionPipeline.admit/2 (real praxis-graphlaw wasm)",
        forbidden_outcome:
          "a latency/throughput figure reported while an invalid candidate was admitted, a lawful one refused, or invalid candidates were skipped from cost",
        attempt_evidence:
          "admission.start, admission.stage (shacl ok, profile_checks ok, parse refused) and admission.stop admitted AND refused events emitted by the real pipeline, attributed to this stimulus",
        survival_evidence:
          "invariant_failures in the content-addressed raw result; verdict :unknown instead of :measured",
        guard: "B1Admission invariant check per sample + court measured/unknown split",
        failure_class: :admission_failure,
        rfc_sections: ["§84", "§85", "§135"],
        attempt_predicate:
          {:all,
           [
             {:observed, "admission.start"},
             {:observed, "admission.stage", %{"stage" => "shacl", "outcome" => "ok"}},
             {:observed, "admission.stage", %{"stage" => "parse", "outcome" => "refused"}},
             {:observed, "admission.stop", %{"outcome" => "admitted"}},
             {:observed, "admission.stop", %{"outcome" => "refused"}}
           ]},
        outcome_predicate:
          {:all,
           [
             {:precedes, "admission.start", "admission.stop"},
             {:observed, "admission.stage", %{"stage" => "profile_checks", "outcome" => "ok"}}
           ]}
      ),
      Falsifier.new!(
        id: "SA2A-BENCH-002",
        court_id: @court,
        kind: :measurement,
        invariant:
          "B5: authority decision, prepared-receipt durability, actuator, final-receipt, independent-postcondition and end-to-end latency are reported separately for authorized, refused, expired, revoked and broker-unavailable paths, with every path keeping its authority/BRCE semantics (§84, §89)",
        stimulus:
          "AshA2A.Chicago.Bench.B5Authority.run/1: warmup + N iterations of five scenarios through Grant.authorize/3 and CommandBus.run/4",
        boundary:
          "AshA2A.Authority.Grant.authorize/3 (real InMemory broker) + AshA2A.CommandBus.run/4 (sole DO boundary)",
        forbidden_outcome:
          "a latency figure reported while a refused/expired/revoked/broker-unavailable command actuated, or an authorized command actuated without a prepared receipt",
        attempt_evidence:
          "authority.decision granted AND refused, brce.admission admitted AND refused(authority_required), brce.prepare prepared, brce.actuate.stop ok, brce.commit committed attributed to this stimulus",
        survival_evidence:
          "invariant_failures in the raw result (actuation on a refusal path, missing prepared receipt, row visible after refusal)",
        guard: "B5Authority invariant check per sample + court measured/unknown split",
        failure_class: :authority_failure,
        rfc_sections: ["§84", "§89", "§135"],
        attempt_predicate:
          {:all,
           [
             {:observed, "authority.decision", %{"outcome" => "granted"}},
             {:observed, "authority.decision", %{"outcome" => "refused"}},
             {:observed, "brce.admission", %{"outcome" => "admitted"}},
             {:observed, "brce.admission",
              %{"outcome" => "refused", "code" => "authority_required"}},
             {:observed, "brce.prepare", %{"outcome" => "prepared"}},
             {:observed, "brce.actuate.stop", %{"outcome" => "ok"}},
             {:observed, "brce.commit", %{"outcome" => "committed"}}
           ]},
        outcome_predicate:
          {:all,
           [
             {:precedes, "brce.prepare", "brce.actuate.start", "command"},
             {:precedes, "brce.actuate.stop", "brce.commit", "command"},
             {:not_observed, "brce.commit", %{"outcome" => "failed"}}
           ]}
      ),
      Falsifier.new!(
        id: "SA2A-BENCH-003",
        court_id: @court,
        kind: :measurement,
        invariant:
          "B9: the incremental cost of independent OCEL evidence (events, objects, size, observer CPU/memory, serialization, validation, query) is measured over a real consequence workload without disabling evidence, and the measured evidence stays complete (§84, §93)",
        stimulus:
          "AshA2A.Chicago.Bench.B9OcelOverhead.run/1: the B5 authorized workload in a baseline arm and an arm with a real Observer attached, then flush, validate and query",
        boundary:
          "AshA2A.CommandBus.run/4 boundary telemetry -> AshA2A.Chicago.Observer -> AshA2A.Chicago.Query",
        forbidden_outcome:
          "an overhead figure reported while the observer dropped records, the artifact failed its digest, or BRCE ordering queries failed",
        attempt_evidence:
          "brce.prepare prepared, brce.actuate.start, brce.commit committed and receipt.committed events of the measured workload attributed to this stimulus",
        survival_evidence:
          "evidence invariant failures in the raw result (dropped > 0, too few events, failed conformance query)",
        guard: "B9OcelOverhead evidence invariants + court measured/unknown split",
        failure_class: :ocel_evidence_incomplete,
        rfc_sections: ["§84", "§93", "§135"],
        attempt_predicate:
          {:all,
           [
             {:observed, "brce.prepare", %{"outcome" => "prepared"}},
             {:observed, "brce.actuate.start"},
             {:observed, "brce.commit", %{"outcome" => "committed"}},
             {:observed, "receipt.committed"}
           ]},
        outcome_predicate:
          {:all,
           [
             {:precedes, "brce.prepare", "brce.actuate.start", "command"},
             {:precedes, "brce.actuate.stop", "brce.commit", "command"}
           ]}
      )
    ]
  end

  @impl true
  def run(%Context{} = ctx) do
    [b1, b5, b9] = falsifiers()
    out = Path.join(ctx.evidence_dir, "bench")

    opts =
      [
        iterations: Keyword.get(ctx.opts, :bench_iterations, 5),
        warmup: Keyword.get(ctx.opts, :bench_warmup, 1),
        out: out
      ] ++
        case Keyword.get(ctx.opts, :bench_b1_cases) do
          nil -> []
          cases -> [cases: cases]
        end

    record_opts = [
      subject: ctx.subject,
      environment: Environment.capture(),
      profile: ctx.profile,
      run_id: ctx.run_id
    ]

    [
      measure(ctx, b1, B1Admission, opts, record_opts, ["admission.stop"]),
      measure(ctx, b5, B5Authority, opts, record_opts, ["authority.decision", "brce.commit"]),
      measure(ctx, b9, B9OcelOverhead, opts, record_opts, ["brce.commit"])
    ]
  end

  defp measure(ctx, falsifier, bench, opts, record_opts, activities) do
    outcome =
      try do
        Context.stimulus(ctx, falsifier, fn -> bench.run(opts) end)
      rescue
        exception -> {:raised, Exception.format(:error, exception, __STACKTRACE__)}
      catch
        kind, reason -> {:raised, "#{kind}: #{inspect(reason, limit: 20)}"}
      end

    case outcome do
      {:ok, body} ->
        judge(ctx, falsifier, bench, body, opts, record_opts, activities)

      {:blocked, detail} ->
        Result.blocked(falsifier, detail, :resource_blocked)

      {:raised, detail} ->
        Result.unknown(falsifier, "benchmark #{bench.id()} raised: #{detail}")
    end
  end

  defp judge(ctx, falsifier, bench, body, opts, record_opts, activities) do
    record = Bench.record(bench.id(), body, record_opts)
    written = Bench.write!(record, Keyword.fetch!(opts, :out))
    measurements = Bench.summary(record, written)
    evidence = %{"raw_result_path" => written.path, "raw_result_digest" => written.digest}
    failures = record["invariant_failure_count"]

    case Bench.verify_file(written.path) do
      {:error, reason} ->
        unknown(
          falsifier,
          "raw result #{written.path} failed integrity verification: #{inspect(reason)}",
          :fresh_consumer_failure,
          measurements,
          evidence
        )

      {:ok, _raw} when failures > 0 ->
        unknown(
          falsifier,
          "#{failures} semantic invariant failure(s) observed during #{bench.id()}; " <>
            "reported, never measured (§84): " <>
            Enum.map_join(Enum.take(record["invariant_failures"], 3), "; ", & &1["detail"]),
          falsifier.failure_class,
          measurements,
          evidence
        )

      {:ok, _raw} ->
        Result.measured(falsifier,
          attempt_observed?: Enum.all?(activities, &Context.observed?(ctx, falsifier, &1)),
          measurements: measurements,
          evidence: evidence,
          detail:
            "#{bench.id()} #{record["iterations"]} iterations; p50 #{record["latency_us"]["p50"]}us p99 #{record["latency_us"]["p99"]}us"
        )
    end
  end

  defp unknown(falsifier, detail, class, measurements, evidence) do
    %{
      Result.unknown(falsifier, detail, class)
      | measurements: measurements,
        evidence: evidence
    }
  end
end
