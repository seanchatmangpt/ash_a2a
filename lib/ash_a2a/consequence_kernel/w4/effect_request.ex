defmodule AshA2A.ConsequenceKernel.W4.EffectRequest do
  @moduledoc false
  @enforce_keys [:skill, :message, :resource_or_domain, :consequence]
  defstruct [:skill, :message, :resource_or_domain, :consequence, history: [], auth_identity: nil]
  @type t :: %__MODULE__{}
end
