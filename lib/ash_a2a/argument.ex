defmodule AshA2A.Argument do
  @moduledoc """
  Spark DSL entity target for `a2a do skill ... do argument ... end end`.

  Structural prerequisite entity: exists so `AshA2A.Dsl`'s `:skill` entity
  can declare `entities: [@argument]` and therefore accept a nested
  `do...end` block at all (`Spark.Dsl.Entity` requires an `entities:` list
  on the parent entity before it will accept child entities in a block).
  Field population/validation of declared arguments against the real Ash
  action's arguments is a separate, later concern -- not implemented here.
  """

  @type t :: %__MODULE__{
          name: atom(),
          type: term(),
          __identifier__: term()
        }

  defstruct [
    :name,
    :type,
    :__identifier__,
    __spark_metadata__: nil
  ]
end
