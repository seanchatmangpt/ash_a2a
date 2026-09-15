defmodule AshA2A.HddlOperator do
  @moduledoc """
  Spark DSL entity target for `a2a do skill ... do hddl_operator ... end end`.

  Declares a skill's HDDL `:action` operator (parameters, precondition, and
  add/delete effects) for the deterministic, non-LLM planning path. Unlike
  `AshA2A.Argument` (a structural prerequisite entity whose declared value is
  deliberately ignored by capability compilation -- see its own @moduledoc
  and `AshA2A.Verify`'s `dead_argument_warning/1`), this entity's value is a
  *live* field: `AshA2A.CapabilityIndex.Compiler.project/3` copies it through
  into the real compiled `AshA2A.Skill.hddl_operators`, because HDDL operator
  metadata has no equivalent to derive from canonical Ash action
  introspection the way arguments do.

  Each fact is a plain 2-tuple `{predicate, args}` -- a STRIPS add/delete-list
  operator fact, directly renderable to an HDDL `(predicate ?arg1 ?arg2)`
  atom (or `(not (predicate ...))` for a delete-effect). Whether a fact's
  `args` are a subset of the operator's own `parameters`, and whether more
  than one `hddl_operator` block is declared per skill, are compile-time
  concerns for a later verifier -- not enforced by this entity or its schema.
  """

  @type fact :: {predicate :: atom(), args :: [atom()]}

  @type t :: %__MODULE__{
          parameters: [atom()],
          preconditions: [fact()],
          add_effects: [fact()],
          delete_effects: [fact()],
          __identifier__: term(),
          __spark_metadata__: term()
        }

  defstruct [
    :__identifier__,
    parameters: [],
    preconditions: [],
    add_effects: [],
    delete_effects: [],
    __spark_metadata__: nil
  ]
end
