# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.CastleCapabilityIntakeRuntimeTest do
  use ExUnit.Case, async: true

  alias AshA2A.CastleCapabilityIntake

  test "adapter and protocol donors terminate at transport without authority" do
    assert CastleCapabilityIntake.owner_capability() == "SA2A_TRANSPORT"
    assert CastleCapabilityIntake.authority_ceiling() == :construct
    assert length(CastleCapabilityIntake.donors()) == 3

    assert {:ok, donor} = CastleCapabilityIntake.fetch("seanchatmangpt/ash_atlassian")
    assert donor.sha == "43e3d21b7c4e4571493fcf3757392ed16f2dd967"
    refute CastleCapabilityIntake.transport_authority?(donor)

    assert {:error, :unknown_castle_edge_donor} =
             CastleCapabilityIntake.fetch("seanchatmangpt/unknown")
  end
end
