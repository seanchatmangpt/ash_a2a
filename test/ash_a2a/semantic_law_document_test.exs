defmodule AshA2A.SemanticLawDocumentTest do
  @moduledoc """
  Chicago-school tests for `AshA2A.Semantic.LawDocument`.

  Real RDF.ex parsing of real Turtle, real `Jason` decoding of real ShExJ, and
  a real character scan over real N3 -- every collaborator here is runnable
  in-process, so nothing is mocked and nothing is stubbed. Assertions are on
  the real returned counts and the real returned failure maps.
  """

  use ExUnit.Case, async: true

  doctest AshA2A.Semantic.LawDocument

  alias AshA2A.Semantic.LawDocument
  alias AshA2A.Test.SA2AAdmissionFixtures, as: Fixtures

  describe "turtle_graph/1 fails closed where the wasm export does not" do
    test "garbage is an error, not an empty graph" do
      assert {:error, failure} = LawDocument.turtle_graph("@@@ not turtle at all ;;; <<<")
      assert failure.code == :turtle_not_parseable
      assert failure.reason =~ "Turtle scanner error"
    end

    test "real Turtle parses to a real graph" do
      assert {:ok, graph} = LawDocument.turtle_graph(Fixtures.conforming_graph())
      assert RDF.Graph.triple_count(graph) == 3
    end
  end

  describe "shacl_shape_count/1" do
    test "the real shapes fixture declares a real shape" do
      assert {:ok, count} = LawDocument.shacl_shape_count(Fixtures.shacl_shapes())
      assert count >= 1
    end

    test "a document that parses but declares no shape counts zero" do
      for vacuous <- ["#", "", "@prefix sh: <http://www.w3.org/ns/shacl#> .", "   "] do
        assert {:ok, 0} = LawDocument.shacl_shape_count(vacuous)
      end
    end

    test "a subject carrying only sh:targetClass still counts as a shape" do
      doc = """
      @prefix sh: <http://www.w3.org/ns/shacl#> .
      @prefix ex: <http://example.org/> .
      ex:S sh:targetClass ex:Goal .
      """

      assert {:ok, 1} = LawDocument.shacl_shape_count(doc)
    end

    test "unparseable shapes are a typed failure, never a zero count" do
      assert {:error, %{code: :turtle_not_parseable}} = LawDocument.shacl_shape_count("@@@")
    end
  end

  describe "owl_axiom_count/1" do
    test "the real profile fixture declares a real axiom" do
      assert {:ok, 1} = LawDocument.owl_axiom_count(Fixtures.profile())
    end

    test "Turtle carrying no OWL/RDFS vocabulary constrains nothing" do
      assert {:ok, 0} =
               LawDocument.owl_axiom_count("<http://a/s> <http://a/p> <http://a/o> .")
    end

    test "rdfs vocabulary counts as a profile axiom" do
      assert {:ok, 1} =
               LawDocument.owl_axiom_count(
                 "<http://a/A> <http://www.w3.org/2000/01/rdf-schema#subClassOf> <http://a/B> ."
               )
    end
  end

  describe "shex_shape_count/1 and shex_shape_map_count/1" do
    test "the real ShExJ fixture declares one shape and the shape map one binding" do
      assert {:ok, 1} = LawDocument.shex_shape_count(Fixtures.shex_schema())
      assert {:ok, 1} = LawDocument.shex_shape_map_count(Fixtures.shex_shape_map())
    end

    test "an empty schema and an empty shape map both count zero" do
      assert {:ok, 0} = LawDocument.shex_shape_count(~s({"shapes":[]}))
      assert {:ok, 0} = LawDocument.shex_shape_map_count("[]")
    end

    test "non-JSON law is a typed failure, never a zero count" do
      assert {:error, %{code: :shex_schema_not_json}} = LawDocument.shex_shape_count("#")
      assert {:error, %{code: :shex_shape_map_not_json}} = LawDocument.shex_shape_map_count("#")
      assert {:error, %{code: :shex_schema_not_an_object}} = LawDocument.shex_shape_count("[]")

      assert {:error, %{code: :shex_shape_map_not_a_list}} =
               LawDocument.shex_shape_map_count("{}")

      assert {:error, %{code: :shex_schema_has_no_shapes_key}} =
               LawDocument.shex_shape_count(~s({"other":1}))
    end
  end

  describe "n3_rule_count/1 recognises statements, never evaluates them" do
    test "the real falsifier fixture declares one rule" do
      assert LawDocument.n3_rule_count(Fixtures.falsifiers()) == 1
    end

    test "the verifier's minimal repro -- a lone comment declares zero rules" do
      assert LawDocument.n3_rule_count("#") == 0
      assert LawDocument.n3_rule_count("") == 0
      assert LawDocument.n3_rule_count("@prefix ex: <http://example.org/> .") == 0
    end

    test "a commented-out rule is not a rule" do
      assert LawDocument.n3_rule_count("# { ?s a ex:Forbidden } => false .") == 0
    end

    test "an implication arrow inside a string literal is not a rule" do
      assert LawDocument.n3_rule_count(~s(<a:s> <a:p> "a => b" .)) == 0
      assert LawDocument.n3_rule_count(~s(<a:s> <a:p> 'a => b' .)) == 0
      assert LawDocument.n3_rule_count(~s(<a:s> <a:p> """a => b""" .)) == 0
    end

    test "an implication arrow inside an IRI is not a rule" do
      assert LawDocument.n3_rule_count("<http://a/x=>y> <a:p> <a:o> .") == 0
    end

    test "several real rules are all counted" do
      doc = """
      @prefix ex: <http://example.org/> .
      { ?s a ex:Forbidden } => false .
      { ?s a ex:AlsoForbidden } => false .
      """

      assert LawDocument.n3_rule_count(doc) == 2
    end
  end
end
