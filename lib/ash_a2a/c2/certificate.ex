defmodule AshA2A.C2.Certificate do
  @enforce_keys [
    :version,
    :effect_digest,
    :principal,
    :policy_epoch,
    :revocation_epoch,
    :generation,
    :nonce,
    :not_before_ms,
    :expires_at_ms,
    :audience,
    :threshold,
    :signatures
  ]
  defstruct @enforce_keys

  def bound?(c, e), do: c.effect_digest == e.digest and c.principal == e.principal

  @type t :: %__MODULE__{
          version: pos_integer(),
          effect_digest: binary(),
          principal: term(),
          policy_epoch: non_neg_integer(),
          revocation_epoch: non_neg_integer(),
          generation: non_neg_integer(),
          nonce: binary(),
          not_before_ms: non_neg_integer(),
          expires_at_ms: pos_integer(),
          audience: binary(),
          threshold: pos_integer(),
          signatures: list()
        }
end
