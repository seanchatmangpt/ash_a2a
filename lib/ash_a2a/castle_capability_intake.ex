defmodule AshA2A.CastleCapabilityIntake do
  @moduledoc """
  CASTLE edge-capability registry for AshA2A.

  External adapters and protocol knowledge terminate at SA2A transport. This
  registry is descriptive and has no dispatch or actuation path.
  """

  @projection_source "seanchatmangpt/ggen-ecosystem@50fdfa20c84205a80c6eb94e916cffbedc4b816e"
  @owner_capability "SA2A_TRANSPORT"
  @authority_ceiling :construct

  @donors [
    %{repository: "seanchatmangpt/ash_atlassian", sha: "43e3d21b7c4e4571493fcf3757392ed16f2dd967", capability: :work_system_adapter, disposition: :wrap},
    %{repository: "seanchatmangpt/ash_planning_center", sha: "5ee26cbdc8fef26c92c7691355c76f5aed2e7b2c", capability: :planning_center_adapter, disposition: :wrap},
    %{repository: "seanchatmangpt/agile-protocol-specification", sha: "1b731a6e963fa249c4e3e8bcbe932025c5e38bb5", capability: :protocol_specification_knowledge, disposition: :keep_knowledge_plane}
  ]

  @spec donors() :: [map()]
  def donors, do: @donors

  @spec projection_source() :: String.t()
  def projection_source, do: @projection_source

  @spec owner_capability() :: String.t()
  def owner_capability, do: @owner_capability

  @spec authority_ceiling() :: :construct
  def authority_ceiling, do: @authority_ceiling

  @spec fetch(String.t()) :: {:ok, map()} | {:error, :unknown_castle_edge_donor}
  def fetch(repository) when is_binary(repository) do
    case Enum.find(@donors, &(&1.repository == repository)) do
      nil -> {:error, :unknown_castle_edge_donor}
      donor -> {:ok, donor}
    end
  end

  @spec transport_authority?(term()) :: false
  def transport_authority?(_), do: false
end
