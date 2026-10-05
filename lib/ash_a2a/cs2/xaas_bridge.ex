# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.CS2.XaasBridge do
  @moduledoc """
  Projects a CS2 fleet-contract envelope into the xaas consumer packet
  (`ash-a2a.cs2.xaas-packet.v1`).
  """

  alias AshA2A.CS2.FleetContract

  @spec packet(term()) :: map()
  def packet(payload) do
    contract = FleetContract.wrap(payload)

    %{
      schema: "ash-a2a.cs2.xaas-packet.v1",
      subject: FleetContract.subject(),
      producer: "ash_a2a",
      consumer: "xaas",
      contract: contract
    }
  end
end
