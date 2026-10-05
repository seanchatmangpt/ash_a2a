# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Gall.Closure.OcelProjectionTest do
  use ExUnit.Case, async: true
  alias AshA2A.Gall.Closure.OcelProjection

  test "OCEL projection keeps candidate, command and receipt as separate objects" do
    candidate = %{candidate_digest: "sha256:" <> String.duplicate("a", 64)}
    command = %{command_id: "c1"}
    receipt = %{receipt_id: "r1", recorded_at: "2026-09-28T18:00:00Z"}
    projection = OcelProjection.project(candidate, command, receipt)

    assert map_size(projection["ocel:objects"]) == 3
    assert projection["ocel:objects"]["command:c1"]["ocel:type"] == "command"
    assert projection["ocel:objects"]["receipt:r1"]["ocel:type"] == "receipt"
  end
end
