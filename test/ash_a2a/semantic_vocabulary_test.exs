defmodule AshA2A.Semantic.VocabularyTest do
  use ExUnit.Case, async: true

  alias AshA2A.Semantic.Vocabulary

  describe "prefixes/0" do
    test "returns exactly the ten known prefix keys" do
      prefixes = Vocabulary.prefixes()

      assert MapSet.new(Map.keys(prefixes)) ==
               MapSet.new(~w(rdf rdfs owl prov time odrl skos schema oa sosa))
    end

    test "known prefixes resolve to their expected URIs" do
      prefixes = Vocabulary.prefixes()

      assert prefixes["rdf"] == "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
      assert prefixes["schema"] == "https://schema.org/"
    end
  end

  describe "expand/1" do
    test "expands a known prefix:local pair by concatenation" do
      assert Vocabulary.expand("rdf:type") ==
               "http://www.w3.org/1999/02/22-rdf-syntax-ns#type"
    end

    test "falls back to local/1 with the full original value when the prefix is unknown" do
      assert Vocabulary.expand("unknownprefix:foo") ==
               "urn:ash-a2a:semantic:unknownprefix_foo"
    end

    test "falls back to local/1 unchanged when there is no colon at all" do
      assert Vocabulary.expand("noColonAtAll") == "urn:ash-a2a:semantic:noColonAtAll"
    end
  end

  describe "local/1" do
    test "collapses each run of non alnum/./_/- characters into a single underscore" do
      assert Vocabulary.local("has space:and/slash") ==
               "urn:ash-a2a:semantic:has_space_and_slash"
    end

    test "leaves already-safe characters untouched" do
      assert Vocabulary.local("already-safe.value_123") ==
               "urn:ash-a2a:semantic:already-safe.value_123"
    end
  end
end
