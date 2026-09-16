defmodule AshA2A.Semantic.FalsifierSuiteTest do
  @moduledoc """
  RFC-SA2A-001 S18/S61 falsifier conformance.

  Chicago-school throughout: real graphs, real evaluators, state-based
  assertions on the real returned verdicts and the real refusal maps. No
  `Mox`/`:meck`/`Mock(`/`patch`/`monkeypatch` equivalent appears anywhere in
  this file -- there is nothing here to fake, because every collaborator
  (the suite, the fixtures, the graphs) is a real in-process value.

  The central property is *discrimination*, not merely firing: for each of
  the fourteen mandatory falsifiers the positive fixture must trip it and the
  negative fixture must not. A falsifier that only ever fires has not been
  shown to distinguish anything.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Semantic.FalsifierFixtures, as: Fixtures
  alias AshA2A.Semantic.FalsifierSuite, as: Suite

  describe "suite definition (RFC S61)" do
    test "defines exactly the fourteen mandatory falsifiers, with unique ids" do
      falsifiers = Suite.falsifiers()

      assert length(falsifiers) == 14
      assert Enum.map(falsifiers, & &1.id) == Suite.ids()
      assert Enum.uniq(Suite.ids()) == Suite.ids()
      assert Enum.all?(falsifiers, & &1.mandatory)
    end

    test "every falsifier carries a normative ASK query and an RFC section" do
      for f <- Suite.falsifiers() do
        assert {:ok, ask} = Suite.ask(f.id)
        assert ask =~ "ASK"
        assert ask =~ "PREFIX sa:"
        assert f.rfc =~ ~r/^S61\.\d+$/
        assert f.title != ""
      end
    end

    test "RFC subsections S61.1 through S61.14 are each covered exactly once" do
      sections = Suite.falsifiers() |> Enum.map(& &1.rfc) |> Enum.sort()
      expected = Enum.sort(for n <- 1..14, do: "S61.#{n}")
      assert sections == expected
    end

    test "report/0 partitions the suite into closed and deferred" do
      report = Suite.report()

      assert length(report) == 14
      assert Enum.all?(report, &(&1.standing in [:closed, :deferred]))

      assert Enum.filter(report, &(&1.standing == :deferred)) |> Enum.map(& &1.id) ==
               Enum.map(Suite.deferred(), & &1.id)

      assert length(Suite.closed()) + length(Suite.deferred()) == 14
    end

    test "unknown falsifier ids are refused, not silently ignored" do
      assert {:error, %{code: :unknown_falsifier, detail: :nope}} = Suite.falsifier(:nope)
      assert {:error, %{code: :unknown_falsifier}} = Suite.ask(:nope)
      assert {:error, %{code: :unknown_falsifier}} = Suite.evaluate([], :nope)
      assert {:error, %{code: :unknown_falsifier}} = Fixtures.positive(:nope)
      assert {:error, %{code: :unknown_falsifier}} = Fixtures.negative(:nope)
    end
  end

  describe "discrimination: every falsifier separates its positive from its negative fixture" do
    for id <- Suite.ids() do
      test "#{id}: positive fixture trips it, negative fixture does not" do
        id = unquote(id)

        assert {:ok, positive} = Fixtures.positive(id)
        assert {:ok, negative} = Fixtures.negative(id)

        assert {:ok, true} = Suite.evaluate(positive, id)
        assert {:ok, false} = Suite.evaluate(negative, id)
      end

      test "#{id}: positive fixture trips EXACTLY this falsifier and no other" do
        id = unquote(id)
        {:ok, positive} = Fixtures.positive(id)

        assert %{tripped: [^id]} = Suite.run(positive)
      end

      test "#{id}: negative fixture trips nothing at all" do
        id = unquote(id)
        {:ok, negative} = Fixtures.negative(id)

        assert %{tripped: []} = Suite.run(negative)
      end
    end

    test "every fixture pair differs -- a pair that was accidentally identical would pass nothing" do
      for {id, positive, negative} <- Fixtures.all() do
        refute Enum.sort(positive) == Enum.sort(negative),
               "fixtures for #{id} are identical; the negative is not a control"
      end
    end
  end

  describe "RFC S18.2: a true mandatory falsifier blocks admission" do
    test "admit/1 refuses every positive fixture and names which falsifier tripped" do
      for {id, positive, _negative} <- Fixtures.all() do
        assert {:error, refusal} = Suite.admit(positive)
        assert refusal.code == :refused_falsifier
        assert refusal.detail.falsifier == id
        assert refusal.detail.falsifiers == [id]

        {:ok, f} = Suite.falsifier(id)
        assert refusal.detail.rfc == [f.rfc]
      end
    end

    test "admit/1 admits every negative fixture" do
      for {id, _positive, negative} <- Fixtures.all() do
        assert Suite.admit(negative) == :ok, "negative fixture for #{id} was refused"
      end
    end

    test "admit/1 names every falsifier that tripped when a graph violates several" do
      {:ok, a} = Fixtures.positive(:consequence_without_authority_requirement)
      {:ok, b} = Fixtures.positive(:canonical_mutation_outside_brce)
      {:ok, c} = Fixtures.positive(:do_without_prepared_receipt)

      assert {:error, refusal} = Suite.admit(a ++ b ++ c)

      assert refusal.detail.falsifiers == [
               :consequence_without_authority_requirement,
               :do_without_prepared_receipt,
               :canonical_mutation_outside_brce
             ]

      # The named single falsifier is the first in RFC S61 order, deterministically.
      assert refusal.detail.falsifier == :consequence_without_authority_requirement
      assert refusal.detail.rfc == ["S61.1", "S61.2", "S61.14"]
    end

    test "an empty graph trips nothing and is admitted" do
      assert Suite.run([]) == %{tripped: [], clear: Suite.ids()}
      assert Suite.admit([]) == :ok
    end
  end

  describe "graph set semantics" do
    test "duplicated triples cannot change a verdict (the aggregating falsifiers)" do
      # F07 counts sub-steps; if multiplicity leaked in, duplicating a
      # sub-step edge in the NEGATIVE fixture would push the count over the
      # bound and trip a falsifier that must stay clear.
      {:ok, negative} = Fixtures.negative(:plan_exceeds_fanout_bound)
      doubled = negative ++ negative

      assert {:ok, false} = Suite.evaluate(doubled, :plan_exceeds_fanout_bound)
      assert %{tripped: []} = Suite.run(doubled)

      # F08 sums resource cost; the same leak would inflate the sum.
      {:ok, envelope} = Fixtures.negative(:plan_exceeds_resource_envelope)
      assert {:ok, false} = Suite.evaluate(envelope ++ envelope, :plan_exceeds_resource_envelope)
    end

    test "triple order cannot change a verdict" do
      for {id, positive, negative} <- Fixtures.all() do
        assert Suite.evaluate(Enum.reverse(positive), id) == {:ok, true}, "order-sensitive: #{id}"

        assert Suite.evaluate(Enum.reverse(negative), id) == {:ok, false},
               "order-sensitive: #{id}"
      end
    end
  end

  describe "boundary behaviour of the aggregating falsifiers" do
    test "fan-out at exactly the bound is admitted; one over trips" do
      plan = "http://example.org/sa2a-fixture#planB"

      at_bound = [
        {plan, Suite.sa("fanOutBound"), {:int, 3}},
        {plan, Suite.sa("hasSubStep"), "http://example.org/s1"},
        {plan, Suite.sa("hasSubStep"), "http://example.org/s2"},
        {plan, Suite.sa("hasSubStep"), "http://example.org/s3"}
      ]

      assert {:ok, false} = Suite.evaluate(at_bound, :plan_exceeds_fanout_bound)

      over = at_bound ++ [{plan, Suite.sa("hasSubStep"), "http://example.org/s4"}]
      assert {:ok, true} = Suite.evaluate(over, :plan_exceeds_fanout_bound)
    end

    test "a plan with a bound but no sub-steps does not trip (empty group, no row)" do
      plan = "http://example.org/sa2a-fixture#planC"

      assert {:ok, false} =
               Suite.evaluate(
                 [{plan, Suite.sa("fanOutBound"), {:int, 0}}],
                 :plan_exceeds_fanout_bound
               )
    end

    test "resource cost exactly at budget is admitted; one over trips" do
      plan = "http://example.org/sa2a-fixture#planD"
      step = "http://example.org/sa2a-fixture#stepD"

      at_budget = [
        {plan, Suite.sa("resourceBudget"), {:int, 5}},
        {plan, Suite.sa("hasSubStep"), step},
        {step, Suite.sa("resourceCost"), {:int, 5}}
      ]

      assert {:ok, false} = Suite.evaluate(at_budget, :plan_exceeds_resource_envelope)

      over =
        List.replace_at(at_budget, 2, {step, Suite.sa("resourceCost"), {:int, 6}})

      assert {:ok, true} = Suite.evaluate(over, :plan_exceeds_resource_envelope)
    end

    test "a budgeted plan whose sub-steps declare no cost does not trip" do
      plan = "http://example.org/sa2a-fixture#planE"

      graph = [
        {plan, Suite.sa("resourceBudget"), {:int, 0}},
        {plan, Suite.sa("hasSubStep"), "http://example.org/sa2a-fixture#stepE"}
      ]

      assert {:ok, false} = Suite.evaluate(graph, :plan_exceeds_resource_envelope)
    end
  end

  describe "RFC S18.3: a CONSTRUCT projection does not automatically acquire standing" do
    test "a bare projection of a canonical graph has no standing" do
      {:ok, projection} = Fixtures.negative(:projection_claiming_canonical_source)

      assert Suite.projection_standing(projection, "http://example.org/sa2a-fixture#projection1") ==
               :none
    end

    test "standing is not inherited from the projected canonical graph" do
      projection = [
        {"http://example.org/sa2a-fixture#projection1", Suite.sa("projectionOf"),
         "http://example.org/sa2a-fixture#canonicalGraph1"},
        {"http://example.org/sa2a-fixture#canonicalGraph1", Suite.rdf_type(),
         Suite.sa("CanonicalGraph")},
        {"http://example.org/sa2a-fixture#canonicalGraph1", Suite.sa("grantedStanding"),
         {:lit, "ADMITTED"}}
      ]

      assert Suite.projection_standing(projection, "http://example.org/sa2a-fixture#projection1") ==
               :none
    end

    test "standing is acquired only by an explicit grant on the projection itself" do
      {:ok, base} = Fixtures.negative(:projection_claiming_canonical_source)

      granted =
        base ++
          [
            {"http://example.org/sa2a-fixture#projection1", Suite.sa("grantedStanding"),
             {:lit, "ADMITTED"}}
          ]

      assert Suite.projection_standing(granted, "http://example.org/sa2a-fixture#projection1") ==
               :admitted
    end

    test "a projection that asserts itself canonical trips F11 (RFC S61.11)" do
      {:ok, overreaching} = Fixtures.positive(:projection_claiming_canonical_source)

      assert {:ok, true} = Suite.evaluate(overreaching, :projection_claiming_canonical_source)
      assert {:error, %{code: :refused_falsifier}} = Suite.admit(overreaching)
    end
  end

  describe "RFC S18.4: direct SPARQL Update against canonical admitted state is prohibited" do
    setup do
      %{graph: Fixtures.update_classification()}
    end

    test "a mutating update against a canonical graph is refused", %{graph: graph} do
      update = """
      PREFIX ex: <http://example.org/>
      INSERT DATA { GRAPH <#{Fixtures.canonical_graph_iri()}> { ex:a ex:p ex:b } }
      """

      assert {:error, refusal} = Suite.check_update(graph, update)
      assert refusal.code == :refused_sparql_update_on_canonical
      assert refusal.detail.rfc == "S18.4"
      assert refusal.detail.form == "INSERT DATA"
      assert refusal.detail.target == Fixtures.canonical_graph_iri()
      assert refusal.detail.reason =~ "canonical"
    end

    test "the same update against a staging graph is permitted", %{graph: graph} do
      update = """
      PREFIX ex: <http://example.org/>
      INSERT DATA { GRAPH <#{Fixtures.staging_graph_iri()}> { ex:a ex:p ex:b } }
      """

      assert Suite.check_update(graph, update) == :ok
    end

    test "every mutating operation form is recognised against canonical", %{graph: graph} do
      canonical = Fixtures.canonical_graph_iri()

      cases = [
        {"INSERT DATA", "INSERT DATA { GRAPH <#{canonical}> { <urn:a> <urn:p> <urn:b> } }"},
        {"DELETE DATA", "DELETE DATA { GRAPH <#{canonical}> { <urn:a> <urn:p> <urn:b> } }"},
        {"DELETE WHERE", "DELETE WHERE { GRAPH <#{canonical}> { ?s ?p ?o } }"},
        {"CLEAR", "CLEAR GRAPH <#{canonical}>"},
        {"DROP", "DROP GRAPH <#{canonical}>"},
        {"LOAD", "LOAD <http://example.org/data.ttl> INTO GRAPH <#{canonical}>"},
        {"COPY", "COPY GRAPH <#{canonical}> TO GRAPH <#{canonical}>"}
      ]

      for {form, update} <- cases do
        assert {:error, refusal} = Suite.check_update(graph, update),
               "#{form} was not refused against a canonical graph"

        assert refusal.code == :refused_sparql_update_on_canonical
        assert refusal.detail.form == form
      end
    end

    test "a mutating update naming no graph is refused (default graph is canonical in Strict)",
         %{graph: graph} do
      assert {:error, refusal} =
               Suite.check_update(graph, "INSERT DATA { <urn:a> <urn:p> <urn:b> }")

      assert refusal.detail.target == :default_graph
      assert refusal.detail.reason =~ "default graph"
    end

    test "a mutating update naming an unclassified graph is refused, not admitted", %{
      graph: graph
    } do
      update =
        "INSERT DATA { GRAPH <http://example.org/unknown-graph> { <urn:a> <urn:p> <urn:b> } }"

      assert {:error, refusal} = Suite.check_update(graph, update)
      assert refusal.detail.target == "http://example.org/unknown-graph"
      assert refusal.detail.reason =~ "not classified"
    end

    test "a read-only query is not an update and is permitted", %{graph: graph} do
      assert Suite.check_update(graph, "SELECT ?s WHERE { ?s ?p ?o }") == :ok
      assert Suite.check_update(graph, "ASK { ?s ?p ?o }") == :ok

      assert Suite.check_update(graph, "CONSTRUCT { ?s ?p ?o } WHERE { ?s ?p ?o }") == :ok
    end

    test "an update touching both a staging and a canonical graph is refused", %{graph: graph} do
      update = """
      DELETE { GRAPH <#{Fixtures.canonical_graph_iri()}> { ?s ?p ?o } }
      INSERT { GRAPH <#{Fixtures.staging_graph_iri()}> { ?s ?p ?o } }
      WHERE  { GRAPH <#{Fixtures.staging_graph_iri()}> { ?s ?p ?o } }
      """

      assert {:error, refusal} = Suite.check_update(graph, update)
      assert refusal.detail.targets == [Fixtures.canonical_graph_iri()]
    end
  end

  describe "N-Triples serialization" do
    test "is deterministic, order-independent and deduplicating" do
      {:ok, graph} = Fixtures.positive(:plan_exceeds_resource_envelope)

      canonical = Suite.to_ntriples(graph)

      assert Suite.to_ntriples(Enum.reverse(graph)) == canonical
      assert Suite.to_ntriples(graph ++ graph) == canonical
      assert Suite.to_ntriples(Enum.shuffle(graph)) == canonical
    end

    test "emits real N-Triples terms for IRIs, plain literals and typed integers" do
      graph = [
        {"http://example.org/s", "http://example.org/p", "http://example.org/o"},
        {"http://example.org/s", "http://example.org/lit", {:lit, "hello"}},
        {"http://example.org/s", "http://example.org/num", {:int, 42}}
      ]

      lines = graph |> Suite.to_ntriples() |> String.split("\n", trim: true)

      assert "<http://example.org/s> <http://example.org/p> <http://example.org/o> ." in lines
      assert "<http://example.org/s> <http://example.org/lit> \"hello\" ." in lines

      assert "<http://example.org/s> <http://example.org/num> \"42\"^^<http://www.w3.org/2001/XMLSchema#integer> ." in lines
    end

    test "escapes literal content that would otherwise break the serialization" do
      graph = [{"http://example.org/s", "http://example.org/p", {:lit, ~s(a "b" c\nd)}}]

      line = graph |> Suite.to_ntriples() |> String.trim()

      assert line == ~S(<http://example.org/s> <http://example.org/p> "a \"b\" c\nd" .)
    end
  end

  describe "integration with the existing semantic vocabulary" do
    test "rdf:type is taken from the real prefix registry, not re-declared" do
      assert Suite.rdf_type() == AshA2A.Semantic.Vocabulary.expand("rdf:type")
      assert Suite.rdf_type() == "http://www.w3.org/1999/02/22-rdf-syntax-ns#type"
    end

    test "the provenance predicate matches the one AshA2A.Semantic.Ontology already emits" do
      assert Suite.prov("wasDerivedFrom") ==
               AshA2A.Semantic.Vocabulary.expand("prov:wasDerivedFrom")
    end
  end
end
