defmodule AshA2A.Dsl do
  @moduledoc """
  Spark DSL schema/section/entity definitions for the `AshA2A` extension.

  Per the ash_a2a PRD/ARD §3.1, dual Resource/Domain declaration shares one
  entity target (`AshA2A.Skill`) and one normalized IR: `skill :name, :action`
  (2-arg) on a resource, `skill :name, Resource, :action` (3-arg) on a domain
  -- the exact `args: [:name, {:optional, :resource}, :action]` shape
  `AshAi.Dsl.@tool` uses (`~/xaas/deps/ash_ai/lib/ash_ai/dsl.ex:264`).
  """

  @skill_schema [
    name: [
      type: :atom,
      required: true,
      doc: "The skill's name, advertised as the A2A `AgentCard` skill id."
    ],
    resource: [
      type: {:spark, Ash.Resource},
      required: false,
      doc:
        "The Ash resource the skill dispatches to. Required (3-arg) on a domain; implicit (2-arg) on a resource."
    ],
    action: [
      type: :atom,
      required: true,
      doc: "The name of the real Ash action this skill dispatches to."
    ]
  ]

  @skill %Spark.Dsl.Entity{
    name: :skill,
    describe: "Exposes a real Ash action as an A2A-discoverable agent skill.",
    examples: [
      "skill :echo, :read",
      "skill :echo, MyResource, :read"
    ],
    target: AshA2A.Skill,
    schema: @skill_schema,
    args: [:name, {:optional, :resource}, :action],
    identifier: :name
  }

  @a2a %Spark.Dsl.Section{
    name: :a2a,
    describe: "Declares A2A-discoverable agent skills backed by real Ash actions.",
    entities: [@skill]
  }

  def sections, do: [@a2a]
end
