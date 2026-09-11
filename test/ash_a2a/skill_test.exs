defmodule AshA2A.SkillTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Direct coverage of the `AshA2A.Skill` struct itself. Existing tests only
  ever inspect `AshA2A.Skill` entries as they come out of a compiled DSL
  extension (via `AshA2A.Info`/capability index tests); none constructs the
  struct directly and asserts on its own real default values.
  """

  test "struct defaults to nil for all fields, with __spark_metadata__ nil" do
    skill = %AshA2A.Skill{}

    assert skill.name == nil
    assert skill.resource == nil
    assert skill.domain == nil
    assert skill.action == nil
    assert skill.arguments == []
    assert skill.__spark_metadata__ == nil
  end

  test "struct holds real, independently-set field values" do
    skill = %AshA2A.Skill{
      name: :echo,
      resource: AshA2A.Test.Fixture.Echo,
      domain: AshA2A.Test.Fixture.Domain,
      action: :read
    }

    assert skill.name == :echo
    assert skill.resource == AshA2A.Test.Fixture.Echo
    assert skill.domain == AshA2A.Test.Fixture.Domain
    assert skill.action == :read
  end
end
