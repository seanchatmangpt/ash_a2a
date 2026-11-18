# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.DfCM.GeneratedProjectionTest do
  use ExUnit.Case, async: true

  alias AshA2A.DfCM.Generated

  @modules [
    Generated.GraphLaw,
    Generated.Affidavit,
    Generated.AshR2RML,
    Generated.GgenCreate,
    Generated.Ferroplan,
    Generated.GymAct,
    Generated.GgenIgniter,
    Generated.GgenEcosystem,
    Generated.Wasm4pm,
    Generated.Bcinr,
    Generated.Castle,
    Generated.Xaas,
    Generated.GgenMarketplace,
    Generated.ChatmanEcosystem
  ]

  test "all generated donor modules resolve through the shared DfCM membrane" do
    assert length(@modules) == 14

    for module <- @modules do
      id = module.donor_id()
      contract = module.contract()
      assert contract["id"] == id
      assert contract["authority"] == "NONE"
      assert contract["consequence"] == "EVIDENCE_ONLY"

      assert {:ok, projection} = module.project(%{"module" => inspect(module)})
      assert projection["donor"] == id
      assert {:ok, ^projection} = module.admit_projection(projection)
    end
  end
end
