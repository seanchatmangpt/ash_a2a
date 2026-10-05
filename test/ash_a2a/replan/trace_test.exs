# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.TraceTest do
  use ExUnit.Case, async: true

  test "replay preserves order" do
    t = %AshA2A.Replan.Trace{} |> AshA2A.Replan.Trace.append(:a) |> AshA2A.Replan.Trace.append(:b)
    assert [:a, :b] = AshA2A.Replan.Trace.replay(t)
  end
end
