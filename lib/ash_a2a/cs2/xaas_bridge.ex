defmodule AshA2A.CS2.XaasBridge do
  alias AshA2A.CS2.FleetContract
  def packet(payload) do
    contract = FleetContract.wrap(payload)
    %{schema: "ash-a2a.cs2.xaas-packet.v1", subject: FleetContract.subject(), producer: "ash_a2a", consumer: "xaas", contract: contract}
  end
end
