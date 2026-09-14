defmodule AshA2A.SemanticProjectionR2RMLRealTest do
  @moduledoc """
  Real Chicago-style coverage for GAP D (Squad F agent 29): proves the
  `AshR2RML.mapping_result/1` join inside `AshA2A.SemanticProjection.capability/2`
  actually returns a successful RDF mapping when the underlying Ash resource
  genuinely declares the real `AshR2RML.Resource` extension and subject map,
  instead of always hitting the `:REFUSED_MISSING_SUBJECT_MAP` refusal path
  every pre-existing fixture in this repo takes.

  All collaborators here are real: `AshA2A.Test.Fixture.R2RMLEcho`
  (`test/support/r2rml_fixture.ex`) is a genuine compiled `Ash.Resource` with
  a real `AshR2RML.Resource` Spark extension and `r2rml do ... end` section;
  `AshR2RML.Resource.Info.mapping_result/1`, `AshR2RML.render/1`, and
  `AshA2A.SemanticProjection.capability/2` are the actual production
  functions under test, not stubs -- no test-double/interaction-verification
  library of any kind is used anywhere in this file.
  """

  use ExUnit.Case, async: true

  alias AshA2A.SemanticProjection
  alias AshA2A.Test.Fixture.R2RMLEcho
  alias AshR2RML.Mapping.{ObjectMap, PredicateObjectMap, Resource, SubjectMap}

  describe "AshR2RML.Resource.Info.mapping_result/1 against a genuinely mapped fixture" do
    test "returns a real successful mapping, not the missing-subject-map refusal" do
      assert {:ok, %Resource{} = mapping} = AshR2RML.Resource.Info.mapping_result(R2RMLEcho)

      assert mapping.ash_resource == R2RMLEcho
      assert mapping.class_iris == ["https://schema.org/Message"]

      assert %SubjectMap{
               strategy: :template,
               value: "https://ash-a2a.example/r2rml/echo/{id}",
               term_type: :iri
             } = mapping.subject_map

      assert [
               %PredicateObjectMap{
                 attribute: :message,
                 predicate_iri: "https://schema.org/text",
                 object_map: %ObjectMap{
                   strategy: :column,
                   value: "message",
                   term_type: :literal,
                   datatype: %{rdf_datatype: "http://www.w3.org/2001/XMLSchema#string"}
                 }
               }
             ] = mapping.predicate_object_maps

      assert mapping.identities == [[:id]]
    end

    test "the previously-refusing fixture (Echo) still genuinely refuses, proving the contrast is real" do
      assert {:error, %AshR2RML.Refusal{code: :REFUSED_MISSING_SUBJECT_MAP}} =
               AshR2RML.Resource.Info.mapping_result(AshA2A.Test.Fixture.Echo)
    end

    test "AshR2RML.render/1 serializes real R2RML Turtle containing the mapped subject/class/predicate" do
      assert {:ok, turtle} = AshR2RML.render([R2RMLEcho])

      assert turtle =~ "rr:template \"https://ash-a2a.example/r2rml/echo/{id}\""
      assert turtle =~ "rr:class <https://schema.org/Message>"
      assert turtle =~ "rr:predicate <https://schema.org/text>"
      assert turtle =~ "rr:column \"message\""
      assert turtle =~ "rr:datatype <http://www.w3.org/2001/XMLSchema#string>"
    end
  end

  describe "AshA2A.SemanticProjection.capability/2 against a genuinely mapped fixture" do
    test "joins the real Ash capability to a real successful ash_r2rml mapping result" do
      assert {:ok, projection} =
               SemanticProjection.capability(R2RMLEcho, "AshA2A.Test.Fixture.R2RMLEcho.read")

      assert projection.resource == inspect(R2RMLEcho)
      assert projection.action == :read

      # The prior line's successful `{:ok, %Resource{...}}` match already proves
      # this is not the `{:error, %AshR2RML.Refusal{}}` refusal path every other
      # fixture in this repo takes -- see the contrast test above.
      assert {:ok, %Resource{class_iris: ["https://schema.org/Message"]} = mapping} =
               projection.r2rml_mapping_result

      [property] = mapping.predicate_object_maps
      assert property.predicate_iri == "https://schema.org/text"
    end
  end
end
