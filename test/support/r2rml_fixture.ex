defmodule AshA2A.Test.Fixture.R2RMLEcho do
  @moduledoc """
  Real fixture resource proving GAP D (Squad F agent 29): a genuine
  `Ash.Resource` that actually declares the real `AshR2RML.Resource` Spark
  extension with a real, minimal R2RML subject map -- not the empty-mapping
  refusal path every other fixture in this repo exercises.

  Before this fixture existed, `grep -rn "extensions:.*AshR2RML" test/ lib/`
  returned zero matches, and
  `AshR2RML.Resource.Info.mapping_result(AshA2A.Test.Fixture.Echo)` genuinely
  returned `{:error, %AshR2RML.Refusal{code: :REFUSED_MISSING_SUBJECT_MAP}}`
  because `Echo` declares no `r2rml do ... end` section at all.

  The DSL syntax below is copied from `deps/ash_r2rml`'s own shipped source
  (`deps/ash_r2rml/lib/ash_r2rml/resource.ex`'s `AshR2RML.Resource` Spark
  entities -- `class/1`, `subject do ... end`, `property/2`) and its own
  README "Ash-first quick start" / "Semantic identity" sections, not
  guessed. `AshR2RML.Resource.Verify` (a real `Spark.Dsl.Verifier`) runs
  `AshR2RML.Mapping.validate/1` at *compile time*, so this module only
  compiles at all because the subject map, class IRI, and property mapping
  below are genuinely admitted -- an invalid mapping would fail `mix
  compile` with a real `Spark.Error.DslError`, not merely fail a test
  assertion later.

  Predicates reuse `AshA2A.Semantic.Vocabulary`'s existing `schema` prefix
  (`https://schema.org/`) rather than inventing a new one, per this
  repository's prior-art-first convention: `schema:Message` for the RDF
  class (schema.org's real `Message` type) and `schema:text` for the one
  mapped literal attribute (schema.org's real `text` property).

  `Ash.DataLayer.Ets` (like every other fixture in this file) is not
  `AshPostgres.DataLayer`, so `AshR2RML.Introspection.logical_table/2`
  cannot infer a relational table name from the data layer -- an explicit
  `table_name` is therefore set in the `r2rml` section options (a real,
  supported escape hatch per `AshR2RML.Introspection.logical_table/2`'s own
  `{nil, nil} -> infer_logical_table(resource)` vs. explicit-`table_name`
  branches), exactly as the ash_r2rml dependency itself documents for a
  non-relational or read-only logical source.

  Combines `extensions: [AshA2A, AshR2RML.Resource]` on one resource (both
  are ordinary Spark extensions with distinct section names, `a2a` and
  `r2rml`; `AshR2RML.Resource`'s `single_extension_kinds: [:ash_r2rml]`
  guards only against mixing it with the legacy top-level `AshR2RML`
  extension, not against unrelated extensions) so
  `AshA2A.SemanticProjection.capability/2` -- the actual production bridge
  under test in `lib/ash_a2a/semantic_projection.ex` -- can be exercised
  end-to-end against a real mapped resource instead of only
  `AshR2RML.Resource.Info.mapping_result/1` in isolation.
  """

  use Ash.Resource,
    domain: AshA2A.Test.Fixture.R2RMLEchoDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A, AshR2RML.Resource]

  attributes do
    uuid_primary_key(:id)
    attribute(:message, :string, public?: true, allow_nil?: false)
  end

  actions do
    defaults([:read])
  end

  a2a do
    skill(:echo, :read)
  end

  r2rml do
    table_name("r2rml_echo_messages")

    class("https://schema.org/Message")

    subject do
      template("https://ash-a2a.example/r2rml/echo/{id}")
      term_type(:iri)
    end

    property(:message, "https://schema.org/text")
  end
end

defmodule AshA2A.Test.Fixture.R2RMLEchoDomain do
  @moduledoc """
  Real fixture domain for `AshA2A.Test.Fixture.R2RMLEcho` above, mirroring
  `AshA2A.Test.Fixture.Domain`'s shape (`extensions: [AshA2A]`, one resource)
  but kept separate so the real `AshR2RML.Resource`-mapped fixture is its own
  genuine Ash domain, independent of every other fixture domain in this
  directory.
  """

  use Ash.Domain, extensions: [AshA2A]

  resources do
    resource(AshA2A.Test.Fixture.R2RMLEcho)
  end
end
