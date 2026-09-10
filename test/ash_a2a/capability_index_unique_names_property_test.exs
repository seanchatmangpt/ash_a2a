defmodule AshA2A.CapabilityIndexUniqueNamesPropertyTest do
  @moduledoc """
  Property-based test for `AshA2A.CapabilityIndex.validate_unique_names/1`
  (task #16).

  `validate_unique_names/1` is `defp` (private), so it cannot be called
  directly from a test module -- Elixir does not export private functions
  via `apply/3` or any other mechanism. It is exercised here through the
  real public `AshA2A.CapabilityIndex.validate/1`, which is defined as
  `validate_unique_names(skills) ++ validate_actions_exist(skills)`
  (`lib/ash_a2a/capability_index.ex`). To isolate the uniqueness check from
  the action-existence check, every generated skill names the same real,
  compiled `{resource, action}` pair -- `{AshA2A.Test.Fixture.Echo, :read}`,
  a genuine `Ash.Resource` action from `test/support/fixture.ex` (already
  exercised in `test/ash_a2a_test.exs`) -- so `validate_actions_exist/1`
  never contributes a refusal and every observed `:REFUSED_DUPLICATE_SKILL_NAME`
  in the result comes from `validate_unique_names/1` alone.

  Chicago-style: no Mock/mox/patch. `Ash.Resource.Info.action/2` is called
  for real (inside `validate/1`) against the real compiled `Echo` fixture;
  assertions are on the real return value of `validate/1`, not on
  interactions.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias AshA2A.CapabilityIndex
  alias AshA2A.Test.Fixture.Echo

  # Small, fixed name pool so StreamData reliably generates both
  # "all-unique" and "has a real duplicate" cases across property runs.
  @name_pool [:alpha, :bravo, :charlie, :delta, :echo]

  defp skill(name), do: %{name: name, resource: Echo, action: :read}

  property "validate/1 fail-closes with :REFUSED_DUPLICATE_SKILL_NAME exactly when a real duplicate name exists" do
    check all(
            names <-
              StreamData.list_of(StreamData.member_of(@name_pool), min_length: 1, max_length: 12),
            max_runs: 200
          ) do
      skills = Enum.map(names, &skill/1)

      duplicated_names =
        names
        |> Enum.frequencies()
        |> Enum.filter(fn {_name, count} -> count > 1 end)
        |> Enum.map(&elem(&1, 0))
        |> MapSet.new()

      result = CapabilityIndex.validate(skills)

      if MapSet.size(duplicated_names) > 0 do
        assert {:error, refusals} = result

        duplicate_refusals =
          Enum.filter(refusals, &(&1.code == :REFUSED_DUPLICATE_SKILL_NAME))

        # Exactly one refusal per distinct duplicated name -- no more, no
        # fewer -- and no other refusal code leaked in (every skill names
        # the same real action, so validate_actions_exist/1 contributes
        # nothing here).
        assert length(duplicate_refusals) == MapSet.size(duplicated_names)
        assert length(refusals) == length(duplicate_refusals)

        reported_names =
          duplicate_refusals
          |> Enum.map(fn %{detail: detail} ->
            Enum.find(@name_pool, fn name -> detail =~ inspect(name) end)
          end)
          |> MapSet.new()

        assert reported_names == duplicated_names
      else
        assert result == :ok
      end
    end
  end

  property "validate/1 never fails closed on a name-collision-free skill list" do
    check all(
            shuffled_pool <- StreamData.constant(@name_pool) |> StreamData.map(&Enum.shuffle/1),
            take_count <- StreamData.integer(0..length(@name_pool)),
            max_runs: 100
          ) do
      names = Enum.take(shuffled_pool, take_count)
      skills = Enum.map(names, &skill/1)
      assert CapabilityIndex.validate(skills) == :ok
    end
  end
end
