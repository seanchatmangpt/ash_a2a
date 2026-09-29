defmodule AshA2A.C2.AuthorityResponse do
  @enforce_keys [:decision]
  defstruct [:decision, :certificate, :reason]
  def admit(c), do: %__MODULE__{decision: :admit, certificate: c}
  def refuse(r), do: %__MODULE__{decision: :refuse, reason: r}
end
