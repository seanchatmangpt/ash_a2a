# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

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
      doc: "Whether this otherwise-public Ash action is exposed through AshA2A.Protocol."
    ],
    consequence: [
      type: {:one_of, [:observe, :change, :external_do, :unknown]},
      required: false,
      doc:
        "Explicit consequence classification (see AshA2A.Skill's @moduledoc). " <>
          "Required to lift a generic :action skill off the fail-closed :unknown " <>
          "default. On :create/:update/:destroy it may only RAISE the :change " <>
          "default (to :external_do or :unknown); `consequence: :observe` on a " <>
          "mutating action is a compile-time DslError (observe_on_mutating_action, " <>
          "SEC-04), because :observe skips authority, admission and receipts."
    ],
    on_cancel: [
      type: {:or, [:module, :mfa]},
      required: false,
      doc:
        "Optional real Ash-side compensation hook (see AshA2A.OnCancel), run by " <>
          "AshA2A.Agent.__cancel__/2 when a task under this skill is genuinely " <>
          "canceled. A bare module must implement `c:AshA2A.OnCancel.on_cancel/3`; " <>
          "an `{module, function, extra_args}` MFA is called with " <>
          "`[exec_context, task_id, context_id | extra_args]`. Unset (the " <>
          "default) leaves cancellation telemetry-only, unchanged from before " <>
          "this option existed."
    ],
    argument_mapping: [
      type: {:map, :string, :atom},
      default: %{},
      doc:
        "Map of wire (string) argument name to atom action argument name, used to " <>
          "translate inbound A2A message arguments onto the canonical Ash action's " <>
          "arguments. Empty (the default) means wire names already match action " <>
          "argument names and are passed through unchanged."
    ],
    get?: [
      type: :boolean,
      default: false,
      doc:
        "Marks a read skill as a single-record get (mirrors ash_json_api's `get?` " <>
          "semantic). Purely declarative metadata on the skill entity; consumers " <>
          "read it via the compiled capability index."
    ],
    lease_required?: [
      type: :boolean,
      default: false,
      doc:
        "Governance boundary: when `true`, dispatch under this skill requires a " <>
          "valid authority lease. The authorizer consequence itself is enforced " <>
          "outside this entity (see the architecture verifier), so declaring it " <>
          "here changes no runtime behavior by itself."
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

  @hddl_fact_schema {:tuple, [:atom, {:list, :atom}]}

  @hddl_operator_schema [
    parameters: [
      type: {:list, :atom},
      default: [],
      doc: "Ordered HDDL parameter variable names for this operator's :parameters."
    ],
    preconditions: [
      type: {:list, @hddl_fact_schema},
      default: [],
      doc: "Facts required before this operator, as {predicate, args} tuples."
    ],
    add_effects: [
      type: {:list, @hddl_fact_schema},
      default: [],
      doc: "Facts asserted true after this operator runs, as {predicate, args} tuples."
    ],
    delete_effects: [
      type: {:list, @hddl_fact_schema},
      default: [],
      doc: "Facts retracted after this operator runs, as {predicate, args} tuples."
    ]
  ]

  @hddl_operator %Spark.Dsl.Entity{
    name: :hddl_operator,
    describe:
      "Declares this skill's HDDL :action operator (parameters/precondition/effect) for " <>
        "the deterministic, non-LLM planning path.",
    target: AshA2A.HddlOperator,
    schema: @hddl_operator_schema,
    identifier: {:auto, :unique_integer}
  }

  @skill %Spark.Dsl.Entity{
    name: :skill,
    describe: "Overrides A2A projection metadata for an existing public Ash action.",
    examples: ["skill :echo, :read", "skill :echo, MyResource, :read"],
    target: AshA2A.Skill,
    schema: @skill_schema,
    args: [:name, {:optional, :resource}, :action],
    identifier: :name,
    entities: [arguments: [@argument], hddl_operators: [@hddl_operator]]
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
        `AshA2A.Protocol.Message.metadata` sets `:semantic_request`/`"semantic_request"`
        to `true` (the same atom-then-string caller-facing convention
        `:skill` metadata already uses, via `AshA2A.MetadataKey`) -- a
        normal skill-targeted or unflagged free-text message never reaches
        the semantic compiler
        regardless of this setting.
        """
      ]
    ]
  }

  @authority %Spark.Dsl.Section{
    name: :authority,
    describe: "Declarative two-port gate policies and lease constraints for A2A actions.",
    schema: [
      gate: [
        type: {:one_of, [:two_port, :open, :disabled]},
        default: :two_port,
        doc: "Default admission gate applied to consequence-bearing actions."
      ],
      lease_duration_ms: [
        type: :pos_integer,
        default: 60_000,
        doc: "Default lease lifetime in milliseconds."
      ]
    ]
  }

  @hooks %Spark.Dsl.Section{
    name: :hooks,
    describe: "Declarative binding of GraphLaw knowledge hooks to action lifecycle points.",
    schema: [
      pre_dispatch: [
        type: {:list, :atom},
        default: [],
        doc: "Hook identifiers evaluated before action dispatch."
      ],
      post_dispatch: [
        type: {:list, :atom},
        default: [],
        doc: "Hook identifiers evaluated after action execution."
      ]
    ]
  }

  def sections, do: [@a2a, @authority, @hooks]
end
