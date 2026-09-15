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
    ],
    consequence: [
      type: {:one_of, [:observe, :change, :external_do, :unknown]},
      required: false,
      doc:
        "Explicit consequence classification (see AshA2A.Skill's @moduledoc). " <>
          "Required to lift a generic :action skill off the fail-closed :unknown " <>
          "default; has no effect on :read/:create/:update/:destroy unless a " <>
          "resource author deliberately wants to override their own default."
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
    entities: [@skill],
    schema: [
      semantic_requests: [
        type: :boolean,
        default: false,
        doc: """
        Explicitly opts this resource/domain into the semantic-compilation A2A
        surface (`AshA2A.Semantic.Compiler`). This is deliberately NOT a
        silent fallback for an unrecognized skill name or arbitrary free
        text -- v26.9.14's design decision is that semantic compilation is
        an explicit production A2A surface, never a surprise LLM invocation
        a caller stumbles into. Two gates must both be true before a real
        dispatch reaches `Compiler.compile/3`: (1) this option is `true` on
        the target resource/domain, and (2) the caller's inbound
        `A2A.Message.metadata` sets `:semantic_request`/`"semantic_request"`
        to `true` (the same atom-then-string caller-facing convention
        `:skill` metadata already uses, via `AshA2A.MetadataKey`) -- a
        normal skill-targeted or unflagged free-text message never reaches
        the semantic compiler
        regardless of this setting.
        """
      ]
    ]
  }

  def sections, do: [@a2a]
end
