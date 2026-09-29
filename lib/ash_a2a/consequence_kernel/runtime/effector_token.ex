defmodule AshA2A.ConsequenceKernel.Runtime.EffectorToken do
  @moduledoc false
  alias AshA2A.ConsequenceKernel.Runtime.PreparedDigest
  @enforce_keys [:request_id, :effect_id, :prepared_digest, :owner]
  defstruct [:request_id, :effect_id, :prepared_digest, :owner]
  def issue(prepared, owner) do
    {:ok, digest} = PreparedDigest.fetch(prepared)
    %__MODULE__{request_id: prepared.instance.request_id, effect_id: prepared.instance.effect_id, prepared_digest: digest, owner: owner}
  end
end
