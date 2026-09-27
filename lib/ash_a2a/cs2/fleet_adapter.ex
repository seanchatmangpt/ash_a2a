defmodule AshA2A.CS2.FleetAdapter do
  @moduledoc """
  Adapter from the canonical CS2 fleet envelope to downstream workflow packets.
  """

  alias AshA2A.CS2.ConsumerContract

  def evidence_packet(payload, provenance) do
    payload
    |> ConsumerContract.wrap(provenance)
    |> ConsumerContract.triage()
  end

  def xaas_packet(payload, provenance) do
    packet = evidence_packet(payload, provenance)

    %{
      contract: "cs2-fleet-contract/26.9.26",
      destination: "xaas.engineer_workflow",
      subject: ConsumerContract.subject(),
      packet: packet
    }
  end
end
