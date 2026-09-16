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
  result into RDF, and GraphLaw's own RDFC-1.0 canonical hash does the rest.
  The sixth is computed inside each runtime over that runtime's own
  observations, so evidence identity is a real agreement rather than a
  restatement of one runtime's view.

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
    * `same_output_semantics` -- identical canonical hash of the projected
      hook result on every vector.
    * `same_evidence_identity` -- identical per-vector evidence digest, and
      identical corpus `root_manifest_digest`.

  An assertion that could not be computed is a **failure**, never a skip:
  `run/1` returns `{:error, receipt}` when any of the five is absent or
  false, and `mix ash_a2a.sa2a_conformance` exits non-zero on it.

  ## Refusing a degenerate run

  Two runtimes sharing a `{host_id, engine_id}` pair are refused with
  `:sa2a_identical_runtimes` before any vector executes. A court that
  silently ran one runtime twice would report five green assertions and mean
  nothing at all.
  """

  alias AshA2A.GraphLaw.Runtime
  alias AshA2A.SA2A.{ResultProjection, StateMachine, Vector}

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
  `AshA2A.GraphLaw.Runtime`, defaulting to `AshA2A.GraphLaw.Wasm` and
  `AshA2A.GraphLaw.RuntimeB`), plus `:corpus_dir` and `:wasm_path`.

  Returns `{:ok, receipt}` only when all five assertions were computed and
  all five are true; `{:error, receipt}` when any failed; and
  `{:error, reason_map}` when the run could not start at all (identical
  runtimes, an unavailable runtime, a missing or empty corpus).
  """
  @spec run(keyword()) :: {:ok, map()} | {:error, map()}
  def run(opts \\ []) do
    runtime_a = Keyword.get(opts, :runtime_a, AshA2A.GraphLaw.Wasm)
    runtime_b = Keyword.get(opts, :runtime_b, AshA2A.GraphLaw.RuntimeB)

    with :ok <- refuse_identical(runtime_a, runtime_b),
         :ok <- check_available(runtime_a, opts),
         :ok <- check_available(runtime_b, opts),
         {:ok, vectors} <- Vector.load_all(opts),
         {:ok, observed_a} <- observe(runtime_a, vectors, opts),
         {:ok, observed_b} <- observe(runtime_b, vectors, opts) do
      judge(observed_a, observed_b, vectors)
    end
  end

  # -- refusals -------------------------------------------------------------

  defp refuse_identical(mod_a, mod_b) do
    identity_a = Runtime.identity(mod_a)
    identity_b = Runtime.identity(mod_b)

    if identity_a == identity_b do
      {:error,
       %{
         code: :sa2a_identical_runtimes,
         runtime_a: inspect(mod_a),
         runtime_b: inspect(mod_b),
         identity: inspect(identity_a),
         message:
           "both runtimes report the same {host_id, engine_id}. Running one runtime " <>
             "twice cannot establish cross-runtime conformance."
       }}
    else
      :ok
    end
  end

  defp check_available(mod, opts) do
    case mod.available?(opts) do
      :ok -> :ok
      {:error, reason} -> {:error, Map.put(reason, :runtime, inspect(mod))}
    end
  end

  # -- observation ----------------------------------------------------------

  defp observe(mod, vectors, opts) do
    root_manifest = Vector.root_manifest(vectors)

    case mod.open(opts) do
      {:ok, %{session: session, wasm_digest: wasm_digest}} ->
        try do
          with {:ok, version} <- mod.call(session, :graphlaw_version, []),
               {:ok, root_digest} <- mod.call(session, :blake3_hex, [root_manifest]) do
            vector_results = Enum.map(vectors, &observe_vector(mod, session, &1, version))

            {:ok,
             %{
               runtime: mod,
               host: mod.host_id(),
               engine: engine_of(mod, session),
               wasm_digest: wasm_digest,
               digest_algorithm: Runtime.digest_algorithm(),
               graphlaw_version: version,
               root_manifest_digest: root_digest,
               vectors: vector_results
             }
             |> with_rollups(mod, session)}
          else
            {:error, reason} ->
              {:error, Map.put(reason, :runtime, inspect(mod))}
          end
        after
          mod.close(session)
        end

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

    input_graph_hash = call(mod, session, :graph_hash, [vector.base])
    hooks_raw = call(mod, session, :run_hooks, [vector.base, vector.event])

    validation = decode(validation_raw)
    hooks = decode(hooks_raw)

    state = StateMachine.evaluate(value(input_graph_hash), validation, hooks)

    projection =
      case hooks do
        {:ok, decoded} -> ResultProjection.hook_result_turtle(vector.id, decoded)
        {:error, _} -> ResultProjection.hook_result_turtle(vector.id, %{"status" => "ABSENT"})
      end

    output_graph_hash = call(mod, session, :graph_hash, [projection])

    validation_summary =
      case validation do
        {:ok, decoded} -> ResultProjection.validation_summary(decoded)
        {:error, reason} -> "validation_unavailable=#{inspect(reason)}\n"
      end

    validation_digest = call(mod, session, :blake3_hex, [validation_summary])

    evidence_package =
      evidence_package(vector, version, %{
        input_graph_hash: value(input_graph_hash),
        state: state,
        validation_digest: value(validation_digest),
        output_graph_hash: value(output_graph_hash)
      })

    evidence_hash = call(mod, session, :blake3_hex, [evidence_package])

    # Repeat of the third call. See the "Stability" section of the module
    # doc: without it, `same_input_identity` can report agreement about a
    # quantity that is not a function of the graph.
    input_graph_hash_repeat = call(mod, session, :graph_hash, [vector.base])

    %{
      vector: vector.id,
      vector_digest: vector.digest,
      input_graph_hash: value(input_graph_hash),
      input_graph_hash_repeat: value(input_graph_hash_repeat),
      validation_digest: value(validation_digest),
      admission: state.admission |> Atom.to_string() |> String.upcase(),
      refusal_reason: state.typed_reason,
      state_reached: state.reached |> Atom.to_string() |> String.upcase(),
      state_trace: state.trace,
      output_graph_hash: value(output_graph_hash),
      evidence_hash: value(evidence_hash),
      errors:
        Enum.reject(
          [
            error_of(validation_raw, :validate_all),
            error_of(input_graph_hash, :graph_hash_input),
            error_of(hooks_raw, :run_hooks),
            error_of(output_graph_hash, :graph_hash_output),
            error_of(validation_digest, :blake3_validation),
            error_of(evidence_hash, :blake3_evidence),
            error_of(input_graph_hash_repeat, :graph_hash_input_repeat)
          ],
          &is_nil/1
        )
    }
  end

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

  defp with_rollups(observation, mod, session) do
    rollup = fn field ->
      payload =
        observation.vectors
        |> Enum.map_join("", fn v -> "#{v.vector}=#{Map.get(v, field)}\n" end)

      value(call(mod, session, :blake3_hex, [payload]))
    end

    admission_payload =
      observation.vectors
      |> Enum.map_join("", fn v ->
        "#{v.vector}=#{v.admission}|#{v.refusal_reason || ""}|#{Enum.join(v.state_trace, ">")}\n"
      end)

    all_admitted? = Enum.all?(observation.vectors, &(&1.admission == "ADMITTED"))

    Map.merge(observation, %{
      input_graph_hash: rollup.(:input_graph_hash),
      output_graph_hash: rollup.(:output_graph_hash),
      evidence_hash: rollup.(:evidence_hash),
      admission: if(all_admitted?, do: "ADMITTED", else: "REFUSED"),
      admission_digest: value(call(mod, session, :blake3_hex, [admission_payload]))
    })
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
      same_output_semantics: per_vector(a, b, :output_graph_hash),
      same_evidence_identity: same_evidence(a, b)
    }

    passed? =
      Enum.all?(@assertions, fn name ->
        assertion = Map.fetch!(assertions, name)
        assertion.computed and assertion.value
      end)

    receipt = receipt(a, b, vectors, assertions, passed?)

    if passed?, do: {:ok, receipt}, else: {:error, receipt}
  end

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

  defp per_vector(a, b, field) do
    pairs = Enum.zip(a.vectors, b.vectors)

    absent =
      Enum.filter(pairs, fn {va, vb} ->
        is_nil(Map.get(va, field)) or is_nil(Map.get(vb, field))
      end)

    divergent =
      Enum.filter(pairs, fn {va, vb} -> Map.get(va, field) != Map.get(vb, field) end)

    cond do
      pairs == [] ->
        absent("no vectors were observed")

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

    divergent =
      Enum.filter(pairs, fn {va, vb} ->
        va.admission != vb.admission or va.refusal_reason != vb.refusal_reason or
          va.state_trace != vb.state_trace
      end)

    cond do
      pairs == [] ->
        absent("no vectors were observed")

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

  defp passed, do: %{computed: true, value: true, detail: nil, divergences: []}

  defp failed(detail, divergences),
    do: %{computed: true, value: false, detail: detail, divergences: divergences}

  defp absent(detail, divergences \\ []),
    do: %{computed: false, value: false, detail: detail, divergences: divergences}

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
            "input_graph_hash" => v.input_graph_hash,
            "input_graph_hash_repeat" => v.input_graph_hash_repeat,
            "validation_digest" => v.validation_digest,
            "admission" => v.admission,
            "refusal_reason" => v.refusal_reason,
            "state_reached" => v.state_reached,
            "state_trace" => v.state_trace,
            "output_graph_hash" => v.output_graph_hash,
            "evidence_hash" => v.evidence_hash,
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
