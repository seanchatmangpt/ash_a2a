defmodule AshA2A.Skill do
  @moduledoc """
  Derived reference to one public Ash action exposed through A2A.

  `AshA2A.Skill` is not a second action model. Its `{resource, action}` pair
  points back to the canonical `Ash.Resource` action, while `id`, `name`,
  `description`, and `tags` are A2A projection data.

  For backwards compatibility the same struct is also the target of the
  optional `a2a do skill ... end` residual-override DSL. Fields such as
  `arguments` and Spark metadata may therefore be populated on a raw DSL
  entity, but they are never copied into the canonical capability index.
  Action arguments are always derived from Ash introspection.

  `hddl_operators` is a different kind of override field: it has no Ash-
  native equivalent to derive instead, so unlike `arguments` it IS copied
  through into the compiled capability index by
  `AshA2A.CapabilityIndex.Compiler.project/3` -- see that function and
  `AshA2A.HddlOperator`'s own @moduledoc.

  ## `consequence`

  `Ash.Resource.Actions.*{}.type` alone is not a sufficient consequence
  calculus: `:read` is unambiguously non-consequence-bearing, and
  `:create`/`:update`/`:destroy` are unambiguously consequence-bearing, but
  a generic `:action` may be either (a pure calculation/query, or a real
  data-/state-mutating or externally-effecting operation) -- `action.type`
  alone cannot distinguish the two. `consequence` is this capability's own,
  explicit classification, computed once at compile time
  (`AshA2A.CapabilityIndex.Compiler.project/3`) and carried as real
  capability truth alongside `id`/`resource`/`action` rather than
  recomputed ad hoc by every consumer (`AshA2A.Agent`, `AshA2A.CommandBus`):

    * `:observe` -- never consequence-bearing; never requires `CommandBus`
      admission/authority, never produces a `Receipt`. Default for `:read`.
    * `:change` -- consequence-bearing via the canonical Ash data layer.
      Default for `:create`/`:update`/`:destroy`.
    * `:external_do` -- consequence-bearing via some effect outside the Ash
      data layer (e.g. mutating other real process state). No default
      action type maps here; a resource author must declare it explicitly.
    * `:unknown` -- not yet classified. Default for a generic `:action`
      with no explicit `consequence:` override. `CommandBus`/`AshA2A.Agent`
      both fail an `:unknown` capability closed
      (`:consequence_unclassified`) rather than silently treating it as
      either safe-to-skip or safe-to-execute -- an unclassified generic
      action must never be the means by which a real consequence bypasses
      the `CommandBus` DO boundary.

  ## `on_cancel`

  Optional real Ash-side compensation hook run by `AshA2A.Agent.__cancel__/2`
  when a task under this skill is genuinely canceled (see
  `AshA2A.OnCancel`'s @moduledoc for the full contract and failure handling).
  Like `hddl_operators` and unlike `arguments`, this field has no Ash-native
  equivalent to derive instead, so it IS copied through into the compiled
  capability index by `AshA2A.CapabilityIndex.Compiler.project/3`. `nil`
  (the default) means no hook is declared -- cancellation stays telemetry-only,
  exactly as before this field existed.
  """

  @type consequence :: :observe | :change | :external_do | :unknown

  @type t :: %__MODULE__{
          id: String.t() | nil,
          name: atom() | String.t() | nil,
          resource: module() | nil,
          domain: module() | nil,
          action: atom() | nil,
          description: String.t() | nil,
          tags: [String.t()] | nil,
          expose?: boolean(),
          consequence: consequence() | nil,
          arguments: [AshA2A.Argument.t()],
          hddl_operators: [AshA2A.HddlOperator.t()],
          on_cancel: module() | mfa() | nil
        }

  defstruct [
    :id,
    :name,
    :resource,
    :domain,
    :action,
    :description,
    :tags,
    :__identifier__,
    :consequence,
    :on_cancel,
    expose?: true,
    arguments: [],
    hddl_operators: [],
    __spark_metadata__: nil
  ]
end
