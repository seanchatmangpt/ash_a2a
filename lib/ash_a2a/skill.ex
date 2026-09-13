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
  """

  @type t :: %__MODULE__{
          id: String.t() | nil,
          name: atom() | String.t() | nil,
          resource: module() | nil,
          domain: module() | nil,
          action: atom() | nil,
          description: String.t() | nil,
          tags: [String.t()] | nil,
          expose?: boolean(),
          arguments: [AshA2A.Argument.t()]
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
    expose?: true,
    arguments: [],
    __spark_metadata__: nil
  ]
end
