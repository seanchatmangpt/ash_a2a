defmodule AshA2A.ConsequenceKernel.Runtime.EffectorToken do
  @moduledoc false
  defstruct [:request_id, :effect_id, :prepared_digest, :owner]
  def issue(p,o), do: %__MODULE__{request_id: p.instance.request_id,effect_id: p.instance.effect_id,prepared_digest: p.digest,owner: o}
end
