defmodule AshA2A.Test.SA2AAdmissionFixtures do
  @moduledoc """
  Real RDF/SHACL/ShExJ/N3/OWL fixtures for the RFC S13 admission pipeline tests.

  Every fixture here is real input for the real `praxis-graphlaw` engine -- real
  Turtle, a real SHACL shapes graph, a real ShExJ schema, a real N3 denial rule
  set, a real OWL profile. Nothing in this module fakes an engine verdict; the
  verdicts come from actually running the wasm.

  Shape of the law, chosen so each stage can be isolated by a real graph:

    * **ShEx** requires only `schema:description` on the focus node.
    * **SHACL** requires `schema:description` *and* `ex:owner` on every
      `ex:Goal`, so a graph carrying a description but no owner passes ShEx and
      fails SHACL -- letting the SHACL negative be distinguished from the ShEx
      negative by a real graph rather than by configuration.
    * **Falsifiers** deny any `ex:Forbidden`, so the falsifier negative is a
      real N3 denial firing on a real triple.
  """

  alias AshA2A.Semantic.{IR, Source}
  alias AshA2A.Semantic.AdmissionPipeline.Candidate

  @conforming """
  @prefix ex: <http://example.org/> .
  @prefix schema: <http://schema.org/> .
  ex:a a ex:Goal ;
    schema:description "ship the admission pipeline" ;
    ex:owner ex:sean .
  """

  @missing_description """
  @prefix ex: <http://example.org/> .
  @prefix schema: <http://schema.org/> .
  ex:a a ex:Goal ;
    ex:owner ex:sean .
  """

  @missing_owner """
  @prefix ex: <http://example.org/> .
  @prefix schema: <http://schema.org/> .
  ex:a a ex:Goal ;
    schema:description "ship the admission pipeline" .
  """

  @forbidden """
  @prefix ex: <http://example.org/> .
  @prefix schema: <http://schema.org/> .
  ex:a a ex:Goal ;
    schema:description "ship the admission pipeline" ;
    ex:owner ex:sean .
  ex:b a ex:Forbidden .
  """

  @not_turtle "this is not turtle at all <<< @@@ ;;;"

  @shacl_shapes """
  @prefix sh: <http://www.w3.org/ns/shacl#> .
  @prefix ex: <http://example.org/> .
  @prefix schema: <http://schema.org/> .
  ex:GoalShape a sh:NodeShape ;
    sh:targetClass ex:Goal ;
    sh:property [ sh:path schema:description ; sh:minCount 1 ] ;
    sh:property [ sh:path ex:owner ; sh:minCount 1 ] .
  """

  # Real ShExJ (the engine's ShEx entry point takes the JSON serialisation, not
  # ShExC -- confirmed by running both against the real wasm).
  @shex_schema ~s({"shapes":[{"id":"http://example.org/GoalShEx","shapeExpr":{"type":"Shape","closed":false,"extra":[],"expression":{"type":"TripleConstraint","predicate":"http://schema.org/description","valueExpr":{"type":"NodeConstraint","datatype":"http://www.w3.org/2001/XMLSchema#string"},"min":1,"max":1}}}]})

  # Real shape map: a JSON array of two-element [focus_node, shape_label] arrays.
  @shex_shape_map ~s([["http://example.org/a","http://example.org/GoalShEx"]])

  @profile """
  @prefix owl: <http://www.w3.org/2002/07/owl#> .
  @prefix ex: <http://example.org/> .
  ex:Goal a owl:Class .
  """

  @falsifiers """
  @prefix ex: <http://example.org/> .
  { ?s a ex:Forbidden } => false .
  """

  @source_text """
  The team agreed to ship the admission pipeline this week, with sean as owner.
  """

  def conforming_graph, do: @conforming
  def graph_missing_description, do: @missing_description
  def graph_missing_owner, do: @missing_owner
  def graph_with_forbidden, do: @forbidden
  def not_turtle, do: @not_turtle
  def shacl_shapes, do: @shacl_shapes
  def shex_schema, do: @shex_schema
  def shex_shape_map, do: @shex_shape_map
  def profile, do: @profile
  def falsifiers, do: @falsifiers
  def source_text, do: @source_text

  @doc "A real `AshA2A.Semantic.Source` whose text really contains the quotes below."
  @spec source() :: Source.t()
  def source, do: Source.new(@source_text, id: "sa2a-admission-fixture-source")

  @doc """
  A real grounded `{Source, IR}` provenance witness: every `source_quote` below
  appears verbatim in `source_text/0`, so the real
  `AshA2A.Semantic.Admission.admit/2` grounding check passes.
  """
  @spec grounded_provenance() :: {Source.t(), IR.t()}
  def grounded_provenance do
    src = source()
    {:ok, ir} = IR.from_map(src.id, grounded_ir_map())
    {src, ir}
  end

  @doc """
  A real `{Source, IR}` witness whose goal quotes text that is **not** in the
  source, so the real grounding check in `AshA2A.Semantic.Admission` refuses it.
  """
  @spec ungrounded_provenance() :: {Source.t(), IR.t()}
  def ungrounded_provenance do
    src = source()

    {:ok, ir} =
      IR.from_map(src.id, %{
        "authority" => "none",
        "goals" => [
          %{
            "id" => "goal-1",
            "kind" => "goal",
            "description" => "delete the production database",
            "source_quote" => "delete the production database"
          }
        ]
      })

    {src, ir}
  end

  defp grounded_ir_map do
    %{
      "authority" => "none",
      "goals" => [
        %{
          "id" => "goal-1",
          "kind" => "goal",
          "description" => "ship the admission pipeline",
          "source_quote" => "ship the admission pipeline"
        }
      ]
    }
  end

  @doc """
  A fully-lawful candidate over the conforming graph. `overrides` replaces any
  field, so a negative case differs from the positive case by exactly the one
  thing under test.
  """
  @spec candidate(keyword()) :: Candidate.t()
  def candidate(overrides \\ []) do
    base = %Candidate{
      graph_ttl: @conforming,
      profile_ttl: @profile,
      shacl_shapes: @shacl_shapes,
      shex_schema: @shex_schema,
      shex_shape_map: @shex_shape_map,
      falsifiers: @falsifiers,
      provenance: grounded_provenance()
    }

    struct!(base, overrides)
  end
end
