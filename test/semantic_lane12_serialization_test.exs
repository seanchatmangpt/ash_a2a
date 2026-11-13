defmodule SemanticLane12SerializationTest do
  use ExUnit.Case, async: true

  alias AshA2A.Semantic.{AgentCard, Ontology, Serialize}

  @evil "http://example.org/x> <http://evil/p> \"pwn\" . <http://a"

  test "Serialize escapes injection characters in IRIs and control chars in literals" do
    assert Serialize.escape_iri(@evil) =~ "\\u003E"
    refute Serialize.escape_iri(@evil) =~ ">"
    assert Serialize.escape_literal("a\rb\u0001c\"d") == "a\\rb\\u0001c\\\"d"
  end

  test "Ontology.to_ntriples cannot be injected through subject IRI and re-parses as one triple" do
    out = Ontology.to_ntriples([%{subject: @evil, predicate: "http://example.org/p", object: "o\rx"}])
    assert length(String.split(out, "\n", trim: true)) == 1
    refute out =~ "> <http://evil/p>"
    assert out =~ "\\r"
  end

  test "AgentCard.to_turtle escapes literals and IRIs via the shared writer" do
    decl = %AgentCard{
      capability_iri: "urn:cap:x",
      input_shape: @evil,
      output_shape: "urn:shape:out",
      consequence_class: "c\rd\"e",
      authority_requirement: "none",
      receipt_class: "r",
      semantic_basis: "b",
      version: "1",
      cost_envelope: "e",
      preconditions: [],
      effects: [],
      planner_compatibility: []
    }

    ttl = AgentCard.to_turtle(decl)
    refute ttl =~ "<http://evil/p>"
    assert ttl =~ "\\r"
    assert ttl =~ "\\u003E"
  end

  test "FalsifierSuite.to_ntriples escapes IRIs" do
    out =
      AshA2A.Semantic.FalsifierSuite.to_ntriples([{@evil, "http://example.org/p", {:lit, "a\rb"}}])

    assert length(String.split(out, "\n", trim: true)) == 1
    refute out =~ "> <http://evil/p>"
    assert out =~ "\\r"
  end

  test "priv/sa2a/AllSA2A.ttl is byte-identical to canonical/AllSA2A.ttl (ggen.toml reads the former)" do
    assert File.read!("priv/sa2a/AllSA2A.ttl") == File.read!("priv/sa2a/canonical/AllSA2A.ttl")
  end
end
