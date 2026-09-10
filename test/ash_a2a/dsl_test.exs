defmodule AshA2A.DslTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Direct coverage of `AshA2A.Dsl.sections/0` -- the raw Spark schema/section
  definition. Existing tests (`test/ash_a2a_test.exs` and friends) only
  exercise the DSL indirectly, through resources/domains that `use AshA2A`
  and declare `a2a do skill ... end` blocks; none of them call
  `AshA2A.Dsl.sections/0` itself or assert on its real, compiled
  `Spark.Dsl.Section`/`Spark.Dsl.Entity` shape.
  """

  test "sections/0 returns the real :a2a section with a :skill entity taking name/resource/action args" do
    assert [%Spark.Dsl.Section{} = section] = AshA2A.Dsl.sections()
    assert section.name == :a2a
    assert [%Spark.Dsl.Entity{} = skill_entity] = section.entities
    assert skill_entity.name == :skill
    assert skill_entity.target == AshA2A.Skill
    assert skill_entity.args == [:name, {:optional, :resource}, :action]
    assert skill_entity.identifier == :name

    schema_keys = Keyword.keys(skill_entity.schema)
    assert :name in schema_keys
    assert :resource in schema_keys
    assert :action in schema_keys
  end
end
