# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.Beam4pmPortTest do
  use ExUnit.Case, async: true

  test "declares POWL" do
    assert AshA2A.Replan.Port.Beam4pm.supports?(:powl)
  end
end
