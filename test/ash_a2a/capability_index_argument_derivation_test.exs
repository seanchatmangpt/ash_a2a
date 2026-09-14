defmodule AshA2A.CapabilityIndexArgumentDerivationTest do
  @moduledoc """
  Exercises `AshA2A.CapabilityIndex.Compiler`'s real derivation of
  `%AshA2A.Skill{}.arguments` from canonical Ash introspection
  (`derive_arguments/2`, private, exercised only through the public
  `AshA2A.Info.capability_index/1` / `AshA2A.Info.skill/2` entry points) --
  previously this field was hardcoded to `[]` regardless of what the real
  action declared (`AshA2A.Skill`'s own moduledoc promised introspection-
  derived arguments; `compiler.ex` did not yet deliver it).

  Chicago-style: no Mock/mox/patch/monkeypatch anywhere in this file. Every
  assertion is against the real `%AshA2A.Skill{}.arguments` list returned by
  compiling a real, compiled `Ash.Resource` fixture through the real
  extension pipeline -- state-based assertions on real data, not
  interaction checks.

  Two real Ash introspection surfaces are covered, per the two fixtures
  already available in `test/support/fixture.ex`:

    * `AshA2A.Test.Fixture.TypedArguments`'s `:search` generic action --
      real action-declared `argument ...` entries
      (`Ash.Resource.Actions.Argument.t()`).
    * `AshA2A.Test.Fixture.Item`'s `:create`/`:update` actions -- real
      `accept:` attribute lists, represented as arguments per the documented
      design decision in `AshA2A.CapabilityIndex.Compiler.derive_arguments/2`.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Test.Fixture.Item
  alias AshA2A.Test.Fixture.TypedArguments

  describe "action-declared arguments (Ash.Resource.Actions.Argument)" do
    test "a real generic action's declared arguments are derived with real names and types" do
      {:ok, skill} = AshA2A.Info.skill(TypedArguments, :search)

      # Ground truth for both the expected names/types AND their order comes
      # from the same real `Ash.Resource.Info.action/2` introspection path
      # `derive_arguments/2` itself uses -- not a hardcoded guess at either
      # how Ash represents a `:string`/`:integer` short type name internally,
      # or what order Spark's compiled entity list carries the two real
      # `argument ...` declarations in.
      real_action = Ash.Resource.Info.action(TypedArguments, :search)

      expected_arguments =
        real_action.arguments
        |> Enum.filter(&Map.get(&1, :public?, true))
        |> Enum.map(&%AshA2A.Argument{name: &1.name, type: &1.type})

      assert Enum.map(expected_arguments, & &1.name) |> Enum.sort() == [:limit, :query]
      assert skill.arguments == expected_arguments
    end

    test "declared argument types are the real Ash.Type modules, not raw short names" do
      {:ok, skill} = AshA2A.Info.skill(TypedArguments, :search)

      query_argument = Enum.find(skill.arguments, &(&1.name == :query))
      limit_argument = Enum.find(skill.arguments, &(&1.name == :limit))

      assert query_argument.type == Ash.Type.String
      assert limit_argument.type == Ash.Type.Integer
    end

    test "the :read default action on the same resource has no declared arguments" do
      {:ok, skill} = AshA2A.Info.skill(TypedArguments, :read)

      assert skill.arguments == []
    end
  end

  describe "accept-derived arguments (:create/:update action.accept)" do
    test "a real create action's accepted attributes are represented as real typed arguments" do
      {:ok, skill} = AshA2A.Info.skill(Item, :create_item)

      real_attribute = Ash.Resource.Info.attribute(Item, :label)

      assert skill.arguments == [
               %AshA2A.Argument{name: :label, type: real_attribute.type}
             ]

      assert real_attribute.type == Ash.Type.String
    end

    test "a real update action's accepted attributes are represented as real typed arguments" do
      {:ok, skill} = AshA2A.Info.skill(Item, :update_item)

      real_attribute = Ash.Resource.Info.attribute(Item, :label)

      assert skill.arguments == [
               %AshA2A.Argument{name: :label, type: real_attribute.type}
             ]
    end

    test "a real destroy action (no accept, no declared arguments) derives an empty list" do
      {:ok, skill} = AshA2A.Info.skill(Item, :destroy_item)

      assert skill.arguments == []
    end

    test "a real generic action with no declared arguments and no accept derives an empty list" do
      {:ok, skill} = AshA2A.Info.skill(Item, :ping)

      assert skill.arguments == []
    end
  end
end
