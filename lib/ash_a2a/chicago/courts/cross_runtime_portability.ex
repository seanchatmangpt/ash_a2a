defmodule AshA2A.Chicago.Courts.CrossRuntimePortability do
  @moduledoc """
  SA2A-XRUNTIME -- Cross-Runtime Portable Semantic Execution (RFC-SA2A-002
  §76, §91 Benchmark B7, §125 determinism, §126 heterogeneous runtimes).

  One content-addressed GraphLaw wasm artifact
  (`priv/graphlaw/praxis_graphlaw.wasm`) executed by genuinely heterogeneous
  real hosts -- the in-BEAM Wasmtime NIF (`AshA2A.GraphLaw.WasmexSession`), a
  standalone V8 subprocess (`AshA2A.GraphLaw.RuntimeB`) and the native
  Wasmtime binary (`AshA2A.GraphLaw.WasmtimeRuntime`) -- judged by the real
  `AshA2A.SA2A.Conformance` court over real corpora on disk
  (`AshA2A.Chicago.Fixtures.CrossRuntime`).

    * SA2A-XRUNTIME-001, 002 -- positive controls (§76, §100): two
      heterogeneous host pairs agree, per fixture, on admission, refusal
      class, input identity and canonical post-state, and the negative fixture
      is refused by both.
    * 003 -- a document that is not Turtle, which the engine hashes and admits
      (`{:ok, <degenerate result>}`), must be refused with an equivalent
      refusal class, never agreed upon as admitted.
    * 004 -- one content-addressed degenerate artifact whose every export
      returns `{}`, executed by two real heterogeneous hosts: agreement on
      nothing must not count as agreement.
    * 005, 006 -- same-runtime masquerades (a decoy process in the session; the
      engine hidden behind an `Agent`) must be refused on the engine the call
      actually executed on (§126), never judged.
    * 007, 009 -- determinism (§125): replaying a durable receipt with
      identical admitted inputs agrees on every semantic identity (007), and a
      replay after one fixture changed reports the divergence (009, positive
      control).
    * 008 -- an input identity that is not a function of the input (the
      unstable blank-node graph hash, `v006_blank_nodes`) must not acquire
      input-identity agreement.
    * 010 -- Benchmark SA2A-B7: host identities, artifact digest, fixture
      count, admission/refusal/post-state equivalence counts, latency and
      memory per host.

  A host that is not available on this machine makes the falsifiers that need
  it BLOCKED -- never killed, never passed. Attempt evidence is always the
  deciding boundary's own telemetry (`[:ash_a2a, :sa2a, :conformance,
  :runtime_identity | :vector_judged | :judged | :replayed]`), keyed on the
  decision being reached regardless of its outcome; survival is read back from
  the durable receipts the court persists and from the OCEL artifact.
  """

  use AshA2A.Chicago.Court

  alias AshA2A.Chicago.{Context, Falsifier, Result}
  alias AshA2A.Chicago.Courts.ExactIdentity
  alias AshA2A.Chicago.Fixtures.CrossRuntime, as: Fx
  alias AshA2A.Chicago.Ocel.Mapping
  alias AshA2A.GraphLaw.{RuntimeB, WasmexSession, WasmtimeRuntime}
  alias AshA2A.RuntimeIdentity.Execution
  alias AshA2A.SA2A.Conformance

  @court "SA2A-XRUNTIME"
  @judge "AshA2A.SA2A.Conformance.run/1 per-vector judgement (judge/3)"
  @identity "AshA2A.SA2A.Conformance runtime-identity refusal (refuse_same_executable)"
  @replay "AshA2A.SA2A.Conformance.replay/2"

  @admit "v001_minimal_admit"
  @shacl_refusal "v004_shacl_min_count_violation"
  @shex_refusal "v009_shex_violation"
  @unstable "v006_blank_nodes"
  @native_subset [@admit, @shacl_refusal, @shex_refusal]

  @identity_activity "sa2a.conformance.runtime_identity"
  @vector_activity "sa2a.conformance.vector_judged"
  @judged_activity "sa2a.conformance.judged"
  @replayed_activity "sa2a.conformance.replayed"

  @impl true
  def id, do: @court

  @impl true
  def title, do: "Cross-runtime portable semantic execution (one artifact, heterogeneous hosts)"

  @impl true
  def gate, do: nil

  @impl true
  def profile, do: :core

  @impl true
  def rfc_sections, do: ["§76", "§91", "§100", "§125", "§126"]

  # --- falsifiers (§11) --------------------------------------------------------

  @impl true
  def falsifiers do
    malformed = Fx.negative_id(:malformed_turtle)

    [
      agreement_control(
        1,
        "BEAM/Wasmex (in-BEAM Wasmtime NIF) x Node/StandaloneJS (V8 subprocess)",
        "Conformance.run(runtime_a: WasmexSession, runtime_b: RuntimeB) over the full real " <>
          "corpus plus the #{malformed} negative fixture"
      ),
      agreement_control(
        2,
        "Node/StandaloneJS (V8 subprocess) x Native/graphlaw_host (Wasmtime binary)",
        "Conformance.run(runtime_a: RuntimeB, runtime_b: WasmtimeRuntime) over " <>
          "#{Enum.join(@native_subset, ", ")} plus #{malformed}"
      ),
      Falsifier.new!(
        id: fid(3),
        court_id: @court,
        kind: :negative,
        invariant:
          "Equivalent negative fixtures produce equivalent refusal classes (§76): a document that " <>
            "is not RDF 1.1 Turtle is refused by every host, never agreed upon as admitted",
        stimulus:
          "Conformance.run(WasmexSession x RuntimeB) over #{@admit} + #{malformed}; the engine " <>
            "hashes the malformed bytes and its validate_all/run_hooks answer ADMITTED",
        boundary: @judge,
        forbidden_outcome:
          "#{malformed} judged ADMITTED by either host, or refused with non-equivalent classes",
        attempt_evidence: "#{@vector_activity} for #{malformed} (the fixture reached the judge)",
        survival_evidence:
          "#{@vector_activity} vector=#{malformed} with admission_a/admission_b=ADMITTED or " <>
            "refusal_equal=false; durable receipt shows the same",
        guard:
          "AshA2A.SA2A.StateMachine PARSED hop admits only input the S12 primitive " <>
            "(AshA2A.Semantic.CanonicalGraph.parse/1) parses; an engine digest alone is not PARSED",
        failure_class: :cross_runtime_divergence,
        rfc_sections: ["§76", "§100"],
        attempt_predicate: {:observed, @vector_activity, %{"vector" => malformed}},
        outcome_predicate:
          {:any,
           [
             {:observed, @vector_activity, %{"vector" => malformed, "admission_a" => "ADMITTED"}},
             {:observed, @vector_activity, %{"vector" => malformed, "admission_b" => "ADMITTED"}},
             {:observed, @vector_activity, %{"vector" => malformed, "refusal_equal" => "false"}}
           ]}
      ),
      Falsifier.new!(
        id: fid(4),
        court_id: @court,
        kind: :negative,
        invariant:
          "A runtime returning {:ok, <degenerate result>} cannot count as agreement: two " <>
            "heterogeneous hosts executing one artifact that computes nothing do not conform",
        stimulus:
          "Conformance.run(WasmexSession x RuntimeB, wasm_path: <degenerate artifact whose every " <>
            "GraphLaw export returns \"{}\">) over #{@admit} + #{@shacl_refusal}",
        boundary: @judge,
        forbidden_outcome: "a degenerate observation judged computed, or the run judged PASS",
        attempt_evidence: "#{@vector_activity} observed (degenerate results reached the judge)",
        survival_evidence:
          "#{@vector_activity} computed=true, or #{@judged_activity} result=PASS; durable " <>
            "receipt with computed vectors or result PASS",
        guard:
          "Conformance result-shape admission: digest calls must return 64-hex digests, " <>
            "validate_all a graph_hash + dialect list, run_hooks a status + verdict list; " <>
            "anything else is :sa2a_degenerate_result, not computed",
        failure_class: :cross_runtime_divergence,
        rfc_sections: ["§76", "§125"],
        attempt_predicate: {:observed, @vector_activity},
        outcome_predicate:
          {:any,
           [
             {:observed, @vector_activity, %{"computed" => "true"}},
             {:observed, @judged_activity, %{"result" => "PASS"}}
           ]}
      ),
      masquerade(
        5,
        "a WasmexSession wrapper whose session also names a real idle decoy process " <>
          "(labels WASI/DecoyHost + wamr)",
        "Fx.DecoyResourceRuntime"
      ),
      masquerade(
        6,
        "a WasmexSession wrapper that executes every call inside an Agent, so its session " <>
          "names no engine (labels WASI/IsolatedHost + wasmer)",
        "Fx.HiddenEngineRuntime"
      ),
      Falsifier.new!(
        id: fid(7),
        court_id: @court,
        kind: :negative,
        invariant:
          "Determinism (§125): identical admitted inputs, one artifact, deterministic environment " <>
            "reproduce equivalent semantic results in fresh host instances",
        stimulus:
          "a durable Conformance receipt (WasmexSession x RuntimeB over #{@admit}, " <>
            "#{@shacl_refusal}, #{@unstable}, v008_hook_event_delta, #{malformed}) read back " <>
            "from disk and replayed with Conformance.replay/2 over the unchanged corpus",
        boundary: @replay,
        forbidden_outcome: "replay diverged on a semantic identity",
        attempt_evidence: "#{@replayed_activity} observed (any outcome)",
        survival_evidence:
          "#{@replayed_activity} outcome=diverged, or the court's independent comparison of the " <>
            "two durable receipts finds a semantic divergence",
        guard:
          "pinned deterministic getRandomValues import in every host + replay compares semantic " <>
            "identities only, never latency/memory/observed-host metadata (§125)",
        failure_class: :replay_failure,
        rfc_sections: ["§125"],
        attempt_predicate: {:observed, @replayed_activity},
        outcome_predicate: {:observed, @replayed_activity, %{"outcome" => "diverged"}}
      ),
      Falsifier.new!(
        id: fid(8),
        court_id: @court,
        kind: :negative,
        invariant:
          "An input identity that is not a function of the input cannot acquire input-identity " <>
            "agreement, however digit-for-digit the hosts agree (§125, §76)",
        stimulus:
          "Conformance.run(WasmexSession x RuntimeB) over #{@unstable}, whose engine graph_hash " <>
            "changes on repetition within one instance identically in both hosts",
        boundary: @judge,
        forbidden_outcome: "#{@unstable} judged input_identity_equal=true",
        attempt_evidence: "#{@vector_activity} for #{@unstable}",
        survival_evidence:
          "#{@vector_activity} vector=#{@unstable} input_identity_equal=true, or the durable " <>
            "receipt's same_input_identity computed and true",
        guard: "Conformance same_input_identity within-runtime stability check (repeat hash)",
        failure_class: :cross_runtime_divergence,
        rfc_sections: ["§125"],
        attempt_predicate: {:observed, @vector_activity, %{"vector" => @unstable}},
        outcome_predicate:
          {:observed, @vector_activity,
           %{"vector" => @unstable, "input_identity_equal" => "true"}}
      ),
      Falsifier.new!(
        id: fid(9),
        court_id: @court,
        kind: :positive_control,
        invariant:
          "The determinism check discriminates (§100): a replay after one admitted input changed " <>
            "reports the divergence rather than agreeing with everything",
        stimulus:
          "durable receipt over #{@admit} + #{@shacl_refusal} read back from disk; one triple " <>
            "appended to #{@admit}/base.ttl on disk; Conformance.replay/2",
        boundary: @replay,
        attempt_evidence: "#{@replayed_activity} observed (any outcome)",
        survival_evidence:
          "#{@replayed_activity} outcome=diverged naming #{@admit}; the independent comparison " <>
            "of the two durable receipts agrees",
        rfc_sections: ["§100", "§125"],
        attempt_predicate: {:observed, @replayed_activity},
        outcome_predicate: {:observed, @replayed_activity, %{"outcome" => "diverged"}}
      ),
      Falsifier.new!(
        id: fid(10),
        court_id: @court,
        kind: :measurement,
        invariant:
          "Benchmark SA2A-B7 (§91): one exact artifact executed by heterogeneous hosts, measured " <>
            "on the real judged path; a disagreement is a conformance defect before a result",
        stimulus:
          "Execution.meter around Conformance.run(WasmexSession x RuntimeB) over the full corpus " <>
            "+ #{malformed}, and (when built) RuntimeB x WasmtimeRuntime over the native subset",
        boundary: @judge,
        attempt_evidence: "#{@judged_activity} observed for the measured run",
        survival_evidence:
          "host identities, artifact digest, fixture count, admission/refusal/post-state " <>
            "equivalence counts, latency and memory per host from the durable receipts + meter",
        rfc_sections: ["§91"],
        attempt_predicate: {:observed, @judged_activity},
        outcome_predicate: {:count, @vector_activity, :gte, 1},
        tags: [:benchmark]
      )
    ]
  end

  defp fid(n), do: @court <> "-" <> String.pad_leading(Integer.to_string(n), 3, "0")

  defp agreement_control(n, hosts, stimulus) do
    malformed = Fx.negative_id(:malformed_turtle)

    Falsifier.new!(
      id: fid(n),
      court_id: @court,
      kind: :positive_control,
      invariant:
        "One content-addressed artifact on heterogeneous hosts (#{hosts}): Runtime_A != " <>
          "Runtime_B on the engine each call executed on, Artifact_A = Artifact_B, and per " <>
          "fixture Admission_A = Admission_B and CanonicalPostState_A = CanonicalPostState_B; " <>
          "the negative fixture is refused by both (§76, §100, §126)",
      stimulus: stimulus,
      boundary: @judge,
      attempt_evidence: "#{@vector_activity} observed (fixtures reached the judge)",
      survival_evidence:
        "runtime_identity outcome=distinct before judgement; no fixture computed=false, " <>
          "admission_equal=false, refusal_equal=false or post_state_equal=false; #{@admit} " <>
          "ADMITTED and #{malformed} REFUSED by both hosts",
      rfc_sections: ["§76", "§100", "§126"],
      attempt_predicate: {:observed, @vector_activity},
      outcome_predicate:
        {:all,
         [
           {:observed, @identity_activity, %{"outcome" => "distinct"}},
           {:precedes, @identity_activity, @vector_activity},
           {:not_observed, @vector_activity, %{"computed" => "false"}},
           {:not_observed, @vector_activity, %{"admission_equal" => "false"}},
           {:not_observed, @vector_activity, %{"refusal_equal" => "false"}},
           {:not_observed, @vector_activity, %{"post_state_equal" => "false"}},
           {:observed, @vector_activity,
            %{
              "vector" => @admit,
              "admission_a" => "ADMITTED",
              "admission_b" => "ADMITTED",
              "input_identity_equal" => "true"
            }},
           {:observed, @vector_activity,
            %{"vector" => @shacl_refusal, "admission_a" => "REFUSED", "refusal_equal" => "true"}},
           {:observed, @vector_activity,
            %{"vector" => malformed, "admission_a" => "REFUSED", "admission_b" => "REFUSED"}}
         ]}
    )
  end

  defp masquerade(n, description, module) do
    Falsifier.new!(
      id: fid(n),
      court_id: @court,
      kind: :negative,
      invariant:
        "Same-runtime masquerade is refused: heterogeneity is established from the engine the " <>
          "calls actually executed on, not from labels or the session term (§126)",
      stimulus:
        "Conformance.run(runtime_a: WasmexSession, runtime_b: #{module}) over #{@admit}, where " <>
          "#{module} is #{description}",
      boundary: @identity,
      forbidden_outcome:
        "the masquerade admitted as a distinct host and a cross-runtime result judged",
      attempt_evidence: "#{@identity_activity} decision observed for the stimulus (any outcome)",
      survival_evidence:
        "#{@identity_activity} outcome=distinct, or #{@judged_activity} observed",
      guard:
        "Conformance executed-engine identity check (AshA2A.RuntimeIdentity.Execution.observe/2 " <>
          "+ disjoint?/2): intersecting engine sets are :sa2a_identical_runtimes",
      failure_class: :identity_failure,
      rfc_sections: ["§126"],
      attempt_predicate: {:observed, @identity_activity},
      outcome_predicate:
        {:any,
         [
           {:observed, @identity_activity, %{"outcome" => "distinct"}},
           {:observed, @judged_activity}
         ]}
    )
  end

  # --- OCEL mappings (§17) -------------------------------------------------------

  @impl true
  def ocel_mappings do
    # The runtime-identity and judged mappings are CHI-ID's own (same event,
    # activity and source), so a run over both courts records one OCEL event
    # per emission.
    shared =
      Enum.filter(
        ExactIdentity.ocel_mappings(),
        &(&1.event in [
            [:ash_a2a, :sa2a, :conformance, :runtime_identity],
            [:ash_a2a, :sa2a, :conformance, :judged]
          ])
      )

    shared ++
      [
        Mapping.new!(
          event: Conformance.vector_event(),
          activity: @vector_activity,
          source: __MODULE__,
          objects: fn _m, meta ->
            Enum.uniq_by(
              [
                {"runtime", meta[:runtime_a], "runtime_a"},
                {"runtime", meta[:runtime_b], "runtime_b"},
                {"sa2a_fixture", meta[:vector], "fixture"},
                {"wasm_artifact", meta[:wasm_digest], "artifact"}
              ],
              fn {type, id, _} -> {type, id} end
            )
          end,
          attributes: fn m, meta ->
            meta
            |> Map.take([
              :vector,
              :computed,
              :admission_a,
              :admission_b,
              :refusal_class_a,
              :refusal_class_b,
              :admission_equal,
              :refusal_equal,
              :input_identity_equal,
              :post_state_equal
            ])
            |> Map.merge(Map.take(m, [:latency_us_a, :latency_us_b]))
          end
        ),
        Mapping.new!(
          event: Conformance.replayed_event(),
          activity: @replayed_activity,
          source: __MODULE__,
          objects: fn _m, meta ->
            [
              {"runtime", meta[:runtime_a], "runtime_a"},
              {"runtime", meta[:runtime_b], "runtime_b"}
            ]
          end,
          attributes: fn _m, meta ->
            Map.take(meta, [:outcome, :divergence_count, :divergences, :code, :result])
          end
        )
      ]
  end

  # --- execution -------------------------------------------------------------------

  @impl true
  def run(%Context{} = ctx) do
    root = Path.join(ctx.evidence_dir, "sa2a-xruntime")
    File.mkdir_p!(root)
    f = Map.new(falsifiers(), &{&1.id, &1})

    [
      guarded(f[fid(1)], fn ->
        run_agreement(ctx, f[fid(1)], root, WasmexSession, RuntimeB, :all)
      end),
      guarded(f[fid(2)], fn ->
        run_agreement(ctx, f[fid(2)], root, RuntimeB, WasmtimeRuntime, @native_subset)
      end),
      guarded(f[fid(3)], fn -> run_negative_fixture(ctx, f[fid(3)], root) end),
      guarded(f[fid(4)], fn -> run_degenerate_artifact(ctx, f[fid(4)], root) end),
      guarded(f[fid(5)], fn -> run_masquerade(ctx, f[fid(5)], root, Fx.DecoyResourceRuntime) end),
      guarded(f[fid(6)], fn -> run_masquerade(ctx, f[fid(6)], root, Fx.HiddenEngineRuntime) end),
      guarded(f[fid(7)], fn -> run_determinism(ctx, f[fid(7)], root) end),
      guarded(f[fid(8)], fn -> run_unstable_identity(ctx, f[fid(8)], root) end),
      guarded(f[fid(9)], fn -> run_replay_discrimination(ctx, f[fid(9)], root) end),
      guarded(f[fid(10)], fn -> run_benchmark(ctx, f[fid(10)], root) end)
    ]
  end

  # One broken edge must not take the other falsifiers with it (§129-§130).
  defp guarded(%Falsifier{} = f, fun) do
    fun.()
  rescue
    exception ->
      Result.unknown(f, "raised: " <> Exception.format(:error, exception, __STACKTRACE__))
  end

  @doc """
  `:ok` when every runtime is available on this machine, else
  `{:blocked, detail}` naming the absent precondition. A host that cannot run
  makes its falsifiers BLOCKED -- never killed, never passed.
  """
  @spec availability([module()], keyword()) :: :ok | {:blocked, String.t()}
  def availability(runtimes, opts \\ []) do
    Enum.find_value(runtimes, :ok, fn runtime ->
      case runtime.available?(opts) do
        :ok ->
          nil

        {:error, reason} ->
          {:blocked, "#{inspect(runtime)} is unavailable on this machine: #{inspect(reason)}"}
      end
    end)
  end

  # SA2A-XRUNTIME-001, 002
  defp run_agreement(ctx, f, root, runtime_a, runtime_b, vector_ids) do
    with :ok <- availability([runtime_a, runtime_b]) do
      corpus = Fx.corpus!(Path.join([root, f.id, "corpus"]), vector_ids, [:malformed_turtle])

      {result, receipt} =
        judged_run(ctx, f, root, runtime_a: runtime_a, runtime_b: runtime_b, corpus_dir: corpus)

      events = observed(ctx, f, @vector_activity)
      decisions = observed(ctx, f, @identity_activity)
      pairs = receipt && vector_pairs(receipt)

      expected =
        case receipt do
          nil ->
            false

          receipt ->
            Enum.any?(decisions, &(&1["outcome"] == "distinct")) and
              receipt["runtime_a"]["wasm_digest"] == receipt["runtime_b"]["wasm_digest"] and
              is_binary(receipt["wasm_digest"]) and pairs != [] and
              Enum.all?(pairs, &agrees?/1) and
              length(events) == length(pairs) and
              Enum.all?(events, &all_equal?/1) and
              admitted_by_both?(pairs, @admit) and
              refused_by_both?(pairs, Fx.negative_id(:malformed_turtle))
        end

      Result.positive(f,
        attempt_observed?: events != [],
        expected_outcome_observed?: expected,
        evidence: %{
          "result" => summarize(result),
          "decisions" => decisions,
          "artifact_digest" => receipt && receipt["wasm_digest"],
          "fixtures" => pairs && Enum.map(pairs, &pair_summary/1)
        }
      )
    else
      {:blocked, detail} -> Result.blocked(f, detail)
    end
  end

  # SA2A-XRUNTIME-003
  defp run_negative_fixture(ctx, f, root) do
    with :ok <- availability([WasmexSession, RuntimeB]) do
      malformed = Fx.negative_id(:malformed_turtle)
      corpus = Fx.corpus!(Path.join([root, f.id, "corpus"]), [@admit], [:malformed_turtle])

      {result, receipt} =
        judged_run(ctx, f, root,
          runtime_a: WasmexSession,
          runtime_b: RuntimeB,
          corpus_dir: corpus
        )

      events = Enum.filter(observed(ctx, f, @vector_activity), &(&1["vector"] == malformed))

      forbidden =
        case receipt && Enum.find(vector_pairs(receipt), &(elem(&1, 0)["vector"] == malformed)) do
          nil ->
            :unknown

          {va, vb} = pair ->
            va["admission"] == "ADMITTED" or vb["admission"] == "ADMITTED" or
              not (agrees?(pair) and refusal_class(va) == refusal_class(vb)) or
              Enum.any?(events, fn e ->
                truthy?(e["refusal_equal"]) == false or e["admission_a"] == "ADMITTED" or
                  e["admission_b"] == "ADMITTED"
              end)
        end

      Result.negative(f,
        attempt_observed?: events != [],
        forbidden_outcome_observed?: forbidden,
        evidence: %{
          "result" => summarize(result),
          "fixture" =>
            receipt &&
              receipt
              |> vector_pairs()
              |> Enum.filter(&(elem(&1, 0)["vector"] == malformed))
              |> Enum.map(&pair_summary/1),
          "events" => events
        }
      )
    else
      {:blocked, detail} -> Result.blocked(f, detail)
    end
  end

  # SA2A-XRUNTIME-004
  defp run_degenerate_artifact(ctx, f, root) do
    with :ok <- availability([WasmexSession, RuntimeB]) do
      dir = Path.join(root, f.id)
      wasm = Fx.degenerate_wasm!(dir)
      corpus = Fx.corpus!(Path.join(dir, "corpus"), [@admit, @shacl_refusal])

      {result, receipt} =
        judged_run(ctx, f, root,
          runtime_a: WasmexSession,
          runtime_b: RuntimeB,
          corpus_dir: corpus,
          wasm_path: wasm
        )

      events = observed(ctx, f, @vector_activity)

      artifact =
        wasm |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

      forbidden =
        case receipt do
          nil ->
            :unknown

          receipt ->
            receipt["result"] == "PASS" or
              Enum.any?(vector_pairs(receipt), fn {va, vb} -> va["computed"] or vb["computed"] end) or
              Enum.any?(events, &truthy?(&1["computed"]))
        end

      Result.negative(f,
        attempt_observed?: events != [] and receipt != nil and receipt["wasm_digest"] == artifact,
        forbidden_outcome_observed?: forbidden,
        evidence: %{
          "degenerate_artifact_sha256" => artifact,
          "receipt_wasm_digest" => receipt && receipt["wasm_digest"],
          "result" => summarize(result),
          "fixtures" => receipt && Enum.map(vector_pairs(receipt), &pair_summary/1)
        }
      )
    else
      {:blocked, detail} -> Result.blocked(f, detail)
    end
  end

  # SA2A-XRUNTIME-005, 006
  defp run_masquerade(ctx, f, root, runtime) do
    with :ok <- availability([WasmexSession, runtime]) do
      corpus = Fx.corpus!(Path.join([root, f.id, "corpus"]), [@admit])

      result =
        Context.stimulus(ctx, f, fn ->
          Conformance.run(runtime_a: WasmexSession, runtime_b: runtime, corpus_dir: corpus)
        end)

      decisions = observed(ctx, f, @identity_activity)

      Result.negative(f,
        attempt_observed?: decisions != [],
        forbidden_outcome_observed?:
          judged?(result) or Enum.any?(decisions, &(&1["outcome"] == "distinct")),
        evidence: %{
          "runtime_b" => inspect(runtime),
          "labels" => [
            inspect(AshA2A.GraphLaw.Runtime.identity(WasmexSession)),
            inspect(AshA2A.GraphLaw.Runtime.identity(runtime))
          ],
          "decisions" => decisions,
          "result" => summarize(result)
        }
      )
    else
      {:blocked, detail} -> Result.blocked(f, detail)
    end
  end

  # SA2A-XRUNTIME-007
  defp run_determinism(ctx, f, root) do
    with :ok <- availability([WasmexSession, RuntimeB]) do
      dir = Path.join(root, f.id)

      corpus =
        Fx.corpus!(
          Path.join(dir, "corpus"),
          [@admit, @shacl_refusal, @unstable, "v008_hook_event_delta"],
          [:malformed_turtle]
        )

      opts = [runtime_a: WasmexSession, runtime_b: RuntimeB, corpus_dir: corpus]
      prior = prior_receipt!(dir, opts)

      replay = Context.stimulus(ctx, f, fn -> Conformance.replay(prior, opts) end)
      replayed = persist_replay(dir, replay)
      independent = replayed && semantic_divergences(prior, replayed)

      forbidden =
        case replay do
          {:ok, %{outcome: :agreed}} -> independent != []
          {:error, %{outcome: :diverged}} -> true
          _ -> :unknown
        end

      Result.negative(f,
        attempt_observed?: observed(ctx, f, @replayed_activity) != [],
        forbidden_outcome_observed?: forbidden,
        evidence: %{
          "replay" => replay_summary(replay),
          "independent_divergences" => independent,
          "prior_result" => prior["result"]
        }
      )
    else
      {:blocked, detail} -> Result.blocked(f, detail)
    end
  end

  # SA2A-XRUNTIME-008
  defp run_unstable_identity(ctx, f, root) do
    with :ok <- availability([WasmexSession, RuntimeB]) do
      corpus = Fx.corpus!(Path.join([root, f.id, "corpus"]), [@unstable])

      {result, receipt} =
        judged_run(ctx, f, root,
          runtime_a: WasmexSession,
          runtime_b: RuntimeB,
          corpus_dir: corpus
        )

      events = Enum.filter(observed(ctx, f, @vector_activity), &(&1["vector"] == @unstable))

      unstable_measured? =
        receipt != nil and
          Enum.any?(vector_pairs(receipt), fn {va, _} ->
            va["input_graph_hash"] != va["input_graph_hash_repeat"]
          end)

      forbidden =
        case receipt do
          nil ->
            :unknown

          receipt ->
            identity = receipt["assertions"]["same_input_identity"]

            (identity["computed"] == true and identity["value"] == true) or
              Enum.any?(events, &truthy?(&1["input_identity_equal"]))
        end

      Result.negative(f,
        attempt_observed?: events != [] and unstable_measured?,
        forbidden_outcome_observed?: forbidden,
        evidence: %{
          "result" => summarize(result),
          "same_input_identity" => receipt && receipt["assertions"]["same_input_identity"],
          "instability_measured" => unstable_measured?
        }
      )
    else
      {:blocked, detail} -> Result.blocked(f, detail)
    end
  end

  # SA2A-XRUNTIME-009
  defp run_replay_discrimination(ctx, f, root) do
    with :ok <- availability([WasmexSession, RuntimeB]) do
      dir = Path.join(root, f.id)
      corpus = Fx.corpus!(Path.join(dir, "corpus"), [@admit, @shacl_refusal])
      opts = [runtime_a: WasmexSession, runtime_b: RuntimeB, corpus_dir: corpus]
      prior = prior_receipt!(dir, opts)

      # Environment change: one admitted input gains one real triple on disk.
      File.write!(
        Path.join([corpus, @admit, "base.ttl"]),
        "\n<http://example.org/chicago> <http://example.org/replayed> \"changed\" .\n",
        [:append]
      )

      replay = Context.stimulus(ctx, f, fn -> Conformance.replay(prior, opts) end)
      replayed = persist_replay(dir, replay)
      independent = replayed && semantic_divergences(prior, replayed)

      expected =
        case replay do
          {:error, %{outcome: :diverged, divergences: divergences}} ->
            Enum.any?(divergences, &String.contains?(&1, @admit)) and
              Enum.any?(independent || [], &String.contains?(&1, @admit))

          {:ok, %{outcome: :agreed}} ->
            false

          _ ->
            :unknown
        end

      Result.positive(f,
        attempt_observed?: observed(ctx, f, @replayed_activity) != [],
        expected_outcome_observed?: expected,
        evidence: %{"replay" => replay_summary(replay), "independent_divergences" => independent}
      )
    else
      {:blocked, detail} -> Result.blocked(f, detail)
    end
  end

  # SA2A-XRUNTIME-010 (Benchmark SA2A-B7)
  defp run_benchmark(ctx, f, root) do
    with :ok <- availability([WasmexSession, RuntimeB]) do
      dir = Path.join(root, f.id)

      native =
        case availability([WasmtimeRuntime]) do
          :ok -> [{RuntimeB, WasmtimeRuntime, @native_subset}]
          {:blocked, detail} -> [{:blocked, detail}]
        end

      pairs =
        for {pair, index} <- Enum.with_index([{WasmexSession, RuntimeB, :all} | native]) do
          case pair do
            {:blocked, detail} ->
              %{"blocked" => detail}

            {runtime_a, runtime_b, vector_ids} ->
              corpus =
                Fx.corpus!(Path.join([dir, "corpus-#{index}"]), vector_ids, [:malformed_turtle])

              {result, meter} =
                Context.stimulus(ctx, f, fn ->
                  Execution.meter(fn ->
                    Conformance.run(
                      runtime_a: runtime_a,
                      runtime_b: runtime_b,
                      corpus_dir: corpus
                    )
                  end)
                end)

              receipt = persist_receipt(Path.join(dir, "receipt-#{index}.json"), result)
              measure_pair(receipt, meter, result)
          end
        end

      measured = Enum.filter(pairs, &Map.has_key?(&1, "fixture_count"))

      Result.measured(f,
        attempt_observed?: measured != [] and observed(ctx, f, @judged_activity) != [],
        measurements: %{
          "benchmark" => "SA2A-B7",
          "artifact_digest" => measured |> Enum.map(& &1["artifact_digest"]) |> Enum.uniq(),
          "pairs" => pairs
        },
        evidence: %{"pairs" => length(pairs), "measured_pairs" => length(measured)}
      )
    else
      {:blocked, detail} -> Result.blocked(f, detail)
    end
  end

  defp measure_pair(nil, meter, result),
    do: %{"not_judged" => summarize(result), "meter" => meter}

  defp measure_pair(receipt, meter, _result) do
    pairs = vector_pairs(receipt)

    %{
      "artifact_digest" => receipt["wasm_digest"],
      "result" => receipt["result"],
      "hosts" => Enum.map(["runtime_a", "runtime_b"], &host_measurement(receipt[&1], meter)),
      "fixture_count" => length(pairs),
      "admission_equivalence_count" => Enum.count(pairs, &agrees?/1),
      "refusal_equivalence_count" =>
        Enum.count(pairs, fn {va, vb} = pair ->
          va["admission"] == "REFUSED" and vb["admission"] == "REFUSED" and computed?(pair) and
            refusal_class(va) == refusal_class(vb)
        end),
      "refused_fixture_count" =>
        Enum.count(pairs, fn {va, vb} ->
          va["admission"] == "REFUSED" or vb["admission"] == "REFUSED"
        end),
      "post_state_equivalence_count" => Enum.count(pairs, &post_state_equal?/1),
      "input_identity_equivalence_count" =>
        Enum.count(pairs, fn {va, vb} = pair ->
          computed?(pair) and va["input_graph_hash"] == vb["input_graph_hash"] and
            va["input_graph_hash"] == va["input_graph_hash_repeat"] and
            vb["input_graph_hash"] == vb["input_graph_hash_repeat"]
        end),
      "disagreements" =>
        pairs
        |> Enum.reject(&(agrees?(&1) and post_state_equal?(&1)))
        |> Enum.map(&elem(&1, 0)["vector"]),
      "wall_us" => meter["wall_us"]
    }
  end

  defp host_measurement(section, meter) do
    executed = section["executed_identity"] || []
    os_shas = for %{"kind" => "os_process", "executable_sha256" => sha} <- executed, do: sha
    modules = for %{"kind" => "beam_process", "engine_module" => m} <- executed, do: m

    latencies =
      Enum.map(section["vectors"] || [], & &1["latency_us"]) |> Enum.filter(&is_integer/1)

    %{
      "host" => section["host"],
      "engine" => section["engine"],
      "runtime_module" => section["runtime_module"],
      "executed_identity" => executed,
      "executed_identity_digest" => executed != [] && AshA2A.RuntimeIdentity.digest(executed),
      "latency_us" => section["observe_us"],
      "vector_latency_us" => %{
        "min" => Enum.min(latencies, fn -> nil end),
        "max" => Enum.max(latencies, fn -> nil end),
        "sum" => Enum.sum(latencies)
      },
      "memory" => %{
        "engine_reported" => section["engine_memory"],
        "os_processes" =>
          Enum.filter(meter["os_processes"] || [], &(&1["executable_sha256"] in os_shas)),
        "beam_engines" =>
          Enum.filter(meter["beam_engines"] || [], &(&1["engine_module"] in modules))
      }
    }
  end

  # --- evidence helpers --------------------------------------------------------------

  # Runs the real court as the stimulus and reads its receipt back from disk:
  # the court never trusts the in-memory return value for its verdict.
  defp judged_run(ctx, f, root, opts) do
    result = Context.stimulus(ctx, f, fn -> Conformance.run(opts) end)
    receipt = persist_receipt(Path.join([root, f.id, "receipt.json"]), result)
    {result, receipt}
  end

  defp persist_receipt(path, {_tag, %{"profile" => _} = receipt}) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, JSON.encode!(receipt))
    path |> File.read!() |> JSON.decode!()
  end

  defp persist_receipt(_path, _not_judged), do: nil

  defp prior_receipt!(dir, opts) do
    persist_receipt(Path.join(dir, "prior_receipt.json"), Conformance.run(opts)) ||
      raise "the prior Conformance run was not judged; there is no receipt to replay"
  end

  defp persist_replay(dir, {:ok, %{receipt: receipt}}),
    do: persist_receipt(Path.join(dir, "replay_receipt.json"), {:ok, receipt})

  defp persist_replay(dir, {:error, %{receipt: receipt}}),
    do: persist_receipt(Path.join(dir, "replay_receipt.json"), {:error, receipt})

  defp persist_replay(_dir, _other), do: nil

  # The court's own comparison of two durable receipts, independent of
  # Conformance.replay/2's: per-vector admission, typed refusal, S41 trace and
  # every semantic digest.
  defp semantic_divergences(prior, replayed) do
    fields =
      ~w(computed admission refusal_reason state_trace input_graph_hash input_graph_hash_repeat
         validation_digest output_graph_hash post_state_identity evidence_hash)

    for side <- ["runtime_a", "runtime_b"],
        {old, index} <- Enum.with_index(prior[side]["vectors"] || []),
        new = Enum.at(replayed[side]["vectors"] || [], index),
        field <- fields,
        is_nil(new) or old[field] != new[field] or old["vector"] != new["vector"] do
      "#{side}.#{old["vector"]}.#{field}"
    end
    |> Enum.uniq()
  end

  defp vector_pairs(receipt),
    do: Enum.zip(receipt["runtime_a"]["vectors"] || [], receipt["runtime_b"]["vectors"] || [])

  defp computed?({va, vb}), do: va["computed"] == true and vb["computed"] == true

  defp agrees?({va, vb} = pair) do
    computed?(pair) and va["vector"] == vb["vector"] and va["admission"] == vb["admission"] and
      va["refusal_reason"] == vb["refusal_reason"] and va["state_trace"] == vb["state_trace"]
  end

  defp post_state_equal?({va, vb} = pair) do
    computed?(pair) and is_binary(va["output_graph_hash"]) and
      va["output_graph_hash"] == vb["output_graph_hash"] and
      va["post_state_identity"] == vb["post_state_identity"]
  end

  defp admitted_by_both?(pairs, id),
    do:
      Enum.any?(pairs, fn {va, vb} ->
        va["vector"] == id and va["admission"] == "ADMITTED" and vb["admission"] == "ADMITTED"
      end)

  defp refused_by_both?(pairs, id),
    do:
      Enum.any?(pairs, fn {va, vb} = pair ->
        va["vector"] == id and va["admission"] == "REFUSED" and vb["admission"] == "REFUSED" and
          agrees?(pair)
      end)

  defp all_equal?(event) do
    Enum.all?(
      ["computed", "admission_equal", "refusal_equal", "post_state_equal"],
      &truthy?(event[&1])
    )
  end

  defp refusal_class(%{"admission" => "ADMITTED"}), do: "NONE"

  defp refusal_class(%{"refusal_reason" => reason}) when is_binary(reason),
    do: reason |> String.split(":", parts: 2) |> hd()

  defp refusal_class(_), do: "UNKNOWN"

  defp pair_summary({va, vb}) do
    %{
      "vector" => va["vector"],
      "computed" => [va["computed"], vb["computed"]],
      "admission" => [va["admission"], vb["admission"]],
      "refusal_reason" => [va["refusal_reason"], vb["refusal_reason"]],
      "post_state" => [va["output_graph_hash"], vb["output_graph_hash"]],
      "post_state_identity" => [va["post_state_identity"], vb["post_state_identity"]]
    }
  end

  defp truthy?(value), do: to_string(value) == "true"

  defp observed(ctx, f, activity) do
    ctx
    |> Context.observed(f)
    |> Enum.filter(&(&1.activity == activity))
    |> Enum.map(& &1.attributes)
  end

  defp judged?({_, %{"result" => _}}), do: true
  defp judged?(_), do: false

  defp summarize({tag, %{"result" => result}}), do: %{"tag" => inspect(tag), "result" => result}

  defp summarize({tag, %{code: code} = reason}),
    do: %{"tag" => inspect(tag), "code" => inspect(code), "basis" => inspect(reason[:basis])}

  defp summarize(other), do: %{"raw" => inspect(other, limit: 10)}

  defp replay_summary({tag, %{outcome: outcome} = replay}),
    do: %{
      "tag" => inspect(tag),
      "outcome" => Atom.to_string(outcome),
      "divergences" => Map.get(replay, :divergences, [])
    }

  defp replay_summary(other), do: summarize(other)
end
