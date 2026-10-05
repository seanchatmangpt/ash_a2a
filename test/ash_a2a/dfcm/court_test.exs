# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.DfCM.CourtTest do
  use ExUnit.Case, async: true

  alias AshA2A.DfCM.{Court, FleetIntake}

  test "every donor has one exact-subject negative court" do
    assert :ok = Court.validate_all()

    for id <- FleetIntake.ids() do
      donor = FleetIntake.fetch!(id)
      assert {:ok, court} = Court.load(id)
      assert court["donor"] == id
      assert court["subject"] == donor["subject"]
      assert court["capability"] == donor["capability"]
      assert court["falsifier"] == donor["falsifier"]
      assert court["authority"] == "NONE"
      assert court["consequence"] == "EVIDENCE_ONLY"
      assert court["expected"] in ["REFUSED", "UNKNOWN", "UNSUPPORTED"]
    end
  end
end
