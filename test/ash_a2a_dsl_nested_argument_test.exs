# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.DslNestedArgumentTest do
  use ExUnit.Case, async: true

  import Spark.Test

  @moduledoc """
  ERRC Create finding: the `:skill` `Spark.Dsl.Entity` had no `entities:`
  key, so no nested `do...end` block was structurally possible at all
  (`Spark.Dsl.Entity` requires `entities:` on the parent before it accepts a
  child entity block). `lib/ash_a2a/dsl.ex`'s `:skill` entity now declares
  `entities: [arguments: [@argument]]`, backed by a real `AshA2A.Argument`
  entity target (`lib/ash_a2a/argument.ex`).

  This test compiles a real fixture resource
  (`AshA2A.Test.NestedArg.EchoWithArgument`) that actually writes
  `skill :echo, :read do argument :query, :string end` and asserts on the
  real compiled DSL entity state via `Spark.Dsl.Extension.get_entities/2` --
  no mocked parser, no hand-built struct standing in for compilation.
  """

  # The fixture is compiled inside the test (not in test/support) because
  # `AshA2A.Verify` warns on a dead nested argument, and a
  # support-compiled fixture would fail `mix compile --warnings-as-errors`.
  # `assert_dsl_warning` collects that real warning, so the same compile also
  # proves the verifier fires.
  test "a skill entity accepts a nested argument block and compiles it for real" do
    {message, _location} =
      assert_dsl_warning {_, _} do
        defmodule Elixir.AshA2A.Test.NestedArg.EchoWithArgumentDomain do
          @moduledoc false
          use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

          resources do
            resource(Elixir.AshA2A.Test.NestedArg.EchoWithArgument)
          end
        end

        defmodule Elixir.AshA2A.Test.NestedArg.EchoWithArgument do
          @moduledoc false
          use Ash.Resource,
            domain: Elixir.AshA2A.Test.NestedArg.EchoWithArgumentDomain,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshA2A]

          attributes do
            uuid_primary_key(:id)
            attribute(:message, :string, public?: true)
          end

          actions do
            defaults([:read])
          end

          a2a do
            skill :echo, :read do
              argument(:query, :string)
            end
          end
        end
      end

    assert message =~ ":echo"

    [skill] = Spark.Dsl.Extension.get_entities(AshA2A.Test.NestedArg.EchoWithArgument, [:a2a])

    assert %AshA2A.Skill{name: :echo, action: :read, arguments: [argument]} = skill
    assert %AshA2A.Argument{name: :query, type: :string} = argument
  end

  test "a skill entity with no nested block still compiles with an empty arguments list" do
    [skill] = Spark.Dsl.Extension.get_entities(AshA2A.Test.Fixture.Echo, [:a2a])

    assert %AshA2A.Skill{name: :echo, action: :read, arguments: []} = skill
  end
end
