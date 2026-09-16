defmodule AshA2A.Chicago.Courts.SafeLogic do
  @moduledoc """
  RFC-SA2A-002 §27 / §47 / §48 / §86 court: Safe Finite Datalog, N3 rule
  standing, and Benchmark SA2A-B2 (logic closure), against the real
  `AshA2A.Semantic.LogicClosure` boundary executing the real vendored
  `praxis-graphlaw` wasm in Wasmtime, plus the real `AshA2A.CommandBus` for the
  derivation-is-not-authority falsifier.

  Attempt evidence is the boundary's own `[:ash_a2a, :logic, :closure, ...]`
  and `[:ash_a2a, :command_bus, ...]` telemetry (mapped by `ocel_mappings/0`),
  never an event this court emits. Post-state is read independently:
  `Ash.read!/1` for the intent resource, a real loopback TCP listener for
  network access, the returned closure struct for standing.

  B2 lives here rather than in the core SPARQL court because §86 scopes it to
  LOGIC profiles.
  """

  use AshA2A.Chicago.Court

  alias AshA2A.{Authority, Command, CommandBus, Identity}
  alias AshA2A.Chicago.{Context, Falsifier, Result}
  alias AshA2A.Chicago.Fixtures.LogicSparql, as: F
  alias AshA2A.Chicago.Fixtures.LogicSparql.{Intent, NetworkProbe}
  alias AshA2A.Chicago.Ocel.Mapping
  alias AshA2A.Semantic.LogicClosure
  alias AshA2A.Semantic.LogicClosure.Program

  @court "SA2A-LOGIC"
  @chain_k 12
  @b2_iterations 5

  @impl true
  def id, do: @court
  @impl true
  def title, do: "Safe finite Datalog, N3 rule standing, and B2 logic closure"
  @impl true
  def gate, do: nil
  @impl true
  def profile, do: :logic
  @impl true
  def rfc_sections, do: ["§12", "§27", "§47", "§48", "§86", "§100", "§102", "§125"]

  @closure_events [:start, :decision, :engine, :stop, :entailment, :replay]
  @closure_attributes [
    :stage,
    :outcome,
    :code,
    :standing,
    :authority,
    :closure_digest,
    :derived_count,
    :rule_count,
    :fact_count_before,
    :fact_count_after,
    :fuel_budget,
    :fuel_consumed,
    :peak_memory_bytes,
    :wall_us,
    :import_surface,
    :wasm_digest,
    :datalog_status,
    :denial_status,
    :replay_status
  ]

  @impl true
  def ocel_mappings do
    for event <- @closure_events do
      Mapping.new!(
        event: [:ash_a2a, :logic, :closure, event],
        activity: "logic.closure.#{event}",
        source: __MODULE__,
        objects: fn _m, meta ->
          [
            {"logic_closure", meta[:closure_id], "closure"},
            {"rule_document", meta[:rules_digest], "rules"},
            {"fact_document", meta[:facts_digest], "facts"}
          ]
        end,
        attributes: fn _m, meta -> Map.take(meta, @closure_attributes) end
      )
    end
  end

  # --- declarations ------------------------------------------------------------

  @gate_forbidden {:any,
                   [
                     {:observed, "logic.closure.engine"},
                     {:observed, "logic.closure.stop", %{"outcome" => "admitted"}}
                   ]}

  @impl true
  def falsifiers do
    [
      gate(1, "rule_identity", "refused_unadmitted_rule",
        invariant: "Only an admitted rule document (exact identity) may derive anything",
        stimulus:
          "close/2 of the transitive program with an admitted set that does not contain its digest",
        guard: "LogicClosure.rule_identity/3 admitted-set membership",
        tags: [:n3, :rule_identity]
      ),
      gate(2, "rule_identity", "refused_unadmitted_rule",
        invariant:
          "Rule identity is the exact bytes: an admitted document plus one appended rule is unadmitted",
        stimulus:
          "close/2 of the admitted transitive rules with one extra symmetric rule appended",
        guard: "LogicClosure.rules_digest/1 over exact bytes + rule_identity/3",
        tags: [:n3, :rule_identity]
      ),
      gate(3, "facts_shape", "refused_facts_not_plain_rdf",
        invariant: "The fact channel cannot carry rules: a `=>` rule inside the facts is refused",
        stimulus: "close/2 with a fact document carrying `{ ?x e:edge ?y } => { ?y e:edge ?x }`",
        guard: "LogicClosure.facts_shape/2 strict RDF 1.1 Turtle parse",
        tags: [:n3, :rule_identity]
      ),
      gate(4, "facts_shape", "refused_facts_not_plain_rdf",
        invariant: "The fact channel cannot carry rules spelled as a log:implies formula",
        stimulus:
          "close/2 with facts carrying `{ ... } log:implies { ... }` (measured: engine replay REPLAY_MISMATCH on formulas)",
        guard: "LogicClosure.facts_shape/2 strict RDF 1.1 Turtle parse",
        tags: [:n3, :rule_identity]
      ),
      gate(5, "rule_shape", "refused_rule_not_range_restricted",
        invariant:
          "Range restriction: a head variable not bound by the body is refused even when the document is admitted",
        stimulus:
          "close/2 of `{ ?x e:edge ?y } => { ?x e:related ?w }` with its digest admitted (measured: engine alone reports DATALOG ADMITTED and materialises a triple with an unbound variable)",
        guard: "RuleDocument.check_rules/1 head_vars subset of body_vars",
        tags: [:datalog, :range_restriction]
      ),
      gate(6, "rule_shape", "refused_rule_not_function_free",
        invariant: "Function-free heads: a blank-node (existential) head is refused",
        stimulus:
          "close/2 of `{ ?x e:edge ?y } => { ?y e:parent [ e:edge ?x ] }`, digest admitted",
        guard: "RuleDocument.check_rules/1 head_function_terms",
        tags: [:datalog, :function_free]
      ),
      gate(7, "rule_shape", "refused_rule_not_function_free",
        invariant:
          "Recursion requiring unbounded term creation through head list terms is refused before execution",
        stimulus:
          "close/2 of `{ ?x e:edge ?y } => { ?x e:edge (?y) }`, digest admitted (measured: engine alone creates terms until fuel is exhausted)",
        guard: "RuleDocument.check_rules/1 head_function_terms",
        tags: [:datalog, :function_free, :termination]
      ),
      neg(8,
        invariant:
          "Finite termination: recursion that creates new arithmetic terms forever is bounded and refused, never admitted and never left running",
        stimulus:
          "close/2 of `{ ?x e:n ?n . (?n 1) math:sum ?m } => { ?x e:n ?m }` under the default bounds",
        boundary: "AshA2A.Semantic.LogicClosure engine stage (Wasmtime fuel)",
        forbidden_outcome: "closure admitted, or no terminal logic.closure.stop",
        attempt_evidence: "logic.closure.engine outcome=bound_exceeded",
        survival_evidence: "logic.closure.stop outcome=admitted, or no logic.closure.stop",
        guard:
          "WasmexSession bounded store (consume_fuel) + LogicClosure.interpret/5 fuel classification",
        failure_class: :bound_failure,
        attempt_predicate: {:observed, "logic.closure.engine", %{"outcome" => "bound_exceeded"}},
        outcome_predicate:
          {:any,
           [
             {:observed, "logic.closure.stop", %{"outcome" => "admitted"}},
             {:not_observed, "logic.closure.stop"}
           ]},
        tags: [:datalog, :termination]
      ),
      neg(9,
        invariant:
          "The bound is enforced, not advisory: the same terminating program under a budget below its measured consumption is refused",
        stimulus:
          "close/2 of the #{@chain_k}-node transitive program with fuel = 3/4 of the fuel it consumed under the default bound",
        boundary: "AshA2A.Semantic.LogicClosure engine stage (Wasmtime fuel)",
        forbidden_outcome: "closure admitted under an insufficient budget",
        attempt_evidence: "logic.closure.engine outcome=bound_exceeded",
        survival_evidence: "logic.closure.stop outcome=admitted",
        guard: "WasmexSession bounded store + StoreOrCaller.set_fuel before the metered call",
        failure_class: :bound_failure,
        attempt_predicate: {:observed, "logic.closure.engine", %{"outcome" => "bound_exceeded"}},
        outcome_predicate: {:observed, "logic.closure.stop", %{"outcome" => "admitted"}},
        tags: [:datalog, :termination]
      ),
      gate(10, "rule_shape", "refused_unadmitted_builtin",
        invariant: "Side-effecting builtins are refused: log:semantics (network fetch)",
        stimulus:
          "close/2 of a rule using log:semantics over a live loopback IRI, digest admitted",
        guard: "RuleDocument.check_builtins/1 pure-builtin allow-list",
        tags: [:n3, :side_effects]
      ),
      gate(11, "rule_shape", "refused_unadmitted_builtin",
        invariant: "Side-effecting builtins are refused whatever prefix label spells them",
        stimulus:
          "close/2 of `@prefix net: <...swap/log#>` + `?u net:semantics ?f`, digest admitted",
        guard: "RuleDocument prefix expansion + check_builtins/1",
        tags: [:n3, :side_effects]
      ),
      gate(12, "rule_shape", "refused_unadmitted_builtin",
        invariant: "Side-effecting builtins are refused when written as a full IRI (log:content)",
        stimulus:
          "close/2 of `?u <http://www.w3.org/2000/10/swap/log#content> ?c`, digest admitted",
        guard: "RuleDocument.check_builtins/1",
        tags: [:n3, :side_effects]
      ),
      gate(13, "rule_shape", "refused_unadmitted_builtin",
        invariant:
          "Data cannot become executed rules: log:parsedAsN3 + log:conclusion are refused",
        stimulus:
          "close/2 of a rule parsing a fact literal as N3 and concluding it, digest admitted",
        guard: "RuleDocument pure-builtin allow-list excludes dynamic-rule builtins",
        tags: [:n3, :rule_identity, :side_effects]
      ),
      neg(14,
        invariant:
          "No runtime network access: an admitted closure over an IRI naming a live endpoint makes no connection, and the engine's import surface is only the two pinned host functions",
        stimulus: "close/2 of a log:uri program whose fact names a real loopback listener",
        boundary: "AshA2A.Semantic.LogicClosure engine stage (import surface) + the wasm sandbox",
        forbidden_outcome:
          "a connection accepted by the listener, or an engine run on an unpinned import surface",
        attempt_evidence: "logic.closure.engine outcome=completed",
        survival_evidence:
          "listener accept count > 0 (calibrated), or logic.closure.engine import_surface=unpinned",
        guard: "LogicClosure.pinned_surface/4 + WasmexSession pinned imports",
        failure_class: :actuation_failure,
        attempt_predicate: {:observed, "logic.closure.engine", %{"outcome" => "completed"}},
        outcome_predicate: {:observed, "logic.closure.engine", %{"import_surface" => "unpinned"}},
        tags: [:datalog, :side_effects, :network]
      ),
      neg(15,
        invariant:
          "Determinism: the same admitted input closed twice on independent engine instances yields the identical closure digest",
        stimulus: "close/2 then replay/3 of the #{@chain_k}-node transitive program",
        boundary: "AshA2A.Semantic.LogicClosure.replay/3",
        forbidden_outcome: "replay diverged",
        attempt_evidence: "logic.closure.replay outcome=agreed|diverged",
        survival_evidence: "logic.closure.replay outcome=diverged",
        guard: "closure digest excludes fuel/wall/memory; pinned deterministic getRandomValues",
        failure_class: :replay_failure,
        attempt_predicate: replay_attempt(),
        outcome_predicate: {:observed, "logic.closure.replay", %{"outcome" => "diverged"}},
        tags: [:datalog, :determinism]
      ),
      neg(16,
        invariant:
          "Determinism: permuted fact order under a different prefix label yields the identical closure digest",
        stimulus:
          "close/2 of the chain program, then replay/3 with the facts reversed and re-prefixed",
        boundary: "AshA2A.Semantic.LogicClosure.replay/3",
        forbidden_outcome: "replay diverged",
        attempt_evidence: "logic.closure.replay outcome=agreed|diverged",
        survival_evidence: "logic.closure.replay outcome=diverged",
        guard:
          "closure digest over the engine's order-invariant graph hash, excluding order-dependent fuel",
        failure_class: :replay_failure,
        attempt_predicate: replay_attempt(),
        outcome_predicate: {:observed, "logic.closure.replay", %{"outcome" => "diverged"}},
        tags: [:datalog, :determinism]
      ),
      neg(17,
        invariant:
          "Rule output is candidate-only: a successful closure carries standing candidate and authority none",
        stimulus: "close/2 of the admitted intent-deriving program",
        boundary: "AshA2A.Semantic.LogicClosure admit_closure/4",
        forbidden_outcome:
          "an admitted closure whose standing is not candidate or whose authority is not none",
        attempt_evidence: "logic.closure.stop outcome=admitted",
        survival_evidence: "no logic.closure.stop with standing=candidate authority=none",
        guard:
          "LogicClosure.Closure defaults (standing: :candidate, authority: :none), no setter",
        failure_class: :authority_failure,
        attempt_predicate: {:observed, "logic.closure.stop", %{"outcome" => "admitted"}},
        outcome_predicate:
          {:not_observed, "logic.closure.stop",
           %{"outcome" => "admitted", "standing" => "candidate", "authority" => "none"}},
        tags: [:n3, :standing]
      ),
      neg(18,
        invariant:
          "A rule-derived, semantically valid, consequence-bearing intent still cannot DO without authority",
        stimulus:
          "entails?/3 confirms the rule derived the create intent; CommandBus.run/4 of Intent.create with that label and no Authority",
        boundary: "AshA2A.CommandBus admission",
        forbidden_outcome: "admission, actuation or dispatch of Intent.create; a new Intent row",
        attempt_evidence:
          "logic.closure.entailment outcome=entailed and brce.admission refused authority_required",
        survival_evidence:
          "brce.actuate.start / dispatch.start / brce.admission admitted; label present in an independent Ash.read!",
        guard: "CommandBus.admit/2 authority_required clause",
        failure_class: :authority_failure,
        attempt_predicate:
          {:all,
           [
             {:observed, "logic.closure.entailment", %{"outcome" => "entailed"}},
             {:observed, "brce.admission",
              %{"outcome" => "refused", "code" => "authority_required"}}
           ]},
        outcome_predicate:
          {:any,
           [
             {:observed, "brce.actuate.start"},
             {:observed, "dispatch.start"},
             {:observed, "brce.admission", %{"outcome" => "admitted"}}
           ]},
        tags: [:n3, :authority]
      ),
      pos(19,
        invariant:
          "Positive control for 018: the same derived intent with a matching Authority is admitted, receipted and actuated",
        stimulus: "entails?/3 then CommandBus.run/4 of Intent.create with matching Authority",
        boundary: "AshA2A.CommandBus admission + receipt anchor",
        attempt_evidence: "brce.admission admitted",
        survival_evidence:
          "prepare precedes actuation; commit observed; row visible to Ash.read!",
        attempt_predicate: {:observed, "brce.admission", %{"outcome" => "admitted"}},
        outcome_predicate:
          {:all,
           [
             {:precedes, "brce.prepare", "brce.actuate.start", "command"},
             {:observed, "brce.commit", %{"outcome" => "committed"}}
           ]},
        tags: [:n3, :authority]
      ),
      pos(20,
        invariant:
          "Positive control (identity, shape, bound families): an admitted, safe, recursive program reaches its least fixpoint with the exact expected cardinality",
        stimulus:
          "close/2 of the #{@chain_k}-node chain under the transitive rules, default bounds",
        boundary: "AshA2A.Semantic.LogicClosure",
        attempt_evidence: "logic.closure.stop observed",
        survival_evidence:
          "stop admitted, candidate, derived_count = C(k,2)-(k-1); every decision precedes the engine run",
        attempt_predicate: {:observed, "logic.closure.stop"},
        outcome_predicate:
          {:all,
           [
             {:observed, "logic.closure.stop",
              %{
                "outcome" => "admitted",
                "standing" => "candidate",
                "derived_count" => F.chain_derived(@chain_k)
              }},
             {:precedes, "logic.closure.decision", "logic.closure.engine", "logic_closure"}
           ]},
        tags: [:datalog, :termination]
      ),
      pos(21,
        invariant:
          "Positive control (side-effect family): pure arithmetic and string builtins are admitted and evaluated",
        stimulus: "close/2 of math:sum + string:concat rules over three subjects",
        boundary: "AshA2A.Semantic.LogicClosure",
        attempt_evidence: "logic.closure.stop observed",
        survival_evidence: "stop admitted with derived_count 6",
        attempt_predicate: {:observed, "logic.closure.stop"},
        outcome_predicate:
          {:observed, "logic.closure.stop",
           %{"outcome" => "admitted", "derived_count" => F.pure_builtin_derived()}},
        tags: [:n3, :side_effects]
      ),
      pos(22,
        invariant:
          "Positive control (bound family): a program needing most of its budget completes inside a budget 25% above its measured consumption",
        stimulus:
          "close/2 of the #{@chain_k}-node chain with fuel = 5/4 of its measured consumption",
        boundary: "AshA2A.Semantic.LogicClosure engine stage",
        attempt_evidence: "logic.closure.engine outcome=completed",
        survival_evidence: "stop admitted",
        attempt_predicate: {:observed, "logic.closure.engine", %{"outcome" => "completed"}},
        outcome_predicate: {:observed, "logic.closure.stop", %{"outcome" => "admitted"}},
        tags: [:datalog, :termination]
      ),
      measure(
        23,
        "shallow",
        "B2 shallow: one non-recursive rule over 200 facts, #{@b2_iterations} measured runs after one warmup"
      ),
      measure(
        24,
        "recursive",
        "B2 recursive: transitive closure over a 40-node chain, #{@b2_iterations} measured runs after one warmup"
      ),
      measure(
        25,
        "near_bound",
        "B2 near-bound: transitive closure over a 90-node chain (a large share of the default fuel budget), #{@b2_iterations} measured runs after one warmup"
      )
    ]
  end

  defp replay_attempt do
    {:any,
     [
       {:observed, "logic.closure.replay", %{"outcome" => "agreed"}},
       {:observed, "logic.closure.replay", %{"outcome" => "diverged"}}
     ]}
  end

  defp fid(n), do: "#{@court}-" <> String.pad_leading(Integer.to_string(n), 3, "0")

  defp gate(n, stage, code, fields) do
    neg(
      n,
      Keyword.merge(
        [
          boundary: "AshA2A.Semantic.LogicClosure #{stage} stage",
          forbidden_outcome: "the engine executes the program, or a closure is admitted",
          attempt_evidence:
            "logic.closure.decision stage=#{stage} outcome=refused code=#{code}, or the program reached logic.closure.engine (the targeted gate let it through)",
          survival_evidence:
            "logic.closure.engine observed, or logic.closure.stop outcome=admitted",
          failure_class: :admission_failure,
          # Reaching the engine is also positive evidence the attack got past
          # every gate, so deleting the targeted guard SURVIVES instead of
          # degrading to UNKNOWN (§11, §22). A refusal by any other gate is
          # neither, and stays UNKNOWN.
          attempt_predicate:
            {:any,
             [
               {:observed, "logic.closure.decision",
                %{"stage" => stage, "outcome" => "refused", "code" => code}},
               {:observed, "logic.closure.engine"}
             ]},
          outcome_predicate: @gate_forbidden
        ],
        fields
      )
    )
  end

  defp neg(n, fields), do: declare(n, :negative, fields)
  defp pos(n, fields), do: declare(n, :positive_control, fields)

  defp measure(n, corpus, stimulus) do
    declare(n, :measurement,
      invariant: "SA2A-B2 logic closure cost is reported only for terminating runs (§86)",
      stimulus: stimulus,
      boundary: "AshA2A.Semantic.LogicClosure (real Wasmtime engine)",
      attempt_evidence: "logic.closure.engine outcome=completed for every measured run",
      survival_evidence:
        "fact counts, rule count, derived count, fuel, wall-time distribution, peak linear memory",
      attempt_predicate: {:observed, "logic.closure.engine", %{"outcome" => "completed"}},
      tags: [:benchmark, :b2, String.to_atom(corpus)]
    )
  end

  defp declare(n, kind, fields) do
    Falsifier.new!(
      [id: fid(n), court_id: @court, kind: kind, rfc_sections: ["§27", "§47", "§48"]] ++ fields
    )
  end

  # --- execution ------------------------------------------------------------------

  @impl true
  def run(%Context{} = ctx) do
    fs = Map.new(falsifiers(), &{&1.id, &1})
    f = fn n -> Map.fetch!(fs, fid(n)) end

    admitted =
      LogicClosure.admitted_rule_set([
        F.transitive_rules(),
        F.unsafe_rules(),
        F.existential_rules(),
        F.list_head_rules(),
        F.unbounded_sum_rules(),
        F.side_effecting_rules(:declared_prefix),
        F.side_effecting_rules(:rebound_prefix),
        F.side_effecting_rules(:full_iri),
        F.reification_rules(),
        F.network_rules(),
        F.pure_builtin_rules(),
        F.intent_rules(),
        F.shallow_rules()
      ])

    opts = [admitted_rules: admitted]
    chain = %Program{facts: F.chain_facts(@chain_k), rules: F.transitive_rules()}

    # Positive control first: its measured fuel parameterises 009 and 022.
    {r20, fuel} = safe_recursive(ctx, f.(20), chain, opts)

    probe = NetworkProbe.start()

    gates =
      try do
        [
          gate_run(ctx, f.(1), chain, admitted_rule_set_without(F.transitive_rules())),
          gate_run(ctx, f.(2), %{chain | rules: F.mutated_transitive_rules()}, opts),
          gate_run(ctx, f.(3), %{chain | facts: F.smuggled_facts(:implication)}, opts),
          gate_run(ctx, f.(4), %{chain | facts: F.smuggled_facts(:log_implies)}, opts),
          gate_run(ctx, f.(5), %{chain | rules: F.unsafe_rules()}, opts),
          gate_run(ctx, f.(6), %{chain | rules: F.existential_rules()}, opts),
          gate_run(ctx, f.(7), %{chain | rules: F.list_head_rules()}, opts),
          gate_run(
            ctx,
            f.(10),
            %Program{
              facts: F.network_facts(probe.port),
              rules: F.side_effecting_rules(:declared_prefix)
            },
            opts,
            probe
          ),
          gate_run(
            ctx,
            f.(11),
            %Program{
              facts: F.network_facts(probe.port),
              rules: F.side_effecting_rules(:rebound_prefix)
            },
            opts,
            probe
          ),
          gate_run(
            ctx,
            f.(12),
            %Program{
              facts: F.network_facts(probe.port),
              rules: F.side_effecting_rules(:full_iri)
            },
            opts,
            probe
          ),
          gate_run(
            ctx,
            f.(13),
            %Program{facts: F.reification_facts(), rules: F.reification_rules()},
            opts
          ),
          no_network(ctx, f.(14), probe, opts)
        ]
      after
        NetworkProbe.stop(probe)
      end

    with_store(fn store_opts ->
      gates ++
        [
          unbounded(ctx, f.(8), opts),
          bound_enforced(ctx, f.(9), chain, opts, fuel),
          replay_same(ctx, f.(15), chain, opts),
          replay_permuted(ctx, f.(16), chain, opts),
          candidate_only(ctx, f.(17), opts),
          derived_intent(ctx, f.(18), opts, store_opts, false),
          derived_intent(ctx, f.(19), opts, store_opts, true),
          r20,
          pure_builtins(ctx, f.(21), opts),
          near_bound(ctx, f.(22), chain, opts, fuel),
          b2(
            ctx,
            f.(23),
            "shallow",
            %Program{facts: F.shallow_facts(200), rules: F.shallow_rules()},
            opts
          ),
          b2(
            ctx,
            f.(24),
            "recursive",
            %Program{facts: F.chain_facts(40), rules: F.transitive_rules()},
            opts
          ),
          b2(
            ctx,
            f.(25),
            "near_bound",
            %Program{facts: F.chain_facts(90), rules: F.transitive_rules()},
            opts
          )
        ]
    end)
  end

  # An admitted set that genuinely admits other documents, so a refusal is a
  # membership decision rather than an empty-set short circuit.
  defp admitted_rule_set_without(document) do
    set =
      [F.pure_builtin_rules(), F.shallow_rules()]
      |> LogicClosure.admitted_rule_set()
      |> MapSet.delete(LogicClosure.rules_digest(document))

    [admitted_rules: set]
  end

  defp gate_run(ctx, falsifier, program, opts, probe \\ nil) do
    before = probe && NetworkProbe.connections(probe)
    reply = Context.stimulus(ctx, falsifier, fn -> LogicClosure.close(program, opts) end)
    {:any, [{:observed, "logic.closure.decision", attrs}, _engine]} = falsifier.attempt_predicate
    connections = if probe, do: settle_connections(probe) - before, else: 0

    Result.negative(falsifier,
      attempt_observed?:
        seen?(ctx, falsifier, "logic.closure.decision", attrs) or
          seen?(ctx, falsifier, "logic.closure.engine"),
      forbidden_outcome_observed?:
        seen?(ctx, falsifier, "logic.closure.engine") or match?({:ok, _}, reply) or
          connections > 0,
      evidence: %{"reply_code" => code_of(reply), "network_connections" => connections}
    )
  end

  defp safe_recursive(ctx, falsifier, program, opts) do
    reply = Context.stimulus(ctx, falsifier, fn -> LogicClosure.close(program, opts) end)

    case reply do
      {:ok, closure} ->
        expected = F.chain_derived(@chain_k)

        result =
          Result.positive(falsifier,
            attempt_observed?: seen?(ctx, falsifier, "logic.closure.stop"),
            expected_outcome_observed?:
              closure.derived_count == expected and closure.standing == :candidate and
                closure.fact_count_before == @chain_k - 1 and
                closure.fact_count_after == @chain_k - 1 + expected,
            evidence: closure_evidence(closure)
          )

        {result, closure.fuel_consumed}

      {:error, error} ->
        {Result.positive(falsifier,
           attempt_observed?: seen?(ctx, falsifier, "logic.closure.stop"),
           expected_outcome_observed?: false,
           evidence: %{"reply_code" => code_of(reply), "detail" => inspect(error, limit: 20)}
         ), nil}
    end
  end

  defp unbounded(ctx, falsifier, opts) do
    program = %Program{facts: F.unbounded_sum_facts(), rules: F.unbounded_sum_rules()}
    reply = Context.stimulus(ctx, falsifier, fn -> LogicClosure.close(program, opts) end)

    Result.negative(falsifier,
      attempt_observed?:
        seen?(ctx, falsifier, "logic.closure.engine", %{"outcome" => "bound_exceeded"}),
      forbidden_outcome_observed?:
        match?({:ok, _}, reply) or not seen?(ctx, falsifier, "logic.closure.stop"),
      evidence: %{"reply_code" => code_of(reply), "bound" => bound_of(reply)}
    )
  end

  defp bound_enforced(_ctx, falsifier, _program, _opts, nil),
    do: Result.unknown(falsifier, "positive control 020 produced no fuel measurement")

  defp bound_enforced(ctx, falsifier, program, opts, fuel) do
    budget = div(fuel * 3, 4)

    reply =
      Context.stimulus(ctx, falsifier, fn ->
        LogicClosure.close(program, opts ++ [fuel: budget])
      end)

    Result.negative(falsifier,
      attempt_observed?:
        seen?(ctx, falsifier, "logic.closure.engine", %{"outcome" => "bound_exceeded"}),
      forbidden_outcome_observed?: match?({:ok, _}, reply),
      evidence: %{"reply_code" => code_of(reply), "budget" => budget, "measured_fuel" => fuel}
    )
  end

  defp no_network(ctx, falsifier, probe, opts) do
    program = %Program{facts: F.network_facts(probe.port), rules: F.network_rules()}
    before = NetworkProbe.connections(probe)
    reply = Context.stimulus(ctx, falsifier, fn -> LogicClosure.close(program, opts) end)
    during = settle_connections(probe) - before
    calibrated? = NetworkProbe.calibrate(probe)

    if calibrated? do
      Result.negative(falsifier,
        attempt_observed?:
          seen?(ctx, falsifier, "logic.closure.engine", %{"outcome" => "completed"}) and
            match?({:ok, _}, reply),
        forbidden_outcome_observed?:
          during > 0 or
            seen?(ctx, falsifier, "logic.closure.engine", %{"import_surface" => "unpinned"}),
        evidence: %{
          "network_connections_during_closure" => during,
          "listener_calibrated" => true,
          "port" => probe.port,
          "reply_code" => code_of(reply)
        }
      )
    else
      Result.unknown(
        falsifier,
        "loopback network observer failed calibration; absence of connections proves nothing"
      )
    end
  end

  defp replay_same(ctx, falsifier, program, opts) do
    replay_run(ctx, falsifier, program, program, opts)
  end

  defp replay_permuted(ctx, falsifier, program, opts) do
    permuted = %{program | facts: F.chain_facts(@chain_k, :reverse)}
    replay_run(ctx, falsifier, program, permuted, opts)
  end

  defp replay_run(ctx, falsifier, program, replayed, opts) do
    reply =
      Context.stimulus(ctx, falsifier, fn ->
        with {:ok, closure} <- LogicClosure.close(program, opts),
             {:ok, again} <- LogicClosure.replay(closure, replayed, opts) do
          {:ok, closure, again}
        end
      end)

    {forbidden, evidence} =
      case reply do
        {:ok, a, b} ->
          {a.closure_digest != b.closure_digest,
           %{
             "digest_first" => a.closure_digest,
             "digest_replay" => b.closure_digest,
             "fuel_first" => a.fuel_consumed,
             "fuel_replay" => b.fuel_consumed
           }}

        {:error, %{code: :closure_replay_diverged} = e} ->
          {true, %{"expected" => e.expected, "actual" => e.actual}}

        other ->
          {:unknown, %{"reply" => inspect(other, limit: 20)}}
      end

    Result.negative(falsifier,
      attempt_observed?:
        seen?(ctx, falsifier, "logic.closure.replay", %{"outcome" => "agreed"}) or
          seen?(ctx, falsifier, "logic.closure.replay", %{"outcome" => "diverged"}),
      forbidden_outcome_observed?: forbidden,
      evidence: evidence
    )
  end

  defp candidate_only(ctx, falsifier, opts) do
    label = "candidate-#{System.unique_integer([:positive])}"
    program = %Program{facts: F.intent_facts(label), rules: F.intent_rules()}
    reply = Context.stimulus(ctx, falsifier, fn -> LogicClosure.close(program, opts) end)

    forbidden =
      case reply do
        {:ok, closure} ->
          closure.standing != :candidate or closure.authority != :none

        _ ->
          :unknown
      end

    Result.negative(falsifier,
      attempt_observed?: seen?(ctx, falsifier, "logic.closure.stop", %{"outcome" => "admitted"}),
      forbidden_outcome_observed?: forbidden,
      evidence:
        case reply do
          {:ok, c} ->
            %{"standing" => c.standing, "authority" => c.authority, "derived" => c.derived_count}

          other ->
            %{"reply_code" => code_of(other)}
        end
    )
  end

  defp derived_intent(ctx, falsifier, opts, store_opts, authorized?) do
    label =
      "derived-intent-#{if authorized?, do: "authorized", else: "unauthorized"}-#{System.unique_integer([:positive])}"

    program = %Program{facts: F.intent_facts(label), rules: F.intent_rules()}

    reply =
      Context.stimulus(ctx, falsifier, fn ->
        case LogicClosure.entails?(program, F.intent_witness(label), opts) do
          {:ok, true} ->
            {:derived,
             CommandBus.run(intent_command(label, authorized?), message(label), Intent,
               store_opts: store_opts
             )}

          other ->
            {:not_derived, other}
        end
      end)

    present? = label in intent_labels()

    case {authorized?, reply} do
      {false, {:derived, bus_reply}} ->
        Result.negative(falsifier,
          attempt_observed?:
            seen?(ctx, falsifier, "logic.closure.entailment", %{"outcome" => "entailed"}) and
              seen?(ctx, falsifier, "brce.admission", %{
                "outcome" => "refused",
                "code" => "authority_required"
              }),
          forbidden_outcome_observed?:
            present? or seen?(ctx, falsifier, "brce.actuate.start") or
              seen?(ctx, falsifier, "dispatch.start"),
          evidence: %{"bus_reply_code" => code_of(bus_reply), "row_present" => present?}
        )

      {true, {:derived, {:ok, receipt}}} ->
        Result.positive(falsifier,
          attempt_observed?: seen?(ctx, falsifier, "brce.admission", %{"outcome" => "admitted"}),
          expected_outcome_observed?: present? and seen?(ctx, falsifier, "brce.commit"),
          evidence: %{"receipt_id" => receipt.receipt_id, "row_present" => present?}
        )

      {true, {:derived, other}} ->
        Result.positive(falsifier,
          attempt_observed?: seen?(ctx, falsifier, "brce.admission"),
          expected_outcome_observed?: false,
          evidence: %{"bus_reply" => inspect(other, limit: 20)}
        )

      {_, {:not_derived, other}} ->
        Result.unknown(
          falsifier,
          "the rule-derived intent was not confirmed by the engine: #{inspect(other, limit: 20)}"
        )
    end
  end

  defp pure_builtins(ctx, falsifier, opts) do
    program = %Program{facts: F.pure_builtin_facts(), rules: F.pure_builtin_rules()}
    reply = Context.stimulus(ctx, falsifier, fn -> LogicClosure.close(program, opts) end)

    Result.positive(falsifier,
      attempt_observed?: seen?(ctx, falsifier, "logic.closure.stop"),
      expected_outcome_observed?: match?({:ok, %{derived_count: n}} when n == 6, reply),
      evidence:
        case reply do
          {:ok, c} -> closure_evidence(c)
          other -> %{"reply_code" => code_of(other)}
        end
    )
  end

  defp near_bound(_ctx, falsifier, _program, _opts, nil),
    do: Result.unknown(falsifier, "positive control 020 produced no fuel measurement")

  defp near_bound(ctx, falsifier, program, opts, fuel) do
    budget = fuel + div(fuel, 4)

    reply =
      Context.stimulus(ctx, falsifier, fn ->
        LogicClosure.close(program, opts ++ [fuel: budget])
      end)

    Result.positive(falsifier,
      attempt_observed?:
        seen?(ctx, falsifier, "logic.closure.engine", %{"outcome" => "completed"}),
      expected_outcome_observed?: match?({:ok, _}, reply),
      evidence: %{"budget" => budget, "measured_fuel" => fuel, "reply_code" => code_of(reply)}
    )
  end

  defp b2(ctx, falsifier, corpus, program, opts) do
    runs =
      Context.stimulus(ctx, falsifier, fn ->
        for _ <- 0..@b2_iterations, do: LogicClosure.close(program, opts)
      end)

    [_warmup | measured] = runs
    closures = for {:ok, closure} <- measured, do: closure
    completed? = length(closures) == @b2_iterations

    measurements =
      if completed? do
        [first | _] = closures
        walls = closures |> Enum.map(& &1.wall_us) |> Enum.sort()
        fuels = closures |> Enum.map(& &1.fuel_consumed) |> Enum.uniq()

        %{
          "benchmark_id" => "SA2A-B2",
          "corpus" => corpus,
          "fact_count_before" => first.fact_count_before,
          "rule_count" => first.rule_count,
          "fact_count_after" => first.fact_count_after,
          "derived_count" => first.derived_count,
          "closure_iterations" => nil,
          "closure_iterations_status" =>
            "UNSUPPORTED: praxis-graphlaw v26.7.5 validate_all reports no fixpoint iteration count",
          "fuel_consumed" => first.fuel_consumed,
          "fuel_deterministic" => length(fuels) == 1,
          "fuel_budget" => first.fuel_budget,
          "fuel_share_of_budget" => Float.round(first.fuel_consumed / first.fuel_budget, 4),
          "wall_us_p50" => percentile(walls, 50),
          "wall_us_p95" => percentile(walls, 95),
          "wall_us_max" => List.last(walls),
          "wall_us_min" => hd(walls),
          "peak_linear_memory_bytes" =>
            closures |> Enum.map(& &1.peak_memory_bytes) |> Enum.max(),
          "iterations" => @b2_iterations,
          "warmup_policy" => "1 discarded run",
          "closure_digest" => first.closure_digest,
          "digest_stable" =>
            closures |> Enum.map(& &1.closure_digest) |> Enum.uniq() |> length() == 1,
          "fixture_digest" => LogicClosure.rules_digest(program.facts <> program.rules),
          "environment" => environment(first)
        }
      else
        %{}
      end

    Result.measured(falsifier,
      attempt_observed?:
        completed? and seen?(ctx, falsifier, "logic.closure.engine", %{"outcome" => "completed"}),
      measurements: measurements,
      evidence: %{"completed_runs" => length(closures), "codes" => Enum.map(runs, &code_of/1)}
    )
  end

  # --- helpers --------------------------------------------------------------------

  defp seen?(ctx, falsifier, activity, attrs \\ %{}) do
    ctx
    |> Context.observed(falsifier)
    |> Enum.any?(fn record ->
      record.activity == activity and
        Enum.all?(attrs, fn {k, v} -> to_string(Map.get(record.attributes, k)) == to_string(v) end)
    end)
  end

  defp settle_connections(probe) do
    Process.sleep(150)
    NetworkProbe.connections(probe)
  end

  defp code_of({:error, %{code: code}}), do: Atom.to_string(code)
  defp code_of({:ok, _}), do: "ok"
  defp code_of(other), do: inspect(other, limit: 5)

  defp bound_of({:error, %{bound: bound}}), do: Atom.to_string(bound)
  defp bound_of(_), do: nil

  defp closure_evidence(c) do
    %{
      "closure_digest" => c.closure_digest,
      "derived_count" => c.derived_count,
      "fact_count_before" => c.fact_count_before,
      "fact_count_after" => c.fact_count_after,
      "fuel_consumed" => c.fuel_consumed,
      "standing" => c.standing,
      "authority" => c.authority
    }
  end

  defp percentile(sorted, p) do
    index = max(ceil(p / 100 * length(sorted)) - 1, 0)
    Enum.at(sorted, index)
  end

  defp environment(closure) do
    %{
      "otp_release" => to_string(:erlang.system_info(:otp_release)),
      "erts" => to_string(:erlang.system_info(:version)),
      "elixir" => System.version(),
      "architecture" => to_string(:erlang.system_info(:system_architecture)),
      "logical_processors" => :erlang.system_info(:logical_processors),
      "os" => inspect(:os.type()) <> " " <> inspect(:os.version()),
      "beam_memory_total_bytes" => :erlang.memory(:total),
      "wasm_engine" => "wasmtime via wasmex #{Application.spec(:wasmex, :vsn)}",
      "wasm_digest" => closure.wasm_digest,
      "memory_limit_bytes" => LogicClosure.default_bounds().memory_limit_bytes,
      "storage" => "in-memory (no I/O on the measured path)",
      "network" => "none on the measured path"
    }
  end

  defp with_store(fun) do
    name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    {:ok, pid} = AshA2A.ReceiptStore.Memory.start_link(name: name)

    try do
      fun.(name: name)
    after
      if Process.alive?(pid), do: GenServer.stop(pid)
    end
  end

  defp intent_labels, do: Intent |> Ash.read!() |> Enum.map(& &1.label)

  defp message(label), do: A2A.Message.new_user([A2A.Part.Data.new(%{"label" => label})])

  defp intent_command(label, authorized?) do
    {:ok, skill} = AshA2A.Info.skill(Intent, :create_intent)
    principal = Identity.principal("chicago-logic-subject")

    Command.new(skill.id,
      command_id: "chicago-logic-" <> label,
      agent_id: "chicago-logic-agent",
      principal_id: principal,
      authority:
        if(authorized?, do: Authority.new(principal, skill.id, token_id: "tok-" <> label)),
      input: %{label: label}
    )
  end
end
