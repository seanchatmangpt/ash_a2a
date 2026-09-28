defmodule AshA2A.CS2.ConsumerContract do
  @moduledoc """
  Consumer-facing CS2 contract used by `AshA2A.CS2.FleetAdapter`.

  A thin delegate over `AshA2A.CS2.Contract`: `wrap/2` builds the evidence
  packet, `triage/1` promotes it to a triage packet. Novelty is not assessed at
  this layer, so a packet without a `:novelty` key is triaged as
  `:unassessed` rather than silently claiming novelty.
  """

  alias AshA2A.CS2.Contract

  @spec subject() :: String.t()
  def subject, do: Contract.subject()

  @spec wrap(term(), map()) :: map()
  def wrap(payload, provenance), do: Contract.evidence_packet(payload, provenance)

  @spec triage(map()) :: map()
  def triage(%{kind: :cs2_evidence_packet} = packet) do
    packet
    |> Map.put_new(:novelty, :unassessed)
    |> Map.put(:kind, :cs2_triage_packet)
  end
end
