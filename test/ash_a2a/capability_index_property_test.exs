defmodule AshA2A.CapabilityIndexPropertyTest do
  @moduledoc """
  Property-based test for `AshA2A.CapabilityIndex.validate/1`'s
  `validate_actions_exist/1` check (private, exercised only through the
  public `validate/1` entry point).

  Generates skill lists mixing real actions on the real
  `AshA2A.Test.Fixture.Echo` resource (compiled in `test/support/fixture.ex`,
  `elixirc_paths(:test)` includes `test/support` per `mix.exs`) with
  fabricated action names that provably do not exist on that resource
  (confirmed via the real `Ash.Resource.Info.action/2` introspection,
  `~/xaas/deps/ash/lib/ash/resource/info.ex:716`), and asserts
  `AshA2A.CapabilityIndex.validate/1` flags exactly the fabricated ones with
  `:REFUSED_ACTION_NOT_FOUND` -- no more, no fewer.

  Chicago-style: no mocks/stubs. The resource is a real, compiled
  `Ash.Resource` and `Ash.Resource.Info.action/2` is called for real by both
  the property (to pick real action names) and the code under test.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias AshA2A.CapabilityIndex
  alias AshA2A.Test.Fixture.Echo

  # The real action names actually compiled onto the fixture resource --
  # ground truth read via the same `Ash.Resource.Info.action/2` path the
  # validator itself uses, not hardcoded from reading the DSL body.
  @real_action_names Echo
                     |> Ash.Resource.Info.actions()
                     |> Enum.map(& &1.name)

  # A fabricated action name is only usable in this test if it provably does
  # NOT collide with a real action on `Echo` -- checked live via
  # `Ash.Resource.Info.action/2`, never assumed from the atom's spelling.
  defp fabricated_action_name_generator do
    StreamData.atom(:alphanumeric)
    |> StreamData.filter(fn name ->
      is_nil(Ash.Resource.Info.action(Echo, name))
    end)
  end

  defp real_action_name_generator do
    StreamData.member_of(@real_action_names)
  end

  # Each skill's action is independently drawn as either a real action name
  # or a provably-fabricated one. Skill names are disjoint across the list
  # (paired with the list index), so `validate_unique_names/1`'s check never
  # fires and only `validate_actions_exist/1` is under test.
  defp skill_spec_generator do
    StreamData.one_of([real_action_name_generator(), fabricated_action_name_generator()])
  end

  property "flags exactly the skills naming fabricated actions, never the real ones" do
    check all(specs <- StreamData.list_of(skill_spec_generator(), min_length: 1, max_length: 12)) do
      skills =
        specs
        |> Enum.with_index()
        |> Enum.map(fn {action, index} ->
          # Ground truth on whether this draw is real is always
          # `Ash.Resource.Info.action/2` membership, never generator intent.
          real? = action in @real_action_names

          %{
            name: :"skill_#{index}",
            resource: Echo,
            domain: nil,
            action: action,
            arguments: []
          }
          |> Map.put(:__fixture_real?, real?)
        end)

      expected_fabricated_names =
        skills
        |> Enum.reject(& &1.__fixture_real?)
        |> Enum.map(& &1.name)
        |> MapSet.new()

      validation_skills = Enum.map(skills, &Map.delete(&1, :__fixture_real?))

      result = CapabilityIndex.validate(validation_skills)

      case {expected_fabricated_names, result} do
        {fabricated, :ok} ->
          assert MapSet.size(fabricated) == 0,
                 "expected :ok only when no skill names a fabricated action, " <>
                   "but #{inspect(MapSet.to_list(fabricated))} were fabricated"

        {fabricated, {:error, refusals}} ->
          assert MapSet.size(fabricated) > 0,
                 "validate/1 returned refusals #{inspect(refusals)} but every " <>
                   "skill named a real action"

          # Extract the exact flagged skill name from
          # `validate_actions_exist/1`'s detail string
          # ("skill #{inspect(name)} names action ..."), anchored on the
          # literal "skill " prefix and " names action" suffix so e.g.
          # `:skill_1` can never spuriously match inside `:skill_10`'s
          # detail (a plain substring check would).
          flagged_names =
            refusals
            |> Enum.filter(&(&1.code == :REFUSED_ACTION_NOT_FOUND))
            |> Enum.map(fn refusal ->
              [_, name_str] = Regex.run(~r/^skill :(\S+) names action/, refusal.detail)
              String.to_existing_atom(name_str)
            end)
            |> MapSet.new()

          assert flagged_names == fabricated,
                 "expected exactly #{inspect(MapSet.to_list(fabricated))} flagged as " <>
                   "REFUSED_ACTION_NOT_FOUND, got #{inspect(MapSet.to_list(flagged_names))}"

          assert length(refusals) == MapSet.size(fabricated),
                 "expected exactly one refusal per fabricated skill, got #{length(refusals)} " <>
                   "refusals for #{MapSet.size(fabricated)} fabricated skills"
      end
    end
  end
end
