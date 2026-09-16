defmodule AshA2A.Semantic.FalsifierSparqlOracleTest do
  @moduledoc """
  Holds every falsifier's **normative** SPARQL 1.1 `ASK` to agreement with the
  structural evaluator that actually runs in this build.

  RFC S18.2 says a graph-global falsifier *is* an ASK query. The measured
  reason this build evaluates them structurally instead is recorded in
  `AshA2A.Semantic.FalsifierSuite`'s moduledoc (the prebuilt GraphLaw wasm
  exposes no query export, and its `run_hooks/2` carries no hooks at all).
  That makes the `:ask` field a claim about semantics that nothing would
  otherwise check -- so this test executes it.

  Chicago school, strictly: the SPARQL engine here is a **real, independent
  SPARQL 1.1 implementation** running in a real OS process over a real file on
  disk, not a stub and not a second Elixir reimplementation of the same
  logic. Its disagreement would mean the structural evaluator is wrong about
  its own normative query. No `Mox`/`:meck`/`Mock(`/`patch`/`monkeypatch`
  equivalent appears anywhere in this file.

  On a machine without that engine the whole module **skips with a named,
  visible reason** -- it never silently substitutes a fake and never reports
  green for a check it did not perform.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Semantic.FalsifierFixtures, as: Fixtures
  alias AshA2A.Semantic.FalsifierSuite, as: Suite
  alias AshA2A.SparqlOracle

  @oracle SparqlOracle.available?()

  case @oracle do
    {:ok, version} ->
      @moduletag oracle: version

    {:error, reason} ->
      @moduletag skip:
                   "no real SPARQL 1.1 engine available, so the normative ASK text was NOT executed: #{reason}"
  end

  describe "the normative ASK text is real, executable SPARQL 1.1" do
    test "every falsifier's ASK parses and executes against a real engine" do
      pairs =
        Enum.map(Suite.falsifiers(), fn f ->
          {:ok, ask} = Suite.ask(f.id)
          {[], ask}
        end)

      assert {:ok, results} = SparqlOracle.ask_many(pairs),
             "at least one normative ASK failed to parse or execute"

      assert length(results) == 14
      assert Enum.all?(results, &is_boolean/1)
    end

    test "an ASK over the empty graph answers false for every falsifier" do
      # Nothing can be violated by a graph with no triples; an ASK that says
      # otherwise would mean the query matches vacuously.
      pairs =
        Enum.map(Suite.falsifiers(), fn f ->
          {:ok, ask} = Suite.ask(f.id)
          {[], ask}
        end)

      assert {:ok, results} = SparqlOracle.ask_many(pairs)

      for {f, fired} <- Enum.zip(Suite.falsifiers(), results) do
        refute fired, "#{f.id} (#{f.rfc}) fires on the empty graph"
      end
    end
  end

  describe "the structural evaluator agrees with a real SPARQL engine on every fixture" do
    for id <- Suite.ids() do
      test "#{id}: engine and structural evaluator agree on the positive fixture" do
        id = unquote(id)
        {:ok, graph} = Fixtures.positive(id)
        {:ok, ask} = Suite.ask(id)

        assert {:ok, engine} = SparqlOracle.ask(graph, ask)
        assert {:ok, structural} = Suite.evaluate(graph, id)

        assert engine == true,
               "the normative ASK for #{id} did NOT detect its own positive fixture"

        assert structural == engine,
               "structural evaluator (#{structural}) disagrees with SPARQL engine (#{engine}) for #{id}"
      end

      test "#{id}: engine and structural evaluator agree on the negative fixture" do
        id = unquote(id)
        {:ok, graph} = Fixtures.negative(id)
        {:ok, ask} = Suite.ask(id)

        assert {:ok, engine} = SparqlOracle.ask(graph, ask)
        assert {:ok, structural} = Suite.evaluate(graph, id)

        assert engine == false,
               "the normative ASK for #{id} fired on its own negative fixture"

        assert structural == engine,
               "structural evaluator (#{structural}) disagrees with SPARQL engine (#{engine}) for #{id}"
      end
    end

    test "cross-product: every ASK agrees with the structural evaluator on every fixture" do
      # Not just each falsifier against its own fixtures -- each of the
      # fourteen ASKs is executed against all twenty-eight fixture graphs, so
      # a falsifier that fires on some other falsifier's fixture is caught
      # here rather than assumed away. 14 x 28 = 392 real engine executions,
      # batched into one engine process (see AshA2A.SparqlOracle.ask_many/1).
      fixtures =
        Enum.flat_map(Fixtures.all(), fn {id, pos, neg} ->
          [{id, :positive, pos}, {id, :negative, neg}]
        end)

      cases =
        for f <- Suite.falsifiers(), {fixture_id, polarity, graph} <- fixtures do
          {:ok, ask} = Suite.ask(f.id)
          {f, fixture_id, polarity, graph, ask}
        end

      assert length(cases) == 392

      assert {:ok, engine_results} =
               SparqlOracle.ask_many(Enum.map(cases, fn {_, _, _, g, ask} -> {g, ask} end))

      for {{f, fixture_id, polarity, graph, _ask}, engine} <- Enum.zip(cases, engine_results) do
        assert {:ok, structural} = Suite.evaluate(graph, f.id)

        assert structural == engine,
               "#{f.id} (#{f.rfc}): structural=#{structural} engine=#{engine} " <>
                 "on the #{polarity} fixture of #{fixture_id}"
      end
    end
  end

  describe "the aggregating falsifiers agree at their boundaries" do
    test "fan-out: engine and structural evaluator agree at, and one over, the bound" do
      plan = "http://example.org/sa2a-fixture#planB"
      {:ok, ask} = Suite.ask(:plan_exceeds_fanout_bound)

      base = [
        {plan, Suite.sa("fanOutBound"), {:int, 3}},
        {plan, Suite.sa("hasSubStep"), "http://example.org/s1"},
        {plan, Suite.sa("hasSubStep"), "http://example.org/s2"},
        {plan, Suite.sa("hasSubStep"), "http://example.org/s3"}
      ]

      over = base ++ [{plan, Suite.sa("hasSubStep"), "http://example.org/s4"}]

      assert SparqlOracle.ask(base, ask) == {:ok, false}
      assert Suite.evaluate(base, :plan_exceeds_fanout_bound) == {:ok, false}
      assert SparqlOracle.ask(over, ask) == {:ok, true}
      assert Suite.evaluate(over, :plan_exceeds_fanout_bound) == {:ok, true}
    end

    test "resource envelope: engine and structural evaluator agree at, and one over, budget" do
      plan = "http://example.org/sa2a-fixture#planD"
      step = "http://example.org/sa2a-fixture#stepD"
      {:ok, ask} = Suite.ask(:plan_exceeds_resource_envelope)

      at_budget = [
        {plan, Suite.sa("resourceBudget"), {:int, 5}},
        {plan, Suite.sa("hasSubStep"), step},
        {step, Suite.sa("resourceCost"), {:int, 5}}
      ]

      over = List.replace_at(at_budget, 2, {step, Suite.sa("resourceCost"), {:int, 6}})

      assert SparqlOracle.ask(at_budget, ask) == {:ok, false}
      assert Suite.evaluate(at_budget, :plan_exceeds_resource_envelope) == {:ok, false}
      assert SparqlOracle.ask(over, ask) == {:ok, true}
      assert Suite.evaluate(over, :plan_exceeds_resource_envelope) == {:ok, true}
    end

    test "a budgeted plan with no declared costs: empty SPARQL group yields no row" do
      plan = "http://example.org/sa2a-fixture#planE"
      {:ok, ask} = Suite.ask(:plan_exceeds_resource_envelope)

      graph = [
        {plan, Suite.sa("resourceBudget"), {:int, 0}},
        {plan, Suite.sa("hasSubStep"), "http://example.org/sa2a-fixture#stepE"}
      ]

      assert SparqlOracle.ask(graph, ask) == {:ok, false}
      assert Suite.evaluate(graph, :plan_exceeds_resource_envelope) == {:ok, false}
    end
  end
end
