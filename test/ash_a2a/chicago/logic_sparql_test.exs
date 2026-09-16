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
