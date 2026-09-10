defmodule AshA2A.Skill do
  @moduledoc """
  Spark DSL entity target for `a2a do skill ... end`.

  Field shape matches `AshA2A.CapabilityIndex.skill/0` (`name`, `resource`,
  `action`, `arguments`) so a compiled entity can be persisted into the
  capability index without translation (ash_a2a PRD/ARD §3.2/§3.4).

  `resource` is `nil` at declaration time for a resource-level `skill :name,
  :action` (2-arg) invocation -- `AshA2A.Transformers.BuildCapabilityIndex`
  fills it in with the enclosing resource module, mirroring
  `AshAi.Transformers.ResourceTools` (`~/xaas/deps/ash_ai/lib/ash_ai/transformers/resource_tools.ex:19-25`).
  """

  @type t :: %__MODULE__{
          name: atom(),
          resource: module() | nil,
          domain: module() | nil,
          action: atom(),
          arguments: [term()]
        }

  defstruct [:name, :resource, :domain, :action, arguments: [], __spark_metadata__: nil]
end
