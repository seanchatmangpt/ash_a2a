defmodule Sa2aCrypto.KeyRecord do
  @moduledoc """
  Read-only registry entry for one `kid`. `alg` is the registry's algorithm for the key
  (the verifier never trusts the envelope's `alg` alone).
  """
  @states [:pre_activation, :active, :suspended, :deactivated, :compromised, :destroyed]
  @tiers [:i1, :i2, :i3, :i4]

  @enforce_keys [:kid, :alg, :public_key, :custodian_id, :custody_tier, :state]
  defstruct [
    :kid,
    :alg,
    :public_key,
    :custodian_id,
    :custody_tier,
    :state,
    revocation_epoch: 0,
    not_after: nil
  ]

  @type t :: %__MODULE__{}

  def states, do: @states
  def tiers, do: @tiers
end
