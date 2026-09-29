defmodule AshA2A.C2.Certificate do
  @enforce_keys [
    :effect_digest,
    :principal,
    :policy_epoch,
    :revocation_epoch,
    :generation,
    :signatures
  ]
  defstruct @enforce_keys
  def bound?(c, e), do: c.effect_digest == e.digest and c.principal == e.principal
end
