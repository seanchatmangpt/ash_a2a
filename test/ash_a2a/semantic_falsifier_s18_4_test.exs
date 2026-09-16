defmodule AshA2A.SemanticFalsifierS184Test do
  @moduledoc """
  Regression cover for the RFC S18.4 false negatives in
  `AshA2A.Semantic.FalsifierSuite.check_update/2`.

  Three real mutations of canonical state were admitted before the fix. Each
  appears below verbatim as the verifier reported it, with the reason the old
  target-scan missed it. The suite also pins the two controls the fix must
  not break -- a legitimate staging update stays permitted, an explicit
  canonical target stays refused -- and re-runs the fourteen S61 falsifiers to
  show none of them regressed.

  Every collaborator is real: the real `FalsifierSuite`, the real
  `FalsifierFixtures` graphs, and real SPARQL Update text.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Semantic.{Falsifier, FalsifierFixtures, FalsifierSuite}

  @canonical "http://example.org/canonical"
  @staging "http://example.org/staging"
  @rdf_type "http://www.w3.org/1999/02/22-rdf-syntax-ns#type"

  # A real classification graph: one canonical graph, one staging graph.
  defp graph do
    [
      {@canonical, @rdf_type, FalsifierSuite.sa("CanonicalGraph")},
      {@staging, @rdf_type, FalsifierSuite.sa("StagingGraph")}
    ]
  end

  defp check(update), do: FalsifierSuite.check_update(graph(), update)

  defp refused_because(update) do
    assert {:error, %{code: :refused_sparql_update_on_canonical, detail: detail}} = check(update)
    detail
  end

  describe "the three mutations the verifier found admitted" do
    test "1. canonical write target written as a prefixed name, masked by a staging IRI in WHERE" do
      # The old regex matched only `<...>`, so `GRAPH c:canonical` named no
      # target; the only target it found was the staging IRI in the read
      # clause, and it admitted.
      update = """
      PREFIX c: <http://example.org/>
      INSERT { GRAPH c:canonical { ?s ?p ?o } }
      WHERE  { GRAPH <#{@staging}> { ?s ?p ?o } }
      """

      detail = refused_because(update)

      assert detail.target_kind == :unresolvable_graph_operand
      assert detail.reason =~ "rather than an <IRIREF>"
    end

    test "2. unqualified INSERT template writing the default graph, masked by staging in WHERE" do
      # An INSERT template not opened by GRAPH writes the DEFAULT graph,
      # which in Strict is canonical consequential state.
      update = "INSERT { ?s ?p ?o } WHERE { GRAPH <#{@staging}> { ?s ?p ?o } }"

      detail = refused_because(update)

      assert detail.target == :default_graph
      assert detail.reason =~ "writes the default graph"
    end

    test "3. MOVE DEFAULT TO <staging>, which destroys the default graph" do
      # MOVE removes its source. `DEFAULT` is a keyword operand, not an
      # IRIREF, so the old scan saw only the staging IRI and admitted.
      detail = refused_because("MOVE DEFAULT TO <#{@staging}>")

      assert detail.target_kind == :keyword_graph_operand
      assert detail.reason =~ "DEFAULT/ALL/NAMED"
    end
  end

  describe "the controls the fix must not break" do
    test "a legitimate staging-graph update is still permitted" do
      assert :ok =
               check(
                 "INSERT DATA { GRAPH <#{@staging}> { <http://e/a> <http://e/p> <http://e/b> } }"
               )
    end

    test "every staging-scoped operation form stays permitted" do
      permitted = [
        "INSERT DATA { GRAPH <#{@staging}> { <http://e/a> <http://e/p> <http://e/b> } }",
        "DELETE DATA { GRAPH <#{@staging}> { <http://e/a> <http://e/p> <http://e/b> } }",
        "DELETE WHERE { GRAPH <#{@staging}> { ?s ?p ?o } }",
        "WITH <#{@staging}> DELETE { ?s ?p ?o } INSERT { ?s ?p <http://e/b> } WHERE { ?s ?p ?o }",
        "INSERT { GRAPH <#{@staging}> { ?s ?p ?o } } WHERE { ?s ?p ?o }",
        "CLEAR GRAPH <#{@staging}>",
        "DROP SILENT GRAPH <#{@staging}>",
        "CREATE GRAPH <#{@staging}>",
        "ADD GRAPH <#{@staging}> TO GRAPH <#{@staging}>"
      ]

      for update <- permitted do
        assert :ok = check(update), "wrongly refused a staging-only update: #{inspect(update)}"
      end
    end

    test "an explicit canonical target is still refused" do
      detail =
        refused_because(
          "INSERT DATA { GRAPH <#{@canonical}> { <http://e/a> <http://e/p> <http://e/b> } }"
        )

      assert detail.target == @canonical
      assert detail.target_kind == :graph_iri
    end

    test "a mutating update naming no graph at all is still refused" do
      assert %{target: :default_graph} =
               refused_because("INSERT DATA { <http://e/a> <http://e/p> <http://e/b> }")
    end

    test "an unclassified graph is not staging" do
      detail =
        refused_because(
          "INSERT DATA { GRAPH <http://example.org/nowhere> { <a:b> <a:c> <a:d> } }"
        )

      assert detail.target == "http://example.org/nowhere"
    end

    test "a non-mutating query is not an update" do
      assert :ok = check("SELECT ?s WHERE { GRAPH <#{@canonical}> { ?s ?p ?o } }")
      assert :ok = check("ASK { ?s ?p ?o }")
    end
  end

  describe "the other keyword-operand mutations of canonical state" do
    for update <- [
          "COPY <http://example.org/staging> TO DEFAULT",
          "MOVE <http://example.org/staging> TO DEFAULT",
          "ADD <http://example.org/staging> TO DEFAULT",
          "CLEAR DEFAULT",
          "CLEAR ALL",
          "DROP ALL",
          "DROP NAMED"
        ] do
      test "#{update} is refused" do
        assert {:error, %{code: :refused_sparql_update_on_canonical}} = check(unquote(update))
      end
    end
  end

  describe "comments and string literals can neither create nor mask evidence" do
    test "a staging IRI inside a comment does not authorise a default-graph write" do
      update = """
      # GRAPH <#{@staging}>
      INSERT DATA { <http://e/a> <http://e/p> <http://e/b> }
      """

      assert {:error, %{code: :refused_sparql_update_on_canonical}} = check(update)
    end

    test "a staging IRI inside a string literal does not authorise it either" do
      update = ~s|INSERT DATA { <http://e/a> <http://e/p> "GRAPH <#{@staging}>" }|

      assert {:error, %{code: :refused_sparql_update_on_canonical}} = check(update)
    end

    test "a mutating keyword hidden inside a literal is still treated as mutating" do
      # `mutating_form/1` runs over the raw text too, so scrubbing can only
      # ever add a refusal, never remove one.
      assert {:error, %{code: :refused_sparql_update_on_canonical}} =
               check(~s|SELECT ?s WHERE { ?s ?p "INSERT DATA" }|)
    end
  end

  describe "the fourteen S61 falsifiers still have teeth" do
    defp trips?(graph, id) do
      assert {:ok, tripped} = FalsifierSuite.evaluate(graph, id)
      tripped
    end

    test "none fires on the empty graph" do
      for %Falsifier{id: id} <- FalsifierSuite.falsifiers() do
        refute trips?([], id), "#{id} fired on the empty graph"
      end
    end

    test "each fires on its own positive fixture and not on its negative one" do
      for %Falsifier{id: id} <- FalsifierSuite.falsifiers() do
        assert {:ok, positive} = FalsifierFixtures.positive(id)
        assert {:ok, negative} = FalsifierFixtures.negative(id)

        assert trips?(positive, id), "#{id} did not fire on its own positive fixture"
        refute trips?(negative, id), "#{id} fired on its own negative fixture"
      end
    end

    test "each fires on exactly one of the fourteen independent positive fixtures" do
      # The discrimination claim: a falsifier that fired on several fixtures
      # would be detecting something more general than its own condition.
      for %Falsifier{id: id} <- FalsifierSuite.falsifiers() do
        fired_on =
          for {other, positive, _negative} <- FalsifierFixtures.all(),
              trips?(positive, id),
              do: other

        assert fired_on == [id], "#{id} fired on #{inspect(fired_on)}"
      end
    end

    test "all fourteen are present" do
      assert length(FalsifierSuite.falsifiers()) == 14
    end
  end
end
