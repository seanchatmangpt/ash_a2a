defmodule AshA2A.ConsequenceKernel.W5.Claim do
 @enforce_keys [:request_id,:effect_id,:prepared_digest,:subject_digest,:claim_id]
 defstruct @enforce_keys
 def new(attrs), do: struct!(__MODULE__,attrs)
end
