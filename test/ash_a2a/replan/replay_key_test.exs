# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.ReplayKeyTest do
  use ExUnit.Case, async: true

  test "deterministic" do
    assert AshA2A.Replan.ReplayKey.build("s", :p, 1) == AshA2A.Replan.ReplayKey.build("s", :p, 1)
  end
end
