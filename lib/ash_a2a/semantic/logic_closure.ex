defmodule AshA2A.Semantic.LogicClosure do
  @moduledoc """
  SA2A-LOGIC closure boundary (RFC-SA2A-002 §27, §47, §48; RFC-SA2A-001 S13
  RuleClosure): the one lawful entry point that lets an admitted N3 rule
  document derive anything over a fact graph.

  The closure itself is computed by the real `praxis-graphlaw` engine -- the
  vendored `priv/graphlaw/praxis_graphlaw.wasm`, executed in-BEAM by Wasmtime
  through `AshA2A.GraphLaw.WasmexSession`. This module owns what Elixir owns at
  this boundary: rule admission, fact-shape admission, resource bounds, refusal
  typing, candidate standing, and telemetry. It evaluates no rule.

      Program(facts, rules)
        -> facts_shape      facts are plain RDF 1.1 Turtle (RDF.ex, fail-closed)
        -> rule_identity    sha256(rules) is in the caller's admitted rule set
        -> rule_shape       RuleDocument.check/1: range-restricted, function-free,
                            pure builtins only, no hooks
        -> engine           bounded run: deterministic fuel, memory cap,
                            wall-clock interrupt, pinned import surface,
                            fact-identity fidelity, replay agreement,
                            DATALOG / N3_DENIAL verdicts
        -> CANDIDATE closure (authority: :none)

  ## Standing and authority

  A successful closure has `standing: :candidate` and `authority: :none`, and
  no code path sets either to anything else. Derivation is not admission and
  confers no permission: a rule that derives a consequence-bearing intent has
  produced a candidate observation; DO still requires `AshA2A.Authority` at
  `AshA2A.CommandBus`.

  ## Bounds (finite termination)

  Nothing in the engine bounds a fixpoint loop (measured: a
  `(?n 1) math:sum ?m` recursion runs until stopped). Every run is metered with
  Wasmtime fuel, which is deterministic for identical input (measured: the same
  program consumed 13,088,280 fuel on two independent instances), so a program
  either reaches its least fixpoint inside the budget on every run or is
  refused `:refused_closure_bound_exceeded` on every run. A memory cap and a
  wall-clock interrupt back the fuel budget.

  ## Closure digest

  `closure_digest` is sha256 over the canonical JSON of what the engine reported
  about the closure: engine artifact digest, rule document digest, the engine's
  own order-invariant fact-graph hash, the DATALOG and N3_DENIAL verdicts with
  their counts, and the engine's replay hashes. Fuel, wall time and memory are
  excluded -- they vary with fact order (measured: 13,088,280 vs 13,207,658 fuel
  for a permuted chain) without changing the closure.

  UNSUPPORTED, stated so it is never assumed: the vendored v26.7.5 exports
  (`validate_all`, `run_hooks`, `graph_hash`, `blake3_hex`, `graphlaw_version`)
  surface no derived-triple content, no per-triple rule provenance and no
  iteration count. The digest therefore binds derived *cardinality* and denial
  verdicts, not derived content; `entails?/3` asks the engine about specific
  derived facts instead.

  ## Telemetry

  `[:ash_a2a, :logic, :closure, event]` with metadata always carrying
  `:closure_id`:

    * `:start` -- `:rules_digest`, `:facts_digest`
    * `:decision` -- `:stage`, `:outcome` (`:admitted | :refused`), `:code`
    * `:engine` -- `:outcome` (`:completed | :bound_exceeded | :trapped |
      :unavailable | :refused`), `:code`, `:fuel_budget`, `:fuel_consumed`,
      `:peak_memory_bytes`, `:wall_us`, `:import_surface` (`:pinned | :unpinned`),
      `:wasm_digest`, `:datalog_status`, `:derived_count`, `:denial_status`,
      `:replay_status`
    * `:stop` -- `:outcome` (`:admitted | :refused`), `:code`, `:standing`,
      `:authority`, `:closure_digest`, `:derived_count`, `:rule_count`
    * `:entailment` -- `:outcome` (`:entailed | :not_entailed | :refused`)
    * `:replay` -- `:outcome` (`:agreed | :diverged | :refused`)
  """

  alias AshA2A.GraphLaw
  alias AshA2A.GraphLaw.{Manifest, WasmexSession}
  alias AshA2A.Semantic.LawDocument
  alias AshA2A.Semantic.LogicClosure.RuleDocument

  @default_fuel 2_000_000_000
  @default_memory_limit 256 * 1024 * 1024
  @default_timeout_ms 30_000
  # Instantiation and the fidelity hash run before the metered closure call.
  @setup_fuel 50_000_000_000

  @hook_namespaces [
    "http://seanchatmangpt.github.io/praxis/kh#",
    "http://seanchatmangpt.github.io/praxis/hook#"
  ]

  defmodule Program do
    @moduledoc "A fact graph (plain Turtle) plus the N3 rule document to close it under."
    @enforce_keys [:facts, :rules]
    defstruct [:facts, :rules, id: nil]

    @type t :: %__MODULE__{facts: String.t(), rules: String.t(), id: String.t() | nil}
  end

  defmodule Closure do
    @moduledoc "A terminated, engine-computed closure. Always `standing: :candidate`, `authority: :none`."
    @enforce_keys [:closure_id, :closure_digest, :rules_digest, :facts_canonical_hash]
    defstruct [
      :closure_id,
      :closure_digest,
      :rules_digest,
      :facts_digest,
      :facts_canonical_hash,
      :engine_graph_hash,
      :wasm_digest,
      :derived_count,
      :fact_count_before,
      :fact_count_after,
      :rule_count,
      :denial_count,
      :fuel_budget,
      :fuel_consumed,
      :peak_memory_bytes,
      :wall_us,
      standing: :candidate,
      authority: :none
    ]

    @type t :: %__MODULE__{}
  end

  @refusal_codes %{
    refused_facts_not_plain_rdf: :refused_structure,
    refused_hook_in_facts: :refused_namespace,
    refused_unadmitted_rule: :refused_rule,
    refused_rule_document_unclassifiable: :refused_structure,
    refused_rule_not_range_restricted: :refused_rule,
    refused_rule_not_function_free: :refused_rule,
    refused_unadmitted_builtin: :refused_namespace,
    refused_hook_in_rule_document: :refused_namespace,
    refused_engine_unavailable: :blocked_resource,
    refused_engine_import_surface: :refused_meta_rigor,
    refused_closure_bound_exceeded: :refused_bounds,
    refused_engine_trap: :blocked_resource,
    refused_engine_fidelity: :refused_identity,
    refused_closure_replay_divergence: :refused_meta_rigor,
    refused_rule_closure: :refused_rule,
    refused_denial_violated: :refused_falsifier,
    refused_entailment_witness: :refused_structure,
    refused_replay_subject_mismatch: :refused_identity,
    closure_replay_diverged: :refused_meta_rigor
  }

  @doc false
  def __sa2a_refusal_codes__, do: @refusal_codes

  @doc "sha256 hex of the exact rule-document bytes: the rule identity admission is keyed on."
  @spec rules_digest(String.t()) :: String.t()
  def rules_digest(rules) when is_binary(rules), do: Manifest.sha256_hex(rules)

  @doc "The admitted rule set for a list of admitted rule documents."
  @spec admitted_rule_set([String.t()]) :: MapSet.t(String.t())
  def admitted_rule_set(documents), do: MapSet.new(documents, &rules_digest/1)

  @doc "Default bounds: `%{fuel:, memory_limit_bytes:, timeout_ms:}`."
  @spec default_bounds() :: map()
  def default_bounds,
    do: %{
      fuel: @default_fuel,
      memory_limit_bytes: @default_memory_limit,
      timeout_ms: @default_timeout_ms
    }

  @doc """
  Closes `program` under its rules with the real engine.

  Options: `:admitted_rules` (enumerable of admitted rule digests; absent means
  nothing is admitted), `:fuel`, `:memory_limit_bytes`, `:timeout_ms`,
  `:wasm_path` (default the vendored artifact).
  """
  @spec close(Program.t(), keyword()) :: {:ok, Closure.t()} | {:error, map()}
  def close(%Program{} = program, opts \\ []) do
    closure_id = new_id("closure")
    rules_digest = rules_digest(program.rules)
    facts_digest = Manifest.sha256_hex(program.facts)
    base = %{closure_id: closure_id, rules_digest: rules_digest, facts_digest: facts_digest}

    emit(:start, base)

    result =
      with {:ok, graph} <- facts_shape(program, base),
           :ok <- rule_identity(rules_digest, opts, base),
           {:ok, analysis} <- rule_shape(program.rules, base),
           {:ok, run} <- engine(program.facts <> "\n" <> program.rules, program.facts, opts, base) do
        admit_closure(run, graph, analysis, base)
      end

    emit_stop(result, base)
    result
  end

  @doc """
  Asks the engine whether the closure of `program` entails `witness`, an N3
  body pattern with at least one variable (`"ex:a ex:p ?o . ?o log:equalTo ex:c"`).

  The witness is evaluated as a denial query appended after the admitted rules
  (never admitted as a rule): it is entailed iff the engine's N3_DENIAL dialect
  finds a violation it did not find for the program alone. The program must
  close admitted first.
  """
  @spec entails?(Program.t(), String.t(), keyword()) :: {:ok, boolean()} | {:error, map()}
  def entails?(%Program{} = program, witness, opts \\ []) when is_binary(witness) do
    with {:ok, closure} <- close(program, opts) do
      base = %{
        closure_id: closure.closure_id,
        rules_digest: closure.rules_digest,
        facts_digest: closure.facts_digest
      }

      query = program.rules <> "\n{ " <> witness <> " } => false .\n"

      result =
        with :ok <- witness_shape(witness, query),
             {:ok, run} <- engine(program.facts <> "\n" <> query, program.facts, opts, base) do
          {:ok, run.denial_count > closure.denial_count}
        end

      outcome =
        case result do
          {:ok, true} -> :entailed
          {:ok, false} -> :not_entailed
          _ -> :refused
        end

      emit(:entailment, Map.merge(base, %{outcome: outcome, code: error_code(result)}))
      result
    end
  end

  @doc """
  Replays a closure: re-closes `program` on a fresh engine instance and compares
  the closure digest. `program` may render the facts differently (another
  statement order, other prefixes) but must be the same RDF graph (RDFC-1.0) and
  the same rule document.
  """
  @spec replay(Closure.t(), Program.t(), keyword()) :: {:ok, Closure.t()} | {:error, map()}
  def replay(%Closure{} = closure, %Program{} = program, opts \\ []) do
    base = %{
      closure_id: closure.closure_id,
      rules_digest: closure.rules_digest,
      facts_digest: closure.facts_digest
    }

    result =
      with :ok <- replay_subject(closure, program),
           {:ok, replayed} <- close(program, opts) do
        if replayed.closure_digest == closure.closure_digest do
          {:ok, replayed}
        else
          {:error,
           %{
             code: :closure_replay_diverged,
             expected: closure.closure_digest,
             actual: replayed.closure_digest
           }}
        end
      end

    outcome =
      case result do
        {:ok, _} -> :agreed
        {:error, %{code: :closure_replay_diverged}} -> :diverged
        _ -> :refused
      end

    emit(
      :replay,
      Map.merge(base, %{
        outcome: outcome,
        code: error_code(result),
        closure_digest: closure.closure_digest
      })
    )

    result
  end

  # --- stages ---------------------------------------------------------------

  defp facts_shape(%Program{facts: facts}, base) do
    case LawDocument.turtle_graph(facts) do
      {:ok, graph} ->
        case hook_iri(graph) do
          nil ->
            decision(:facts_shape, :admitted, nil, base)
            {:ok, graph}

          iri ->
            refuse(:facts_shape, :refused_hook_in_facts, base,
              reason: "knowledge-hook vocabulary #{iri} in the fact graph"
            )
        end

      {:error, failure} ->
        refuse(:facts_shape, :refused_facts_not_plain_rdf, base, reason: failure.reason)
    end
  end

  defp rule_identity(digest, opts, base) do
    admitted = opts |> Keyword.get(:admitted_rules, []) |> MapSet.new()

    if MapSet.member?(admitted, digest) do
      decision(:rule_identity, :admitted, nil, base)
      :ok
    else
      refuse(:rule_identity, :refused_unadmitted_rule, base,
        reason: "rule document #{digest} is not in the admitted rule set"
      )
    end
  end

  defp rule_shape(rules, base) do
    case RuleDocument.check(rules) do
      {:ok, analysis} ->
        decision(:rule_shape, :admitted, nil, base)
        {:ok, analysis}

      {:error, %{code: code, reason: reason}} ->
        refuse(:rule_shape, :"refused_#{code}", base, reason: reason)
    end
  end

  defp witness_shape(witness, query) do
    with {:ok, _} <- RuleDocument.check(query),
         true <- String.contains?(witness, "?") do
      :ok
    else
      false ->
        {:error,
         %{code: :refused_entailment_witness, reason: "a ground witness never matches a denial"}}

      {:error, %{code: code, reason: reason}} ->
        {:error, %{code: :refused_entailment_witness, rule_code: code, reason: reason}}
    end
  end

  defp replay_subject(%Closure{} = closure, %Program{} = program) do
    cond do
      rules_digest(program.rules) != closure.rules_digest ->
        {:error, %{code: :refused_replay_subject_mismatch, field: :rules_digest}}

      canonical_hash(program.facts) != closure.facts_canonical_hash ->
        {:error, %{code: :refused_replay_subject_mismatch, field: :facts_canonical_hash}}

      true ->
        :ok
    end
  end

  # --- engine ---------------------------------------------------------------

  defp engine(document, facts, opts, base) do
    budget = Keyword.get(opts, :fuel, @default_fuel)

    session_opts = [
      wasm_path: Keyword.get(opts, :wasm_path, GraphLaw.wasm_path()),
      fuel: @setup_fuel,
      memory_limit_bytes: Keyword.get(opts, :memory_limit_bytes, @default_memory_limit),
      call_timeout_ms: Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    ]

    metrics = %{
      fuel_budget: budget,
      memory_limit_bytes: Keyword.fetch!(session_opts, :memory_limit_bytes)
    }

    case WasmexSession.open(session_opts) do
      {:ok, %{session: session, wasm_digest: wasm_digest}} ->
        try do
          metrics = Map.merge(metrics, %{wasm_digest: wasm_digest})
          run_session(session, document, facts, budget, metrics, base)
        after
          WasmexSession.close(session)
        end

      {:error, reason} ->
        refuse_engine(:unavailable, :refused_engine_unavailable, metrics, base,
          reason: inspect(reason)
        )
    end
  end

  defp run_session(session, document, facts, budget, metrics, base) do
    surface =
      if session.module_imports == WasmexSession.pinned_imports(), do: :pinned, else: :unpinned

    metrics = Map.put(metrics, :import_surface, surface)

    with :ok <- pinned_surface(surface, session, metrics, base),
         {:ok, facts_hash} <- fidelity_hash(session, facts, metrics, base) do
      :ok = Wasmex.StoreOrCaller.set_fuel(session.store, budget)
      started = System.monotonic_time(:microsecond)
      reply = WasmexSession.call(session, :validate_all, [document, "", "", "", ""])
      wall_us = System.monotonic_time(:microsecond) - started
      remaining = WasmexSession.fuel_remaining(session) || 0

      metrics =
        Map.merge(metrics, %{
          fuel_consumed: budget - remaining,
          peak_memory_bytes: WasmexSession.memory_bytes(session),
          wall_us: wall_us
        })

      interpret(reply, facts_hash, remaining, metrics, base)
    end
  end

  defp pinned_surface(:pinned, _session, _metrics, _base), do: :ok

  defp pinned_surface(:unpinned, session, metrics, base) do
    refuse_engine(:refused, :refused_engine_import_surface, metrics, base,
      reason: "module imports #{inspect(session.module_imports)} are not the pinned host surface"
    )
  end

  defp fidelity_hash(session, facts, metrics, base) do
    case WasmexSession.call(session, :graph_hash, [facts]) do
      {:ok, hash} when byte_size(hash) == 64 ->
        {:ok, hash}

      other ->
        refuse_engine(:trapped, :refused_engine_trap, metrics, base, reason: inspect(other))
    end
  end

  # A trap can surface from the metered export itself (`:reason`) or from one
  # of the ABI setup calls that share its fuel (`:error`, a MatchError text).
  defp interpret({:error, %{} = error}, _facts_hash, remaining, metrics, base)
       when is_map_key(error, :reason) or is_map_key(error, :error) do
    text = to_string(Map.get(error, :reason) || Map.get(error, :error))

    cond do
      remaining == 0 or text =~ "fuel" ->
        refuse_engine(:bound_exceeded, :refused_closure_bound_exceeded, metrics, base,
          bound: :fuel,
          reason: "closure did not reach a fixpoint within #{metrics.fuel_budget} fuel"
        )

      text =~ "interrupt" or text =~ "timeout" ->
        refuse_engine(:bound_exceeded, :refused_closure_bound_exceeded, metrics, base,
          bound: :wall_clock,
          reason: text
        )

      # Linear memory only grows; a trap within one wasm page of the cap is the
      # cap refusing growth, not an engine fault.
      is_integer(metrics.peak_memory_bytes) and
          metrics.peak_memory_bytes + 65_536 > metrics.memory_limit_bytes ->
        refuse_engine(:bound_exceeded, :refused_closure_bound_exceeded, metrics, base,
          bound: :memory,
          reason: text
        )

      true ->
        refuse_engine(:trapped, :refused_engine_trap, metrics, base, reason: inspect(error))
    end
  end

  defp interpret({:error, error}, _facts_hash, _remaining, metrics, base),
    do: refuse_engine(:trapped, :refused_engine_trap, metrics, base, reason: inspect(error))

  defp interpret({:ok, raw}, facts_hash, _remaining, metrics, base) do
    with {:ok, report} <- decode(raw, metrics, base) do
      datalog = dialect(report, "DATALOG")
      denial = dialect(report, "N3_DENIAL")
      replay = Map.get(report, "replay") || %{}

      metrics =
        Map.merge(metrics, %{
          datalog_status: datalog["status"],
          derived_count: datalog["triples_out"],
          denial_status: denial["status"],
          denial_count: denial["triples_out"],
          replay_status: replay["status"]
        })

      cond do
        report["graph_hash"] != facts_hash ->
          refuse_engine(:refused, :refused_engine_fidelity, metrics, base,
            reason:
              "engine read the program's facts as #{report["graph_hash"]}, the fact graph alone as #{facts_hash}"
          )

        replay["status"] != "ADMITTED" or replay["first_hash"] != replay["second_hash"] ->
          refuse_engine(:refused, :refused_closure_replay_divergence, metrics, base,
            reason: "engine replay #{inspect(replay)}"
          )

        datalog["status"] != "ADMITTED" or not is_integer(datalog["triples_out"]) ->
          refuse_engine(:refused, :refused_rule_closure, metrics, base, reason: inspect(datalog))

        not is_integer(denial["triples_out"]) or denial["status"] not in ["ADMITTED", "REFUSED"] ->
          refuse_engine(:refused, :refused_rule_closure, metrics, base, reason: inspect(denial))

        true ->
          emit(:engine, Map.merge(base, Map.merge(metrics, %{outcome: :completed, code: nil})))
          {:ok, Map.merge(metrics, %{report: report})}
      end
    end
  end

  defp decode(raw, metrics, base) do
    case JSON.decode(raw) do
      {:ok, %{"error" => message}} ->
        refuse_engine(:trapped, :refused_engine_trap, metrics, base, reason: message)

      {:ok, %{} = report} ->
        {:ok, report}

      other ->
        refuse_engine(:trapped, :refused_engine_trap, metrics, base, reason: inspect(other))
    end
  end

  defp dialect(report, name) do
    report
    |> Map.get("dialects", [])
    |> List.wrap()
    |> Enum.find(%{}, &(is_map(&1) and &1["dialect"] == name))
  end

  defp admit_closure(run, graph, analysis, base) do
    if run.denial_status == "REFUSED" do
      refuse(:closure, :refused_denial_violated, base,
        reason: "#{run.denial_count} denial violation(s) over the closure"
      )
    else
      fact_count = RDF.Graph.triple_count(graph)
      report = run.report

      digest =
        Manifest.sha256_hex(
          Manifest.canonical_json(%{
            "schema" => "ash_a2a.logic_closure.digest/1",
            "wasm_digest" => run.wasm_digest,
            "rules_digest" => base.rules_digest,
            "engine_graph_hash" => report["graph_hash"],
            "datalog" => [run.datalog_status, run.derived_count],
            "n3_denial" => [run.denial_status, run.denial_count],
            "replay" => [
              run.replay_status,
              get_in(report, ["replay", "first_hash"]),
              get_in(report, ["replay", "second_hash"])
            ]
          })
        )

      {:ok,
       %Closure{
         closure_id: base.closure_id,
         closure_digest: digest,
         rules_digest: base.rules_digest,
         facts_digest: base.facts_digest,
         facts_canonical_hash: RDF.Graph.canonical_hash(graph),
         engine_graph_hash: report["graph_hash"],
         wasm_digest: run.wasm_digest,
         derived_count: run.derived_count,
         fact_count_before: fact_count,
         fact_count_after: fact_count + run.derived_count,
         rule_count: length(analysis.rules),
         denial_count: run.denial_count,
         fuel_budget: run.fuel_budget,
         fuel_consumed: run.fuel_consumed,
         peak_memory_bytes: run.peak_memory_bytes,
         wall_us: run.wall_us
       }}
    end
  end

  # --- helpers ----------------------------------------------------------------

  defp hook_iri(graph) do
    graph
    |> RDF.Graph.triples()
    |> Enum.flat_map(&Tuple.to_list/1)
    |> Enum.map(&to_string/1)
    |> Enum.find(fn term -> Enum.any?(@hook_namespaces, &String.starts_with?(term, &1)) end)
  end

  defp canonical_hash(facts) do
    case LawDocument.turtle_graph(facts) do
      {:ok, graph} -> RDF.Graph.canonical_hash(graph)
      {:error, _} -> nil
    end
  end

  defp decision(stage, outcome, code, base),
    do: emit(:decision, Map.merge(base, %{stage: stage, outcome: outcome, code: code}))

  defp refuse(stage, code, base, detail) do
    decision(stage, :refused, code, base)
    {:error, Map.merge(%{code: code, stage: stage}, Map.new(detail))}
  end

  defp refuse_engine(outcome, code, metrics, base, detail) do
    emit(:engine, Map.merge(base, Map.merge(metrics, %{outcome: outcome, code: code})))
    {:error, Map.merge(%{code: code, stage: :engine, metrics: metrics}, Map.new(detail))}
  end

  defp emit_stop({:ok, %Closure{} = closure}, base) do
    emit(
      :stop,
      Map.merge(base, %{
        outcome: :admitted,
        code: nil,
        standing: closure.standing,
        authority: closure.authority,
        closure_digest: closure.closure_digest,
        derived_count: closure.derived_count,
        rule_count: closure.rule_count,
        fact_count_before: closure.fact_count_before,
        fact_count_after: closure.fact_count_after
      })
    )
  end

  defp emit_stop({:error, %{code: code}}, base),
    do: emit(:stop, Map.merge(base, %{outcome: :refused, code: code, authority: :none}))

  defp emit(event, metadata),
    do: :telemetry.execute([:ash_a2a, :logic, :closure, event], %{}, metadata)

  defp error_code({:error, %{code: code}}), do: code
  defp error_code(_), do: nil

  defp new_id(prefix),
    do: prefix <> "-" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
end
