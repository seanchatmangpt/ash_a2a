defmodule AshA2ADispatcherSkillNameShapeTest do
  @moduledoc """
  Chicago-style regression coverage for the ERRC "Raise" finding:
  `AshA2A.Dispatcher.to_skill_name/1` had no catch-all clause, contradicting
  its own documented fail-closed contract. `skill_name` reaches
  `AshA2A.Dispatcher.dispatch/5` from `AshA2A.Agent.resolve_skill_name/2`,
  which pulls it out of an unauthenticated, unschema'd `A2A.Message.metadata`
  map with zero type checking -- so a remote caller can make `skill_name` any
  term at all (integer, list, map, ...), not just `atom()` or `String.t()`.

  Before the fix, `to_skill_name(123)` / `to_skill_name([1, 2])` /
  `to_skill_name(%{})` would raise `FunctionClauseError` instead of returning
  the documented `{:error, {:unknown_skill, skill_name}}`, crashing the
  calling `A2A.Agent` process.

  No Mock/mox/patch/monkeypatch: this dispatches a real `A2A.Message` through
  the real `AshA2A.Dispatcher.dispatch/5` against the real
  `AshA2A.Test.Fixture.Item` resource and asserts on the real returned reply
  tuple (state-based), not on any mocked interaction.
  """

  use ExUnit.Case

  alias AshA2A.Test.Fixture.Item

  for {label, bad_skill_name} <- [
        {"an integer", 123},
        {"a list", [1, 2]},
        {"a map", %{}},
        {"a tuple", {:foo, :bar}},
        {"a float", 1.5}
      ] do
    test "dispatch/5 fails closed (no raise) for a skill_name that is #{label}" do
      message = A2A.Message.new_user([A2A.Part.Data.new(%{"label" => "widget"})])
      bad_skill_name = unquote(Macro.escape(bad_skill_name))

      assert {:error, {:skill_lookup, {:unknown_skill, ^bad_skill_name}}} =
               AshA2A.Dispatcher.dispatch(bad_skill_name, message, Item)
    end
  end

  test "dispatch/5 still resolves a real atom skill_name to a normal reply" do
    message = A2A.Message.new_user([A2A.Part.Data.new(%{"label" => "widget"})])

    assert {:reply, [%A2A.Part.Data{data: %{label: "widget"}}]} =
             AshA2A.Dispatcher.dispatch(:create_item, message, Item)
  end

  test "dispatch/5 still resolves a real binary skill_name to a normal reply" do
    message = A2A.Message.new_user([A2A.Part.Data.new(%{"label" => "widget"})])

    assert {:reply, [%A2A.Part.Data{data: %{label: "widget"}}]} =
             AshA2A.Dispatcher.dispatch("create_item", message, Item)
  end
end
