defmodule AshA2A.DslNestedArgumentTest do
  use ExUnit.Case, async: true

  @moduledoc """
  ERRC Create finding: the `:skill` `Spark.Dsl.Entity` had no `entities:`
  key, so no nested `do...end` block was structurally possible at all
  (`Spark.Dsl.Entity` requires `entities:` on the parent before it accepts a
  child entity block). `lib/ash_a2a/dsl.ex`'s `:skill` entity now declares
  `entities: [arguments: [@argument]]`, backed by a real `AshA2A.Argument`
  entity target (`lib/ash_a2a/argument.ex`).

  This test compiles a real fixture resource
  (`AshA2A.Test.Fixture.EchoWithArgument`) that actually writes
  `skill :echo, :read do argument :query, :string end` and asserts on the
  real compiled DSL entity state via `Spark.Dsl.Extension.get_entities/2` --
  no mocked parser, no hand-built struct standing in for compilation.
  """

  test "a skill entity accepts a nested argument block and compiles it for real" do
    [skill] = Spark.Dsl.Extension.get_entities(AshA2A.Test.Fixture.EchoWithArgument, [:a2a])

    assert %AshA2A.Skill{name: :echo, action: :read, arguments: [argument]} = skill
    assert %AshA2A.Argument{name: :query, type: :string} = argument
  end

  test "a skill entity with no nested block still compiles with an empty arguments list" do
    [skill] = Spark.Dsl.Extension.get_entities(AshA2A.Test.Fixture.Echo, [:a2a])

    assert %AshA2A.Skill{name: :echo, action: :read, arguments: []} = skill
  end
end
