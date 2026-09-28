defmodule AshA2A.CS2.GeneratedConsumer do
  @moduledoc """
  Semantic values of the RFC-CS2-001 fleet consumer projection.

  UNSUPPORTED(generator-capability): no ggen pack for RFC-CS2-001 exists in
  `~/ggen-marketplace/packs`, so this module is handwritten residue. It derives
  every value from `AshA2A.CS2.FleetContract` so the fleet envelope has one
  source; replace this module with the ggen projection once the pack exists.
  """

  alias AshA2A.CS2.FleetContract

  @consumers ["xaas"]

  @spec subject() :: String.t()
  def subject, do: FleetContract.subject()

  @spec authority_ceiling() :: :construct
  def authority_ceiling, do: :construct

  @spec consumers() :: [String.t()]
  def consumers, do: @consumers

  @spec packet(term()) :: map()
  def packet(evidence), do: FleetContract.wrap(evidence)
end
