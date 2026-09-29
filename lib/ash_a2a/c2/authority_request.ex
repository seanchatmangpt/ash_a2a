defmodule AshA2A.C2.AuthorityRequest do
  @enforce_keys [:effect, :principal, :policy_epoch, :revocation_epoch, :generation]
  defstruct @enforce_keys

  def new(effect, ctx) do
    %__MODULE__{
      effect: effect,
      principal: effect.principal,
      policy_epoch: Map.fetch!(ctx, :policy_epoch),
      revocation_epoch: Map.fetch!(ctx, :revocation_epoch),
      generation: Map.fetch!(ctx, :generation)
    }
  end
end
