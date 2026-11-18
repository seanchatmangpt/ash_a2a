# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.DfCM.ReverseChestertonTest do
  use ExUnit.Case, async: true

  alias AshA2A.DfCM.FleetIntake

  test "every imported capability preserves mature negative knowledge" do
    for id <- FleetIntake.ids() do
      donor = FleetIntake.fetch!(id)
      assert length(donor["reuse"]) >= 1
      assert length(donor["negative_knowledge"]) >= 1
      assert is_binary(donor["falsifier"]) and donor["falsifier"] != ""
    end
  end

  test "recent universal laws and qualification algebra are references, not parallel owners" do
    universal = FleetIntake.fetch!("chatman_ecosystem")
    graphlaw = FleetIntake.fetch!("graphlaw")

    assert universal["capability"] == "universal_laws_formal_core"
    assert graphlaw["capability"] == "qualification_algebra"
    assert universal["owner"] == "chatman-ecosystem"
    assert graphlaw["owner"] == "GraphLaw"
    assert universal["authority"] == "NONE"
    assert graphlaw["authority"] == "NONE"
  end
end
