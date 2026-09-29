defmodule Actuator.Context do
  @moduledoc """
  The actuator's OWN view of the world: pinned key registry, audience, policy epoch,
  revocation view, allowed subjects/capabilities, quorum policy, generation view, clock.

  Nothing here is ever taken from a request or certificate. `Actuator.Config.load/1`
  builds it from the operator-pinned config file and the state directory, on every request,
  so a policy-epoch or revocation refresh takes effect without a restart.
  """
  @enforce_keys [:state_dir, :registry, :audience, :policy_epoch]
  defstruct [
    :state_dir,
    :registry,
    :audience,
    :policy_epoch,
    # %{refreshed_at: unix, epoch: int, revoked: MapSet of kid} | nil (nil = fail closed)
    revocation: nil,
    allowed_subjects: [],
    allowed_capabilities: :all,
    quorum: %{},
    quorum_default: 1,
    generations: %{},
    generation_default: 1,
    skew: 30,
    max_ttl: 900,
    max_revocation_staleness: 300,
    required_profile: :classical,
    allowed_algs: nil,
    clock: &__MODULE__.system_clock/0
  ]

  @type t :: %__MODULE__{}

  def system_clock, do: System.os_time(:second)
  def now(%__MODULE__{clock: c}), do: c.()

  def quorum_for(%__MODULE__{quorum: q, quorum_default: d}, class), do: Map.get(q, class, d)
end
