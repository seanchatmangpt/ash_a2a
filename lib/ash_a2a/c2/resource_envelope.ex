defmodule AshA2A.C2.ResourceEnvelope do
 @enforce_keys [:principal,:effect_digest,:budget,:generation]
 defstruct @enforce_keys
 def bound?(r,e,c), do: r.principal==e.principal and r.effect_digest==e.digest and r.generation==c.generation
end