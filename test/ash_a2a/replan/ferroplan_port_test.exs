# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.FerroplanPortTest do
  use ExUnit.Case, async: true

  test "declares FOND" do
    assert AshA2A.Replan.Port.Ferroplan.supports?(:fond)
  end
end
