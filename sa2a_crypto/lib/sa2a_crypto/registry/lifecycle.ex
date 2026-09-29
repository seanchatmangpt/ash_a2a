defmodule Sa2aCrypto.Registry.Lifecycle do
  @moduledoc """
  NIST SP 800-57 key states and the legal transitions between them.

      pre_activation -> active | compromised | destroyed
      active         -> suspended | deactivated | compromised
      suspended      -> active | deactivated | compromised
      deactivated    -> compromised | destroyed
      compromised    -> destroyed
      destroyed      -> (terminal)

  Reactivating a suspended key is legal; reactivating a deactivated, compromised or
  destroyed key is not (a key that left service never re-enters it).
  """
  @table %{
    pre_activation: [:active, :compromised, :destroyed],
    active: [:suspended, :deactivated, :compromised],
    suspended: [:active, :deactivated, :compromised],
    deactivated: [:compromised, :destroyed],
    compromised: [:destroyed],
    destroyed: []
  }

  @spec allowed?(atom(), atom()) :: boolean()
  def allowed?(from, to), do: to in Map.get(@table, from, [])

  @spec check(atom(), atom()) :: :ok | {:error, :illegal_transition}
  def check(from, to), do: if(allowed?(from, to), do: :ok, else: {:error, :illegal_transition})

  @doc "States in which a key counts as revoked for quorum purposes."
  def revoked?(state), do: state in [:compromised, :destroyed]
end
