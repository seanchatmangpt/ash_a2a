defmodule AshA2A.SA2A.Conformance do
  @moduledoc """
  The SA2A conformance court: runs one identical GraphLaw call sequence in two
  genuinely different WebAssembly runtimes over one identical WASM module and
  one identical corpus, and emits a machine-readable receipt saying whether
  the two agreed.

  ## The exact claim this court can earn

      Runtime_A != Runtime_B,  WASM_A = WASM_B,  O*_input,A = O*_input,B
        => Admission_A = Admission_B, O*_output,A = O*_output,B, Refusal_A = Refusal_B

  ...for the finite corpus in `priv/sa2a_conformance/`, and for nothing else.
  A passing run does **not** establish universal semantic equivalence,
  production readiness, security completeness, or equivalence between two
  different *implementations* of GraphLaw. The module is byte-identical in
  both runtimes by construction; what is under test is portable execution of
  it, which is a real property and a narrow one.

  ## What is measured, and what is deliberately not

  The court evaluates the RFC S41 state-machine prefix
  `RECEIVED -> ... -> ADMITTED` (see `AshA2A.SA2A.StateMachine`) and stops
  there. It dispatches no command, consults no authority, claims no
  `AshA2A.Receipt`, and never calls `AshA2A.CommandBus`. Admission is not
  actuation. Putting a network or database adapter inside this measurement
  would contaminate evidence about GraphLaw portability with evidence about
  an HTTP client.

  ## Call sequence, per vector, per runtime

      graphlaw_version()
      validate_all(base, profile, shacl, shex, shape_map)
      graph_hash(base)
      run_hooks(base, event)
      graph_hash(<canonical projection of the run_hooks result>)
      blake3_hex(<canonical evidence package>)
      graph_hash(base)        # repeated, see "Stability" below

  The fifth call hashes the *result* of the fourth, not its printed form:
  `AshA2A.SA2A.ResultProjection.hook_result_turtle/2` projects the parsed
  result into RDF, and GraphLaw's own `graph_hash` does the rest. That is the
  engine's prefix- and triple-order-invariant BLAKE3 digest, not RDFC-1.0 (it
  is not blank-node-relabel invariant; RFC S12 identity is
  `AshA2A.Semantic.CanonicalGraph`) -- the court compares runtimes on the same
  engine digest, not on RDF isomorphism.
  The sixth is computed inside each runtime over that runtime's own
  observations, so evidence identity is a real agreement rather than a
  restatement of one runtime's view.

  ## An engine error is never projected into a comparable value

  This is the court's load-bearing rule and it is enforced structurally, not
  by convention. If any call in a vector's sequence fails -- a transport
  error, or the `{"error": ...}` JSON GraphLaw returns instead of raising --
  that vector's observation is marked `computed: false` in both runtimes'
  receipt sections, every downstream call is **skipped rather than issued
  over a substitute input**, and every per-vector assertion reports
  `computed: false, value: nil`.

  The alternative was measured and is the reason the rule is structural. An
  earlier revision of this module projected a failed `run_hooks/2` into a
  well-formed `%{"status" => "ABSENT"}` graph and hashed *that*. Two hosts
  whose hook path was broken then produced the identical ABSENT digest
  `d8d7d578..`, `same_admission`, `same_output_semantics` and
  `same_evidence_identity` all reported `computed: true, value: true`, and
  `run/1` returned `{:ok, receipt}` with `"result" => "PASS"` for a run in
  which `run_hooks/2` -- the call that decides ADMITTED -- never executed in
  either runtime. Two hosts agreeing that they both failed is not
  conformance. A failure has no canonical form and must not be given one.

  ## Degenerate results are not values either

  A call that *succeeds* can still answer nothing. Measured before this rule:
  one content-addressed wasm artifact whose every GraphLaw export returns the
  string `{}`, executed by the real in-BEAM host and the real V8 host, ran to
  `{:ok, receipt}` with `"result" => "PASS"` -- both hosts agreed on `{}` for
  every digest, every validation and every hook result. So every answer is
  admitted by shape before it is comparable: digest calls (`graph_hash`,
  `blake3_hex`, rollups, root manifest) must answer a 64-hex digest,
  `validate_all/5` a `graph_hash` digest and a non-empty dialect list,
  `run_hooks/2` a status and a verdict list. Anything else is recorded as
  `:sa2a_degenerate_result` and the observation is not computed.

  Engine-level degeneracy is fenced at the S41 PARSED hop: GraphLaw hashes
  bytes that are not Turtle and then admits them, identically in every host,
  so PARSED also requires the S12 primitive to parse the input
  (`AshA2A.SA2A.StateMachine.evaluate/4`).

  ## Stability: why `graph_hash(base)` is called twice

  The conformance claim's premise is `O*_input,A = O*_input,B` -- an equality
  between two runtimes' input identities. That equality is only meaningful if
  input identity is a *function of the graph*. If `graph_hash/1` returns a
  different digest each time it is handed the same graph, two runtimes
  walking the same call sequence will still agree, and
  `same_input_identity` would report `true` about a quantity that means
  nothing.

  That is not hypothetical. Measured against `praxis-graphlaw v26.7.5`, four
  consecutive `graph_hash/1` calls on the identical blank-node graph of
  vector `v006_blank_nodes` in one session returned four different digests
  (`dac3b497..`, `725c2598..`, `bb3ebb85..`, `47bc5f5f..`), while ground
  graphs were perfectly stable across the same calls. Both runtimes
  reproduced the identical unstable sequence, so this is a deterministic
  engine property, not a portability defect -- and exactly the vacuity the
  premise has to exclude.

  So the sequence repeats `graph_hash(base)` at the end, and
  `same_input_identity` requires cross-runtime equality **and** within-runtime
  stability. A runtime that disagrees with itself fails the assertion.

  ## The five falsifiers

    * `same_wasm` -- both hosts loaded the identical module digest.
    * `same_input_identity` -- `graph_hash(base)` agreed across runtimes on
      every vector, and each runtime agreed with itself on repetition.
    * `same_admission` -- identical admission, identical typed refusal
      reason, and identical S41 state trace on every vector.
    * `same_output_semantics` -- identical engine hash of the projected hook
      result on every vector, and identical canonical post-state identity
      (`post_state_identity`: RFC S12 RDFC-1.0 digest of each host's own
      projected result, computed by `AshA2A.Semantic.CanonicalGraph`, not by
      the host under test).
    * `same_evidence_identity` -- identical per-vector evidence digest, and
      identical corpus `root_manifest_digest`.

  An assertion that could not be computed is a **failure**, never a skip:
  `run/1` returns `{:error, receipt}` when any of the five is absent or
  false, and `mix ash_a2a.sa2a_conformance` exits non-zero on it.

  `computed` and `value` are genuinely distinct in the receipt and are not
  two spellings of the same bit. An assertion the court could not compute
  carries `"computed" => false, "value" => null`; one it computed and
  falsified carries `"computed" => true, "value" => false`; only
  `"computed" => true, "value" => true` counts toward a pass, for all five.
  There is no third state in which absence satisfies the pass condition.

  ## Refusing a degenerate run

  Two runtimes that are the same module, or that share a
  `{host_id, engine_id}` pair, are refused with `:sa2a_identical_runtimes`
  before any vector executes. A court that silently ran one runtime twice
  would report five green assertions and mean nothing at all. The module
  check runs first, so a module that cannot report its own identity still
  cannot be run against itself.

  The pair is compared after `AshA2A.RuntimeIdentity.label_key/1`
  normalization (Unicode NFKC, whitespace / separator / format characters
  removed, case folded): changing only a whitespace-normalized host label is
  not evidence of heterogeneity (RFC-SA2A-002 §126). Measured before this
  rule, a runtime reporting `"BEAM/Wasmex "` -- one trailing space -- over
  the very same Wasmtime instance ran to `{:ok, receipt}` with
  `"result" => "PASS"`.

  Labels are caller-controlled, so they are necessary but not sufficient.
  Once both sessions are open, and still before any vector executes, the
  court observes each session's real executing resources
  (`AshA2A.RuntimeIdentity.observe_session/1`: the emulator + engine
  module/NIF digests of an in-BEAM process, the executable digest of an OS
  process) and refuses with `:sa2a_identical_runtimes` when both observed
  identities are equal, or with `:sa2a_runtime_identity_unobservable` when
  either cannot be observed. A module relabelled `"WASI/StandaloneHost"` /
  `"wasm3"` that executes in the same in-BEAM Wasmtime engine is refused on
  what it executes, not on what it says.

  Session terms are authored by the runtime module under test, so distinct
  session identities are still not sufficient. Measured before the next
  check: a `WasmexSession` wrapper whose session also named an idle decoy
  process, and one running every call inside an `Agent` (a session naming no
  engine at all), were each judged "PASS" against `WasmexSession`. The court
  therefore issues one real `graphlaw_version` call per session under
  execution tracing (`AshA2A.RuntimeIdentity.Execution.observe/2`) and
  refuses with `:sa2a_identical_runtimes` (`basis: :executed_engine`) when the
  engines those calls executed on intersect, or with
  `:sa2a_runtime_identity_unobservable` when a call reached no observable
  engine.

  Each decision emits `[:ash_a2a, :sa2a, :conformance, :runtime_identity]`
  (`outcome: :identical | :distinct | :unobservable`, `basis: :module |
  :label | :observed_executable | :executed_engine`), every judged run emits
  `[:ash_a2a, :sa2a, :conformance, :judged]` and one
  `[:ash_a2a, :sa2a, :conformance, :vector_judged]` per vector (admission,
  refusal class and post-state equivalence, derived from the judged
  assertions), and `replay/2` emits `[:ash_a2a, :sa2a, :conformance,
  :replayed]`, so an independent observer can establish that each decision
  was reached before any verdict.
  """

  @doc false
  def __sa2a_refusal_codes__,
    do: %{
      sa2a_identical_runtimes: :refused_identity,
      sa2a_runtime_identity_unobservable: :refused_identity,
      sa2a_replay_subject_mismatch: :refused_identity,
      sa2a_replay_prior_malformed: :refused_structure,
      sa2a_degenerate_result: :refused_structure
    }

  alias AshA2A.GraphLaw.Runtime
  alias AshA2A.RuntimeIdentity
  alias AshA2A.RuntimeIdentity.Execution
  alias AshA2A.SA2A.{ResultProjection, StateMachine, Vector}
  alias AshA2A.Semantic.CanonicalGraph

  @profile "SA2A-STRICT-v26.9.16"
  @assertions [
    :same_wasm,
    :same_input_identity,
    :same_admission,
    :same_output_semantics,
    :same_evidence_identity
  ]

  @doc "The conformance profile identifier stamped into every receipt."
  @spec profile() :: String.t()
  def profile, do: @profile

  @doc "The five assertion names, in receipt order."
  @spec assertion_names() :: [atom()]
  def assertion_names, do: @assertions

  @doc """
  Runs the full court.

  Options: `:runtime_a` and `:runtime_b` (modules implementing
  `AshA2A.GraphLaw.Runtime`, defaulting to `AshA2A.GraphLaw.WasmexSession` and
  `AshA2A.GraphLaw.RuntimeB`), plus `:corpus_dir` and `:wasm_path`.

  Returns `{:ok, receipt}` only when all five assertions were computed and
  all five are true; `{:error, receipt}` when any failed; and
  `{:error, reason_map}` when the run could not start at all (identical
  runtimes, an unavailable runtime, a missing or empty corpus).
  """
  @spec run(keyword()) :: {:ok, map()} | {:error, map()}
  def run(opts \\ []) do
    runtime_a = Keyword.get(opts, :runtime_a, AshA2A.GraphLaw.WasmexSession)
    runtime_b = Keyword.get(opts, :runtime_b, AshA2A.GraphLaw.RuntimeB)

    with :ok <- refuse_identical(runtime_a, runtime_b),
         :ok <- check_available(runtime_a, opts),
         :ok <- check_available(runtime_b, opts),
         {:ok, vectors} <- Vector.load_all(opts) do
      # Both sessions are opened before any vector executes, so the observed
      # runtime identities can be compared first (RFC-SA2A-002 §126).
      with_open(runtime_a, opts, fn opened_a ->
        with_open(runtime_b, opts, fn opened_b ->
          with {:ok, identity_a, identity_b} <-
                 refuse_same_executable(runtime_a, opened_a, runtime_b, opened_b),
               {:ok, observed_a} <- observe(runtime_a, opened_a, identity_a, vectors),
               {:ok, observed_b} <- observe(runtime_b, opened_b, identity_b, vectors) do
            judge(observed_a, observed_b, vectors)
          end
        end)
      end)
    end
  end

  @replayed_event [:ash_a2a, :sa2a, :conformance, :replayed]

  @doc "Telemetry event emitted by every `replay/2` decision."
  @spec replayed_event() :: [atom()]
  def replayed_event, do: @replayed_event

  # Semantic identities a replay compares (RFC-SA2A-002 §125). Latency,
  # memory, observed host/executable identities and free-text details are
  # non-semantic metadata: they MAY differ between two runs of identical
  # admitted inputs and are deliberately not compared.
  @semantic_top ~w(profile graphlaw_version wasm_digest wasm_digest_algorithm root_manifest_digest result corpus)
  @semantic_runtime ~w(host engine runtime_module wasm_digest graphlaw_version root_manifest_digest
                       observations_complete input_graph_hash admission admission_digest
                       output_graph_hash evidence_hash)
  @semantic_vector ~w(vector vector_digest computed input_graph_hash input_graph_hash_repeat
                      validation_digest admission refusal_reason state_reached state_trace
                      output_graph_hash post_state_identity evidence_hash)

  @doc """
  Determinism check (RFC-SA2A-002 §125): re-executes the court with `opts`
  against the runtimes a durable `prior` receipt names, and compares the
  semantic identities of the two receipts -- per-vector admission, typed
  refusal, S41 trace, input/output/evidence identities, rollups and assertion
  outcomes -- never raw pretty-printed output or non-semantic metadata.

  `prior` is a receipt as read back from disk (string keys). Returns
  `{:ok, %{outcome: :agreed, receipt: new}}`, `{:error, %{outcome: :diverged,
  divergences: [path], receipt: new}}`, or `{:error, reason}` when the replay
  is not comparable (malformed prior, different runtimes, a run that could
  not start). Every decision emits `replayed_event/0`.
  """
  @spec replay(map(), keyword()) :: {:ok, map()} | {:error, map()}
  def replay(prior, opts \\ []) when is_map(prior) do
    runtime_a = Keyword.get(opts, :runtime_a, AshA2A.GraphLaw.WasmexSession)
    runtime_b = Keyword.get(opts, :runtime_b, AshA2A.GraphLaw.RuntimeB)
    prior = prior |> JSON.encode!() |> JSON.decode!()

    cond do
      not match?(
        %{"runtime_a" => %{"runtime_module" => _}, "runtime_b" => %{"runtime_module" => _}},
        prior
      ) ->
        emit_replay(:not_comparable, runtime_a, runtime_b, %{code: :sa2a_replay_prior_malformed})

        {:error,
         %{
           code: :sa2a_replay_prior_malformed,
           message: "the prior receipt names no runtime modules; there is nothing to replay"
         }}

      prior["runtime_a"]["runtime_module"] != inspect(runtime_a) or
          prior["runtime_b"]["runtime_module"] != inspect(runtime_b) ->
        emit_replay(:not_comparable, runtime_a, runtime_b, %{code: :sa2a_replay_subject_mismatch})

        {:error,
         %{
           code: :sa2a_replay_subject_mismatch,
           prior: [prior["runtime_a"]["runtime_module"], prior["runtime_b"]["runtime_module"]],
           replay: [inspect(runtime_a), inspect(runtime_b)],
           message: "a replay against different runtimes is not a determinism check"
         }}

      true ->
        case run(opts) do
          {_tag, %{"profile" => _} = receipt} ->
            divergences =
              diff(semantic(prior), semantic(receipt |> JSON.encode!() |> JSON.decode!()), [])

            outcome = if divergences == [], do: :agreed, else: :diverged

            emit_replay(outcome, runtime_a, runtime_b, %{
              divergence_count: length(divergences),
              divergences: divergences |> Enum.take(20) |> Enum.join(","),
              prior_result: prior["result"],
              result: receipt["result"]
            })

            if outcome == :agreed,
              do: {:ok, %{outcome: :agreed, receipt: receipt}},
              else: {:error, %{outcome: :diverged, divergences: divergences, receipt: receipt}}

          {:error, reason} ->
            emit_replay(:not_comparable, runtime_a, runtime_b, %{code: reason[:code]})
            {:error, Map.put(reason, :replay, :not_comparable)}
        end
    end
  end

  defp semantic(receipt) do
    receipt
    |> Map.take(@semantic_top)
    |> Map.put(
      "assertions",
      Map.new(receipt["assertions"] || %{}, fn {name, a} ->
        {name, Map.take(a, ["computed", "value"])}
      end)
    )
    |> Map.merge(
      Map.new(["runtime_a", "runtime_b"], fn side ->
        section = receipt[side] || %{}

        {side,
         section
         |> Map.take(@semantic_runtime)
         |> Map.put(
           "vectors",
           Enum.map(section["vectors"] || [], &Map.take(&1, @semantic_vector))
         )}
      end)
    )
  end

  defp diff(same, same, _path), do: []

  defp diff(%{} = a, %{} = b, path) do
    (Map.keys(a) ++ Map.keys(b))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(&diff(Map.get(a, &1), Map.get(b, &1), path ++ [&1]))
  end

  defp diff(a, b, path) when is_list(a) and is_list(b) and length(a) == length(b) do
    a
    |> Enum.zip(b)
    |> Enum.with_index()
    |> Enum.flat_map(fn {{x, y}, i} ->
      label = if is_map(x) and is_binary(x["vector"]), do: x["vector"], else: Integer.to_string(i)
      diff(x, y, path ++ [label])
    end)
  end

  defp diff(_a, _b, path), do: [Enum.join(path, ".")]

  defp emit_replay(outcome, runtime_a, runtime_b, extra) do
    :telemetry.execute(
      @replayed_event,
      %{},
      Map.merge(
        %{outcome: outcome, runtime_a: inspect(runtime_a), runtime_b: inspect(runtime_b)},
        extra
      )
    )
  end

  defp with_open(mod, opts, fun) do
    case mod.open(opts) do
      {:ok, %{session: session} = opened} ->
        try do
          fun.(opened)
        after
          mod.close(session)
        end

      {:error, reason} ->
        {:error, Map.put(reason, :runtime, inspect(mod))}
    end
  end

  # -- refusals -------------------------------------------------------------

  # Two checks, module identity first. A module that cannot report its own
  # {host_id, engine_id} must still not be runnable against itself, so the
  # cheaper and stricter check does not depend on the runtime answering.
  defp refuse_identical(mod, mod) do
    emit_identity(:identical, :module, mod, mod)

    {:error,
     %{
       code: :sa2a_identical_runtimes,
       same_module: true,
       runtime_a: inspect(mod),
       runtime_b: inspect(mod),
       identity: inspect(Runtime.identity(mod)),
       message:
         "runtime_a and runtime_b resolve to the same module (#{inspect(mod)}). Running " <>
           "one runtime twice cannot establish cross-runtime conformance; it would " <>
           "report five trivially-passing assertions about a single host."
     }}
  end

  defp refuse_identical(mod_a, mod_b) do
    identity_a = Runtime.identity(mod_a)
    identity_b = Runtime.identity(mod_b)

    # Caller-controlled strings: compared after whitespace/case/Unicode
    # normalization, so "BEAM/Wasmex " is not a second host (§126).
    if label_keys(identity_a) == label_keys(identity_b) do
      emit_identity(:identical, :label, mod_a, mod_b)

      {:error,
       %{
         code: :sa2a_identical_runtimes,
         same_module: false,
         basis: :label,
         runtime_a: inspect(mod_a),
         runtime_b: inspect(mod_b),
         identity: inspect(identity_a),
         identity_b: inspect(identity_b),
         message:
           "both runtimes report the same {host_id, engine_id} (compared after " <>
             "whitespace/case normalization, RFC-SA2A-002 S126). Running one runtime " <>
             "twice cannot establish cross-runtime conformance."
       }}
    else
      :ok
    end
  end

  defp label_keys({host, engine}),
    do: {RuntimeIdentity.label_key(host), RuntimeIdentity.label_key(engine)}

  # Labels passed; the executing resources decide. Observed from the open
  # sessions, never from what either module reports about itself.
  defp refuse_same_executable(mod_a, %{session: session_a}, mod_b, %{session: session_b}) do
    case {RuntimeIdentity.observe_session(session_a), RuntimeIdentity.observe_session(session_b)} do
      {{:ok, same}, {:ok, same}} ->
        digest = RuntimeIdentity.digest(same)

        emit_identity(:identical, :observed_executable, mod_a, mod_b, %{
          observed_a: digest,
          observed_b: digest
        })

        {:error,
         %{
           code: :sa2a_identical_runtimes,
           same_module: false,
           basis: :observed_executable,
           runtime_a: inspect(mod_a),
           runtime_b: inspect(mod_b),
           identity: inspect(Runtime.identity(mod_a)),
           identity_b: inspect(Runtime.identity(mod_b)),
           observed_identity: same,
           message:
             "the two runtimes report different {host_id, engine_id} labels but execute on " <>
               "the same observed runtime (#{String.slice(digest, 0, 12)}). Running one runtime " <>
               "twice cannot establish cross-runtime conformance (RFC-SA2A-002 S126)."
         }}

      {{:ok, identity_a}, {:ok, identity_b}} ->
        refuse_same_engine(mod_a, session_a, identity_a, mod_b, session_b, identity_b)

      {observed_a, observed_b} ->
        emit_identity(:unobservable, :observed_executable, mod_a, mod_b)

        {:error,
         %{
           code: :sa2a_runtime_identity_unobservable,
           runtime_a: inspect(mod_a),
           runtime_b: inspect(mod_b),
           observed_a: inspect(observed_a),
           observed_b: inspect(observed_b),
           message:
             "a runtime's executing identity could not be observed, so heterogeneity " <>
               "cannot be established (RFC-SA2A-002 S126)."
         }}
    end
  end

  # The session term is authored by the runtime module under test, so distinct
  # session identities are necessary but not sufficient. Measured before this
  # check: a WasmexSession wrapper whose session also named an idle decoy
  # process, and one that ran every call inside an Agent (its session naming
  # no engine at all), were each judged `{:ok, receipt}` "PASS" against
  # WasmexSession itself. The engine each session's real call executed on
  # decides (RFC-SA2A-002 S126): intersecting engine sets are one runtime.
  defp refuse_same_engine(mod_a, session_a, identity_a, mod_b, session_b, identity_b) do
    observed = %{
      observed_a: RuntimeIdentity.digest(identity_a),
      observed_b: RuntimeIdentity.digest(identity_b)
    }

    executed_a = Execution.observe(fn -> mod_a.call(session_a, :graphlaw_version, []) end)
    executed_b = Execution.observe(fn -> mod_b.call(session_b, :graphlaw_version, []) end)

    case {executed_a, executed_b} do
      {{:ok, a}, {:ok, b}} ->
        extra = Map.merge(observed, %{executed_a: a.digest, executed_b: b.digest})

        if Execution.disjoint?(a.engines, b.engines) do
          emit_identity(:distinct, :observed_executable, mod_a, mod_b, extra)

          {:ok, %{session: identity_a, executed: a.engines},
           %{session: identity_b, executed: b.engines}}
        else
          emit_identity(:identical, :executed_engine, mod_a, mod_b, extra)
          shared = Enum.filter(a.engines, &(&1 in b.engines))

          {:error,
           %{
             code: :sa2a_identical_runtimes,
             same_module: false,
             basis: :executed_engine,
             runtime_a: inspect(mod_a),
             runtime_b: inspect(mod_b),
             identity: inspect(Runtime.identity(mod_a)),
             identity_b: inspect(Runtime.identity(mod_b)),
             observed_identity: identity_b,
             executed_identity: shared,
             message:
               "the two runtimes present different labels and session resources but their " <>
                 "calls execute on the same engine (#{String.slice(a.digest, 0, 12)}). Running " <>
                 "one runtime twice cannot establish cross-runtime conformance (RFC-SA2A-002 S126)."
           }}
        end

      _ ->
        emit_identity(:unobservable, :executed_engine, mod_a, mod_b, observed)

        {:error,
         %{
           code: :sa2a_runtime_identity_unobservable,
           basis: :executed_engine,
           runtime_a: inspect(mod_a),
           runtime_b: inspect(mod_b),
           executed_a: inspect(executed_a),
           executed_b: inspect(executed_b),
           message:
             "the engine a runtime's call executed on could not be observed, so heterogeneity " <>
               "cannot be established (RFC-SA2A-002 S126)."
         }}
    end
  end

  @identity_event [:ash_a2a, :sa2a, :conformance, :runtime_identity]
  @judged_event [:ash_a2a, :sa2a, :conformance, :judged]

  # Boundary telemetry (RFC-SA2A-002 §12): the decision this court makes about
  # whether two runtimes are heterogeneous, observable by an independent
  # process observer. Behaviour-preserving; it records, it decides nothing.
  defp emit_identity(outcome, basis, mod_a, mod_b, extra \\ %{}) do
    :telemetry.execute(
      @identity_event,
      %{},
      Map.merge(
        %{outcome: outcome, basis: basis, runtime_a: inspect(mod_a), runtime_b: inspect(mod_b)},
        extra
      )
    )
  end

  defp check_available(mod, opts) do
    case mod.available?(opts) do
      :ok -> :ok
      {:error, reason} -> {:error, Map.put(reason, :runtime, inspect(mod))}
    end
  end

  # -- observation ----------------------------------------------------------

  defp observe(mod, %{session: session, wasm_digest: wasm_digest}, identity, vectors) do
    root_manifest = Vector.root_manifest(vectors)

    started = System.monotonic_time(:microsecond)

    with {:ok, version} <- mod.call(session, :graphlaw_version, []),
         {:ok, root_raw} <- mod.call(session, :blake3_hex, [root_manifest]) do
      # A root digest that is not a digest is not computed (nil), never a
      # value two degenerate hosts could agree on.
      root_digest = value(admit_digest({:ok, root_raw}, :root_manifest))

      vector_results =
        Enum.map(vectors, fn vector ->
          vector_started = System.monotonic_time(:microsecond)
          observation = observe_vector(mod, session, vector, version)
          Map.put(observation, :latency_us, System.monotonic_time(:microsecond) - vector_started)
        end)

      {:ok,
       %{
         runtime: mod,
         host: mod.host_id(),
         engine: engine_of(mod, session),
         observed_identity: identity.session,
         executed_identity: identity.executed,
         wasm_digest: wasm_digest,
         digest_algorithm: Runtime.digest_algorithm(),
         graphlaw_version: version,
         root_manifest_digest: root_digest,
         vectors: vector_results,
         observe_us: System.monotonic_time(:microsecond) - started,
         engine_memory: engine_memory(mod, session)
       }
       |> with_rollups(mod, session)}
    else
      {:error, reason} ->
        {:error, Map.put(reason, :runtime, inspect(mod))}
    end
  end

  defp observe_vector(mod, session, %Vector{} = vector, version) do
    validation_raw =
      call(mod, session, :validate_all, [
        vector.base,
        vector.profile,
        vector.shacl,
        vector.shex,
        vector.shape_map
      ])

    input_graph_hash = digest_call(mod, session, :graph_hash, [vector.base], :graph_hash_input)
    hooks_raw = call(mod, session, :run_hooks, [vector.base, vector.event])

    # Decoded, not raw: GraphLaw answers `{"error": ...}` JSON instead of
    # raising, so a transport-level `{:ok, body}` can still carry an engine
    # failure. Both count as failures here. A payload that decodes but lacks
    # the shape every real GraphLaw answer has is a degenerate result, and is
    # not computed either (see "Degenerate results" in the module doc).
    validation = validation_raw |> decode() |> admit_validation()
    hooks = hooks_raw |> decode() |> admit_hooks()

    state = StateMachine.evaluate(value(input_graph_hash), validation, hooks, base: vector.base)

    # A failed `run_hooks/2` has no canonical form. The projection call is
    # SKIPPED rather than issued over a substitute graph -- projecting the
    # failure into `%{"status" => "ABSENT"}` and hashing it is what let two
    # broken hosts agree digit-for-digit on a digest neither had earned.
    output_graph_hash =
      case hooks do
        {:ok, decoded} ->
          digest_call(
            mod,
            session,
            :graph_hash,
            [ResultProjection.hook_result_turtle(vector.id, decoded)],
            :graph_hash_output
          )

        {:error, reason} ->
          not_computed(:run_hooks, reason)
      end

    # The canonical post-state identity (RFC-SA2A-001 S12, RFC-SA2A-002 S76),
    # computed by the S12 primitive from this host's own decoded result --
    # not by the host under test, whose engine digest is lenient about
    # unparseable input and is not RDFC-1.0.
    post_state_identity =
      case hooks do
        {:ok, decoded} ->
          case CanonicalGraph.canonical_digest(
                 ResultProjection.hook_result_turtle(vector.id, decoded)
               ) do
            {:ok, digest} ->
              {:ok, digest}

            {:error, reason} ->
              {:error,
               %{
                 code: :sa2a_degenerate_result,
                 step: :post_state_identity,
                 cause: CanonicalGraph.describe(reason)
               }}
          end

        {:error, reason} ->
          not_computed(:run_hooks, reason)
      end

    # Same rule one call over: a failed `validate_all/5` is not summarised
    # into `"validation_unavailable=..."` and hashed. Two hosts that failed
    # identically would otherwise agree on that digest too.
    validation_digest =
      case validation do
        {:ok, decoded} ->
          digest_call(
            mod,
            session,
            :blake3_hex,
            [ResultProjection.validation_summary(decoded)],
            :blake3_validation
          )

        {:error, reason} ->
          not_computed(:validate_all, reason)
      end

    # Repeat of the third call. See the "Stability" section of the module
    # doc: without it, `same_input_identity` can report agreement about a
    # quantity that is not a function of the graph.
    input_graph_hash_repeat =
      digest_call(mod, session, :graph_hash, [vector.base], :graph_hash_input_repeat)

    # The evidence package is a fixed-order rendering of the four quantities
    # above. If any of them is absent the package would render an empty field
    # -- and two runtimes missing the same field would produce the identical
    # evidence digest. So the sixth call is skipped too.
    evidence_hash =
      case {input_graph_hash, validation_digest, output_graph_hash} do
        {{:ok, input}, {:ok, validation_hash}, {:ok, output}} ->
          digest_call(
            mod,
            session,
            :blake3_hex,
            [
              evidence_package(vector, version, %{
                input_graph_hash: input,
                state: state,
                validation_digest: validation_hash,
                output_graph_hash: output
              })
            ],
            :blake3_evidence
          )

        _ ->
          not_computed(:evidence_package, %{
            code: :sa2a_upstream_not_computed,
            message: "an earlier call in this vector's sequence did not produce a value"
          })
      end

    errors =
      Enum.reject(
        [
          error_of(validation, :validate_all),
          error_of(input_graph_hash, :graph_hash_input),
          error_of(hooks, :run_hooks),
          error_of(output_graph_hash, :graph_hash_output),
          error_of(post_state_identity, :post_state_identity),
          error_of(validation_digest, :blake3_validation),
          error_of(evidence_hash, :blake3_evidence),
          error_of(input_graph_hash_repeat, :graph_hash_input_repeat)
        ],
        &is_nil/1
      )

    %{
      vector: vector.id,
      vector_digest: vector.digest,
      # One failed call anywhere in the sequence poisons the whole
      # observation. Every per-vector assertion refuses to compare a vector
      # whose observation is not complete, in either runtime.
      computed: errors == [],
      input_graph_hash: value(input_graph_hash),
      input_graph_hash_repeat: value(input_graph_hash_repeat),
      validation_digest: value(validation_digest),
      admission: state.admission |> Atom.to_string() |> String.upcase(),
      refusal_reason: state.typed_reason,
      state_reached: state.reached |> Atom.to_string() |> String.upcase(),
      state_trace: state.trace,
      output_graph_hash: value(output_graph_hash),
      post_state_identity: value(post_state_identity),
      evidence_hash: value(evidence_hash),
      errors: errors
    }
  end

  # A call whose answer must be a digest. GraphLaw's digest entry points
  # answer a 64-hex string; any other `{:ok, value}` is a degenerate result
  # and is not computed.
  defp digest_call(mod, session, fun, args, step),
    do: mod |> call(session, fun, args) |> admit_digest(step)

  defp admit_digest({:ok, value}, step) do
    if hex64?(value), do: {:ok, value}, else: degenerate(step, value, "a 64-hex digest")
  end

  defp admit_digest(error, _step), do: error

  defp admit_validation({:ok, %{"graph_hash" => hash, "dialects" => [_ | _] = dialects} = v}) do
    if hex64?(hash) and Enum.all?(dialects, &dialect_shape?/1),
      do: {:ok, v},
      else: degenerate(:validate_all, v, "a graph_hash digest and a dialect list")
  end

  defp admit_validation({:ok, other}),
    do: degenerate(:validate_all, other, "a graph_hash digest and a dialect list")

  defp admit_validation(error), do: error

  defp admit_hooks({:ok, %{"status" => status, "verdicts" => verdicts} = hooks})
       when is_binary(status) and status != "" and is_list(verdicts),
       do: {:ok, hooks}

  defp admit_hooks({:ok, other}), do: degenerate(:run_hooks, other, "a status and a verdict list")
  defp admit_hooks(error), do: error

  defp dialect_shape?(%{"dialect" => dialect, "status" => status}),
    do: is_binary(dialect) and dialect != "" and is_binary(status) and status != ""

  defp dialect_shape?(_), do: false

  defp degenerate(step, value, expected) do
    {:error,
     %{
       code: :sa2a_degenerate_result,
       step: step,
       expected: expected,
       got: value |> inspect(limit: 5, printable_limit: 80)
     }}
  end

  defp hex64?(value) when is_binary(value),
    do: byte_size(value) == 64 and String.match?(value, ~r/\A[0-9a-f]{64}\z/)

  defp hex64?(_), do: false

  # A call that was deliberately not issued, because issuing it would have
  # required inventing an input the engine never produced.
  defp not_computed(step, cause),
    do: {:error, %{code: :sa2a_not_computed, skipped_after: step, cause: cause}}

  @doc """
  The canonical evidence package for one vector in one runtime: the exact
  string that runtime hands to `blake3_hex/1`.

  Fixed field order, newline separated, no map iteration anywhere. It carries
  the vector's own digest, so an evidence hash cannot collide across
  different inputs, and it carries the full S41 trace, so two runtimes that
  reached `ADMITTED` by different routes cannot report the same evidence.
  """
  @spec evidence_package(Vector.t(), String.t(), map()) :: String.t()
  def evidence_package(%Vector{} = vector, version, fields) do
    """
    #{@profile}
    vector=#{vector.id}
    vector_digest=#{vector.digest}
    graphlaw_version=#{version}
    input_graph_hash=#{fields.input_graph_hash}
    state_reached=#{fields.state.reached |> Atom.to_string() |> String.upcase()}
    state_trace=#{Enum.join(fields.state.trace, ">")}
    admission=#{fields.state.admission |> Atom.to_string() |> String.upcase()}
    refusal_reason=#{fields.state.typed_reason || ""}
    validation_digest=#{fields.validation_digest}
    output_graph_hash=#{fields.output_graph_hash}
    """
  end

  # Rollups summarise per-vector observations, so a rollup over an incomplete
  # set is a well-formed digest of a failure -- exactly the shape this court
  # must never produce. When any vector's observation is incomplete the
  # runtime-level digests are `nil`, and the receipt says so by name in
  # `observations_complete`.
  defp with_rollups(observation, mod, session) do
    complete? = Enum.all?(observation.vectors, & &1.computed)

    rollup = fn field ->
      if complete? do
        payload =
          observation.vectors
          |> Enum.map_join("", fn v -> "#{v.vector}=#{Map.get(v, field)}\n" end)

        value(digest_call(mod, session, :blake3_hex, [payload], :rollup))
      end
    end

    admission_payload =
      observation.vectors
      |> Enum.map_join("", fn v ->
        "#{v.vector}=#{v.admission}|#{v.refusal_reason || ""}|#{Enum.join(v.state_trace, ">")}\n"
      end)

    all_admitted? = Enum.all?(observation.vectors, &(&1.admission == "ADMITTED"))

    Map.merge(observation, %{
      observations_complete: complete?,
      input_graph_hash: rollup.(:input_graph_hash),
      output_graph_hash: rollup.(:output_graph_hash),
      evidence_hash: rollup.(:evidence_hash),
      admission: if(complete? and all_admitted?, do: "ADMITTED", else: "REFUSED"),
      admission_digest:
        if(complete?,
          do: value(digest_call(mod, session, :blake3_hex, [admission_payload], :rollup))
        )
    })
  end

  # Wasm linear memory as the engine itself reports it, where the runtime
  # module exposes that reading (RFC-SA2A-002 §91 memory per host). Never
  # estimated: a runtime without the reading reports `nil`.
  defp engine_memory(mod, session) do
    if function_exported?(mod, :memory_bytes, 1) do
      case mod.memory_bytes(session) do
        bytes when is_integer(bytes) -> %{"wasm_linear_memory_bytes" => bytes}
        _ -> nil
      end
    end
  rescue
    _ -> nil
  end

  defp engine_of(AshA2A.GraphLaw.RuntimeB = mod, session),
    do: "#{mod.engine_id()} (#{AshA2A.GraphLaw.RuntimeB.reported_engine(session)})"

  defp engine_of(mod, _session), do: mod.engine_id()

  # -- judgement ------------------------------------------------------------

  defp judge(a, b, vectors) do
    assertions = %{
      same_wasm: same_wasm(a, b),
      same_input_identity: same_input_identity(a, b),
      same_admission: same_admission(a, b),
      same_output_semantics: same_output(a, b),
      same_evidence_identity: same_evidence(a, b)
    }

    # `computed` and `value` are separate bits and both must be exactly
    # `true`. An assertion the court could not compute carries
    # `value: nil`, which can never satisfy this and is never a skip.
    passed? =
      Enum.all?(@assertions, fn name ->
        assertion = Map.fetch!(assertions, name)
        assertion.computed == true and assertion.value == true
      end)

    receipt = receipt(a, b, vectors, assertions, passed?)

    emit_vectors(a, b, assertions)

    :telemetry.execute(
      @judged_event,
      %{vector_count: length(vectors), observe_us_a: a.observe_us, observe_us_b: b.observe_us},
      Map.merge(
        %{
          result: receipt["result"],
          runtime_a: inspect(a.runtime),
          runtime_b: inspect(b.runtime),
          wasm_digest: a.wasm_digest,
          wasm_digest_b: b.wasm_digest
        },
        Map.new(@assertions, fn name ->
          {name, assertion_outcome(Map.fetch!(assertions, name))}
        end)
      )
    )

    if passed?, do: {:ok, receipt}, else: {:error, receipt}
  end

  @vector_event [:ash_a2a, :sa2a, :conformance, :vector_judged]

  @doc "Telemetry event emitted once per judged vector (RFC-SA2A-002 §76, §91)."
  @spec vector_event() :: [atom()]
  def vector_event, do: @vector_event

  defp assertion_outcome(%{computed: true, value: true}), do: "true"
  defp assertion_outcome(%{computed: true}), do: "false"
  defp assertion_outcome(_), do: "not_computed"

  # One decision record per vector, derived from the very assertion results
  # the court judged with (never recomputed here), so an independent observer
  # can ask per-fixture questions (§76: Admission_A = Admission_B,
  # CanonicalPostState_A = CanonicalPostState_B, equivalent refusal classes).
  defp emit_vectors(a, b, assertions) do
    incomplete = MapSet.new(incomplete(a, b), & &1["vector"])

    diverged = fn name ->
      assertions
      |> Map.fetch!(name)
      |> Map.get(:divergences, [])
      |> Enum.map(& &1["vector"])
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()
    end

    judged? = fn name -> Map.fetch!(assertions, name).computed == true end

    admission_diverged = diverged.(:same_admission)
    input_diverged = diverged.(:same_input_identity)
    output_diverged = diverged.(:same_output_semantics)

    for {va, vb} <- Enum.zip(a.vectors, b.vectors) do
      id = va.vector
      computed = va.computed and vb.computed and not MapSet.member?(incomplete, id)
      class_a = refusal_class(va)
      class_b = refusal_class(vb)

      :telemetry.execute(
        @vector_event,
        %{latency_us_a: va.latency_us, latency_us_b: vb.latency_us},
        %{
          vector: id,
          vector_digest: va.vector_digest,
          runtime_a: inspect(a.runtime),
          runtime_b: inspect(b.runtime),
          wasm_digest: a.wasm_digest,
          computed: computed,
          admission_a: va.admission,
          admission_b: vb.admission,
          refusal_class_a: class_a,
          refusal_class_b: class_b,
          admission_equal:
            computed and judged?.(:same_admission) and not MapSet.member?(admission_diverged, id),
          refusal_equal: computed and va.admission == vb.admission and class_a == class_b,
          input_identity_equal:
            computed and judged?.(:same_input_identity) and
              not MapSet.member?(input_diverged, id),
          post_state_equal:
            computed and judged?.(:same_output_semantics) and
              not MapSet.member?(output_diverged, id),
          post_state_a: va.post_state_identity,
          post_state_b: vb.post_state_identity,
          degenerate: Enum.any?(va.errors ++ vb.errors, &degenerate_error?/1)
        }
      )
    end
  end

  defp degenerate_error?(%{reason: %{code: :sa2a_degenerate_result}}), do: true
  defp degenerate_error?(_), do: false

  # The S41 hop at which a vector was refused ("NONE" when admitted): the
  # refusal class two hosts must agree on (§76), coarser than the full typed
  # reason `same_admission` compares.
  defp refusal_class(%{admission: "ADMITTED"}), do: "NONE"

  defp refusal_class(%{refusal_reason: reason}) when is_binary(reason),
    do: reason |> String.split(":", parts: 2) |> hd()

  defp refusal_class(_), do: "UNKNOWN"

  defp same_wasm(a, b) do
    cond do
      is_nil(a.wasm_digest) or is_nil(b.wasm_digest) ->
        absent("a runtime reported no wasm digest")

      a.wasm_digest != b.wasm_digest ->
        failed("wasm digests differ", [
          %{"runtime_a" => a.wasm_digest, "runtime_b" => b.wasm_digest}
        ])

      a.graphlaw_version != b.graphlaw_version ->
        failed("identical wasm digest but divergent graphlaw_version", [
          %{"runtime_a" => a.graphlaw_version, "runtime_b" => b.graphlaw_version}
        ])

      true ->
        passed()
    end
  end

  # Canonical post-state (RFC-SA2A-002 S76): the engine's own output digest
  # AND the S12 canonical identity of each host's decoded result must agree.
  defp same_output(a, b) do
    engine = per_vector(a, b, :output_graph_hash)

    if engine.computed and engine.value,
      do: per_vector(a, b, :post_state_identity),
      else: engine
  end

  # Cross-runtime equality is necessary but not sufficient: an input identity
  # that is not a function of the input makes the equality vacuous, so each
  # runtime must also agree with its own repeated measurement.
  defp same_input_identity(a, b) do
    cross = per_vector(a, b, :input_graph_hash)

    unstable =
      [a, b]
      |> Enum.flat_map(fn observation ->
        observation.vectors
        |> Enum.filter(&(&1.input_graph_hash != &1.input_graph_hash_repeat))
        |> Enum.map(
          &%{
            "vector" => &1.vector,
            "runtime" => observation.host,
            "reason" => "graph_hash/1 is not stable across repetition for this graph",
            "first" => &1.input_graph_hash,
            "repeat" => &1.input_graph_hash_repeat
          }
        )
      end)

    cond do
      not cross.computed -> cross
      not cross.value -> cross
      unstable != [] -> failed("input identity is not a function of the input graph", unstable)
      true -> passed()
    end
  end

  # Every incomplete observation, in either runtime, with the steps that
  # failed. A vector listed here is never compared: an engine error is not a
  # value, so two runtimes carrying the same error are not in agreement.
  defp incomplete(a, b) do
    for observation <- [a, b],
        vector <- observation.vectors,
        not vector.computed do
      %{
        "vector" => vector.vector,
        "runtime" => observation.host,
        "reason" => "the engine did not compute this observation; it cannot be compared",
        "failed_steps" => Enum.map(vector.errors, &to_string(&1.step)),
        "errors" => Enum.map(vector.errors, &inspect/1)
      }
    end
  end

  defp per_vector(a, b, field) do
    pairs = Enum.zip(a.vectors, b.vectors)
    incomplete = incomplete(a, b)

    absent =
      Enum.filter(pairs, fn {va, vb} ->
        is_nil(Map.get(va, field)) or is_nil(Map.get(vb, field))
      end)

    divergent =
      Enum.filter(pairs, fn {va, vb} -> Map.get(va, field) != Map.get(vb, field) end)

    cond do
      pairs == [] ->
        absent("no vectors were observed")

      incomplete != [] ->
        absent(
          "#{length(incomplete)} vector observation(s) could not be computed",
          incomplete
        )

      absent != [] ->
        absent(
          "#{length(absent)} vector(s) produced no #{field}",
          Enum.map(absent, fn {va, _} ->
            %{"vector" => va.vector, "errors" => Enum.map(va.errors, &inspect/1)}
          end)
        )

      divergent != [] ->
        failed(
          "#{length(divergent)} vector(s) diverged on #{field}",
          Enum.map(divergent, fn {va, vb} ->
            %{
              "vector" => va.vector,
              "runtime_a" => Map.get(va, field),
              "runtime_b" => Map.get(vb, field)
            }
          end)
        )

      true ->
        passed()
    end
  end

  defp same_admission(a, b) do
    pairs = Enum.zip(a.vectors, b.vectors)
    incomplete = incomplete(a, b)

    divergent =
      Enum.filter(pairs, fn {va, vb} ->
        va.admission != vb.admission or va.refusal_reason != vb.refusal_reason or
          va.state_trace != vb.state_trace
      end)

    cond do
      pairs == [] ->
        absent("no vectors were observed")

      # `run_hooks/2` is the call that decides ADMITTED. If it did not run,
      # there is no admission to agree about, however identically the two
      # state machines described its absence.
      incomplete != [] ->
        absent("#{length(incomplete)} vector observation(s) could not be computed", incomplete)

      a.admission_digest == nil or b.admission_digest == nil ->
        absent("a runtime produced no admission rollup digest")

      divergent != [] ->
        failed(
          "#{length(divergent)} vector(s) diverged on admission, typed refusal, or S41 trace",
          Enum.map(divergent, fn {va, vb} ->
            %{
              "vector" => va.vector,
              "runtime_a" => %{
                "admission" => va.admission,
                "refusal_reason" => va.refusal_reason,
                "state_trace" => va.state_trace
              },
              "runtime_b" => %{
                "admission" => vb.admission,
                "refusal_reason" => vb.refusal_reason,
                "state_trace" => vb.state_trace
              }
            }
          end)
        )

      a.admission_digest != b.admission_digest ->
        failed("admission rollup digests differ", [
          %{"runtime_a" => a.admission_digest, "runtime_b" => b.admission_digest}
        ])

      true ->
        passed()
    end
  end

  defp same_evidence(a, b) do
    per = per_vector(a, b, :evidence_hash)

    cond do
      not per.computed ->
        per

      not per.value ->
        per

      is_nil(a.root_manifest_digest) or is_nil(b.root_manifest_digest) ->
        absent("a runtime reported no root_manifest_digest")

      a.root_manifest_digest != b.root_manifest_digest ->
        failed("root_manifest_digest differs", [
          %{"runtime_a" => a.root_manifest_digest, "runtime_b" => b.root_manifest_digest}
        ])

      true ->
        passed()
    end
  end

  # Three genuinely distinct outcomes, not two. `value` is a truth value only
  # where one was actually computed; where none was, it is `nil` rather than
  # `false`, so "the court could not tell" can never be read as "the court
  # checked and it held", nor be counted toward a pass.
  defp passed, do: %{computed: true, value: true, detail: nil, divergences: []}

  defp failed(detail, divergences),
    do: %{computed: true, value: false, detail: detail, divergences: divergences}

  defp absent(detail, divergences \\ []),
    do: %{computed: false, value: nil, detail: detail, divergences: divergences}

  # -- receipt --------------------------------------------------------------

  defp receipt(a, b, vectors, assertions, passed?) do
    %{
      "profile" => @profile,
      "graphlaw_version" => a.graphlaw_version,
      "wasm_digest" => a.wasm_digest,
      "wasm_digest_algorithm" => a.digest_algorithm,
      "root_manifest_digest" => a.root_manifest_digest,
      "corpus" => %{
        "vector_count" => length(vectors),
        "vectors" => Enum.map(vectors, &%{"id" => &1.id, "digest" => &1.digest})
      },
      "runtime_a" => runtime_section(a),
      "runtime_b" => runtime_section(b),
      "assertions" =>
        Map.new(@assertions, fn name ->
          assertion = Map.fetch!(assertions, name)

          {Atom.to_string(name),
           %{
             "computed" => assertion.computed,
             "value" => assertion.value,
             "detail" => assertion.detail,
             "divergences" => assertion.divergences
           }}
        end),
      "result" => if(passed?, do: "PASS", else: "FAIL"),
      "scope" => %{
        "state_machine_prefix" =>
          StateMachine.states() |> Enum.map(&(&1 |> Atom.to_string() |> String.upcase())),
        "stops_at" => "ADMITTED",
        "actuation" => "none",
        "authority_consulted" => false,
        "command_bus_invoked" => false,
        "establishes" =>
          "portable execution of one identical wasm module across two different hosts " <>
            "over this finite corpus",
        "does_not_establish" => [
          "universal semantic equivalence",
          "production readiness",
          "security completeness",
          "cross-implementation equivalence"
        ]
      }
    }
  end

  defp runtime_section(observation) do
    %{
      "host" => observation.host,
      "engine" => observation.engine,
      "runtime_module" => inspect(observation.runtime),
      "observed_identity" => observation.observed_identity,
      "executed_identity" => observation.executed_identity,
      "observations_complete" => observation.observations_complete,
      "observe_us" => observation.observe_us,
      "engine_memory" => observation.engine_memory,
      "wasm_digest" => observation.wasm_digest,
      "graphlaw_version" => observation.graphlaw_version,
      "root_manifest_digest" => observation.root_manifest_digest,
      "input_graph_hash" => observation.input_graph_hash,
      "admission" => observation.admission,
      "admission_digest" => observation.admission_digest,
      "output_graph_hash" => observation.output_graph_hash,
      "evidence_hash" => observation.evidence_hash,
      "vectors" =>
        Enum.map(observation.vectors, fn v ->
          %{
            "vector" => v.vector,
            "vector_digest" => v.vector_digest,
            "computed" => v.computed,
            "input_graph_hash" => v.input_graph_hash,
            "input_graph_hash_repeat" => v.input_graph_hash_repeat,
            "validation_digest" => v.validation_digest,
            "admission" => v.admission,
            "refusal_reason" => v.refusal_reason,
            "state_reached" => v.state_reached,
            "state_trace" => v.state_trace,
            "output_graph_hash" => v.output_graph_hash,
            "post_state_identity" => v.post_state_identity,
            "evidence_hash" => v.evidence_hash,
            "latency_us" => v.latency_us,
            "errors" => Enum.map(v.errors, &inspect/1)
          }
        end)
    }
  end

  # -- call plumbing --------------------------------------------------------

  defp call(mod, session, fun, args), do: mod.call(session, fun, args)

  defp value({:ok, result}), do: result
  defp value({:error, _}), do: nil

  defp error_of({:error, reason}, label), do: %{step: label, reason: reason}
  defp error_of(_, _), do: nil

  # GraphLaw returns {"error": "..."} JSON instead of raising, so a successful
  # call is not a successful result -- every decoded payload is checked for
  # the error key before it is trusted.
  defp decode({:ok, raw}) do
    case JSON.decode(raw) do
      {:ok, %{"error" => message}} -> {:error, %{code: :graphlaw_error, message: message}}
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, other} -> {:error, %{code: :graphlaw_unexpected_payload, payload: inspect(other)}}
      {:error, reason} -> {:error, %{code: :graphlaw_non_json, reason: inspect(reason), raw: raw}}
    end
  end

  defp decode({:error, reason}), do: {:error, reason}
end
