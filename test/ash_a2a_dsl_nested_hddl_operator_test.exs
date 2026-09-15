defmodule AshA2A.DslNestedHddlOperatorTest do
  use ExUnit.Case, async: true

  @moduledoc """
  HDDL deterministic-planning-path Task 1: the `:skill` entity now also
  declares `entities: [arguments: [@argument], hddl_operators:
  [@hddl_operator]]` (`lib/ash_a2a/dsl.ex`), backed by a real
  `AshA2A.HddlOperator` entity target (`lib/ash_a2a/hddl_operator.ex`).

  Unlike the pre-existing `argument` nested entity -- accepted but
  deliberately dead at capability-compilation time
  (`AshA2A.Verify.dead_argument_warning/1`) -- `hddl_operator` is a *live*
  override field: `AshA2A.CapabilityIndex.Compiler.project/3` copies it
  through into the real compiled `AshA2A.Skill.hddl_operators`, because HDDL
  operator metadata has no equivalent to derive from Ash introspection
  instead. This test compiles a real fixture resource
  (`AshA2A.Test.Fixture.EchoWithHddlOperator`) that actually writes a
  `hddl_operator do ... end` block and asserts both on the raw compiled DSL
  entity state (`Spark.Dsl.Extension.get_entities/2`) and on the real
  compiled capability index (`AshA2A.Info.capability_index/1`) -- no mocked
  parser, no hand-built struct standing in for compilation.
  """

  test "a skill entity accepts a nested hddl_operator block and compiles it for real" do
    [skill] =
      Spark.Dsl.Extension.get_entities(AshA2A.Test.Fixture.EchoWithHddlOperator, [:a2a])

    assert %AshA2A.Skill{name: :advance, action: :read, hddl_operators: [operator]} = skill

    assert %AshA2A.HddlOperator{
             parameters: [:from, :to],
             preconditions: [{:current_phase, [:from]}],
             add_effects: [{:current_phase, [:to]}],
             delete_effects: [{:current_phase, [:from]}]
           } = operator
  end

  test "the declared hddl_operator is a live field: it round-trips into the real compiled capability index" do
    {:ok, skill} = AshA2A.Info.skill(AshA2A.Test.Fixture.EchoWithHddlOperator, :advance)

    assert %AshA2A.Skill{hddl_operators: [operator]} = skill

    assert %AshA2A.HddlOperator{
             parameters: [:from, :to],
             preconditions: [{:current_phase, [:from]}],
             add_effects: [{:current_phase, [:to]}],
             delete_effects: [{:current_phase, [:from]}]
           } = operator
  end

  test "a skill with no nested hddl_operator block still compiles with an empty hddl_operators list, in both the DSL entity and the compiled index" do
    [skill] = Spark.Dsl.Extension.get_entities(AshA2A.Test.Fixture.Echo, [:a2a])
    assert %AshA2A.Skill{name: :echo, action: :read, hddl_operators: []} = skill

    {:ok, compiled} = AshA2A.Info.skill(AshA2A.Test.Fixture.Echo, :echo)
    assert %AshA2A.Skill{hddl_operators: []} = compiled
  end
end
