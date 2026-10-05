# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C2.AuthorityRequest do
  @enforce_keys [
    :effect,
    :effect_digest,
    :principal,
    :policy_epoch,
    :revocation_epoch,
    :generation,
    :audience
  ]
  defstruct @enforce_keys

  def new(effect, ctx) do
    %__MODULE__{
      effect: effect,
      effect_digest: effect.digest,
      principal: effect.principal,
      policy_epoch: Map.fetch!(ctx, :policy_epoch),
      revocation_epoch: Map.fetch!(ctx, :revocation_epoch),
      generation: Map.fetch!(ctx, :generation),
      audience: Map.fetch!(ctx, :audience)
    }
  end

  @type t :: %__MODULE__{
          effect: AshA2A.C2.PreparedEffect.t(),
          effect_digest: binary(),
          principal: term(),
          policy_epoch: non_neg_integer(),
          revocation_epoch: non_neg_integer(),
          generation: non_neg_integer(),
          audience: binary()
        }
end
