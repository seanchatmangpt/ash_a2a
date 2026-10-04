# SPDX-FileCopyrightText: 2026 ash_a2a contributors
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Semantic.Engine.AshGraphLawTest do
  use ExUnit.Case, async: false

  alias AshA2A.Semantic.Conformance
  alias AshA2A.Semantic.Engine.AshGraphLaw, as: Engine

  describe "AshA2A.Semantic.Engine.AshGraphLaw conformance surface" do
    test "exports all five RFC engine capability functions" do
      assert function_exported?(Engine, :validate_shex, 3)
      assert function_exported?(Engine, :validate_shacl, 2)
      assert function_exported?(Engine, :query_sparql, 2)
      assert function_exported?(Engine, :datalog_closure, 2)
      assert function_exported?(Engine, :n3_closure, 2)
    end

    test "AshA2A.Semantic.Conformance.engine_capability/2 returns :met for all capabilities" do
      assert Conformance.engine_capability(:validate_shex, 3) == :met
      assert Conformance.engine_capability(:validate_shacl, 2) == :met
      assert Conformance.engine_capability(:query_sparql, 2) == :met
      assert Conformance.engine_capability(:datalog_closure, 2) == :met
      assert Conformance.engine_capability(:n3_closure, 2) == :met
    end

    test "available?/0 returns true when AshGraphLaw is live" do
      assert Engine.available?() == true
    end

    test "version/0 returns release string" do
      assert {:ok, version} = Engine.version()
      assert byte_size(version) > 0
    end

    test "validate_shacl/2 executes against real engine" do
      data = """
      @prefix ex: <http://example.org/> .
      @prefix foaf: <http://xmlns.com/foaf/0.1/> .
      ex:alice a foaf:Person ;
               foaf:name "Alice" .
      """

      shapes = """
      @prefix sh: <http://www.w3.org/ns/shacl#> .
      @prefix foaf: <http://xmlns.com/foaf/0.1/> .
      @prefix ex: <http://example.org/> .

      ex:PersonShape a sh:NodeShape ;
          sh:targetClass foaf:Person ;
          sh:property [
              sh:path foaf:name ;
              sh:minCount 1 ;
          ] .
      """

      assert {:ok, res} = Engine.validate_shacl(data, shapes)
      assert res.conforms == true
    end

    test "query_sparql/2 executes against real engine" do
      data = """
      @prefix ex: <http://example.org/> .
      ex:bob ex:greeting "hello" .
      """

      query = """
      SELECT ?greeting WHERE {
        ?s <http://example.org/greeting> ?greeting .
      }
      """

      assert {:ok, %AshGraphLaw.Result.Sparql{} = res} = Engine.query_sparql(data, query)
      assert is_list(res.rows)
      assert length(res.rows) == 1
    end
  end
end
