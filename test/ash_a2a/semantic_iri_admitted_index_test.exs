defmodule AshA2A.SemanticIriAdmittedIndexTest do
  @moduledoc """
  Regression cover for `AshA2A.Semantic.Iri.classify/2` laundering an invented
  term into `:public` on the strength of its namespace prefix.

  The defect, as reproduced before the fix, against the real pinned ontology
  cache:

      TermRegistry.member?(index, "…skos/core#totallyInventedTermThatDoesNotExist")
        -> false
      Iri.classify("…skos/core#totallyInventedTermThatDoesNotExist", index)
        -> :public

  `classify/2` fell back to `TermRegistry.in_admitted_namespace?/2`, a bare
  `String.starts_with?/2` prefix test, so anyone who spelled a minted term
  under an admitted namespace got it classified public -- which is the S7.3
  mint-and-use evasion in one string operation.

  The index here is the real one, built from the real digest-pinned
  `priv/semantic/ontology_cache` documents through
  `TermRegistry.from_cache/1`. Nothing is stubbed.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Semantic.{Iri, TermRegistry}

  setup_all do
    assert {:ok, index} = TermRegistry.from_cache()
    %{index: index}
  end

  @real_term "http://www.w3.org/2004/02/skos/core#prefLabel"
  @invented_term "http://www.w3.org/2004/02/skos/core#totallyInventedTermThatDoesNotExist"

  describe "the verifier's minimal reproducing input" do
    test "the invented term really is absent from the real admitted index", %{index: index} do
      assert TermRegistry.member?(index, @real_term)
      refute TermRegistry.member?(index, @invented_term)
    end

    test "it sits under an admitted namespace, which is what fooled the old check", %{
      index: index
    } do
      assert TermRegistry.in_admitted_namespace?(index, @invented_term)
    end

    test "and it no longer classifies as :public", %{index: index} do
      assert Iri.classify(@invented_term, index) == :unknown
    end

    test "a real admitted term still classifies as :public", %{index: index} do
      assert Iri.classify(@real_term, index) == :public
    end
  end

  describe "the case is named rather than merely refused" do
    test "admitted_namespace_but_unknown_term?/2 identifies the mint-and-use shape", %{
      index: index
    } do
      assert Iri.admitted_namespace_but_unknown_term?(@invented_term, index)
      refute Iri.admitted_namespace_but_unknown_term?(@real_term, index)
      refute Iri.admitted_namespace_but_unknown_term?("http://elsewhere.example/x", index)
      refute Iri.admitted_namespace_but_unknown_term?(@invented_term, nil)
    end
  end

  describe "membership is the only route to :public, across every admitted namespace" do
    test "no minted sibling of a real term classifies public", %{index: index} do
      minted =
        index
        |> TermRegistry.iris()
        |> Enum.take(25)
        |> Enum.map(&(&1 <> "MintedByThisTestAndNotInAnyPinnedDocument"))

      assert minted != []

      for iri <- minted do
        assert TermRegistry.in_admitted_namespace?(index, iri)
        refute TermRegistry.member?(index, iri)

        assert Iri.classify(iri, index) == :unknown,
               "#{iri} classified #{inspect(Iri.classify(iri, index))}"
      end
    end

    test "every term really in the index does classify public", %{index: index} do
      iris = TermRegistry.iris(index)
      assert length(iris) > 0

      for iri <- iris do
        assert Iri.classify(iri, index) == :public, "#{iri} did not classify public"
      end
    end
  end

  describe "the rest of the classification is unchanged" do
    test "private namespaces are still private", %{index: index} do
      assert Iri.classify("urn:ash-a2a:semantic:node:e2", index) == :private
      assert Iri.classify("urn:example:thing", index) == :private
    end

    test "an unknown IRI with no index at all is :unknown, not :public" do
      assert Iri.classify(@real_term, nil) == :unknown
      assert Iri.classify("http://elsewhere.example/x", nil) == :unknown
    end
  end
end
