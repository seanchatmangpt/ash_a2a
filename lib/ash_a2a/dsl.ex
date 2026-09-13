defmodule AshA2A.Dsl do
  @moduledoc """
  Residual A2A projection configuration.

  Public Ash actions require no `skill` declaration. The `skill` entity is an
  optional override locator for A2A-only metadata such as a display name,
  description, tags, or exclusion. It cannot manufacture a capability: the
  referenced action must already exist and be public in Ash.

  The nested `argument` entity remains accepted for source compatibility with
  pre-v26.9.12 declarations, but it is deliberately ignored by capability
  compilation. Arguments are derived from `Ash.Resource.Info` instead.
  """

  @skill_schema [
    name: [
      type: :atom,
      required: true,
      doc: "A2A display/selector name override for the referenced public Ash action."
    ],
    resource: [
      type: {:spark, Ash.Resource},
      required: false,
      doc: "Target resource. Required on a domain; implicit on a resource."
    ],
    action: [
      type: :atom,
      required: true,
      doc: "Canonical public Ash action to override."
    ],
    description: [
      type: :string,
      required: false,
      doc: "Optional A2A-only description override."
    ],
    tags: [
      type: {:list, :string},
      required: false,
      doc: "Optional A2A-only tags override."
    ],
    expose?: [
      type: :boolean,
      default: true,
      doc: "Whether this otherwise-public Ash action is exposed through A2A."
    ]
  ]

  @argument_schema [
    name: [type: :atom, required: true],
    type: [type: :any, required: true]
  ]

  @argument %Spark.Dsl.Entity{
    name: :argument,
    describe:
      "Deprecated compatibility-only argument declaration; canonical arguments come from Ash.",
    target: AshA2A.Argument,
    schema: @argument_schema,
    args: [:name, :type],
    identifier: :name
  }

  @skill %Spark.Dsl.Entity{
    name: :skill,
    describe: "Overrides A2A projection metadata for an existing public Ash action.",
    examples: ["skill :echo, :read", "skill :echo, MyResource, :read"],
    target: AshA2A.Skill,
    schema: @skill_schema,
    args: [:name, {:optional, :resource}, :action],
    identifier: :name,
    entities: [arguments: [@argument]]
  }

  @a2a %Spark.Dsl.Section{
    name: :a2a,
    describe:
      "Optional residual A2A overrides. Public Ash actions are exposed without declarations.",
    entities: [@skill]
  }

  def sections, do: [@a2a]
end
