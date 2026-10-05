# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.StalePlanTest do
  use ExUnit.Case, async: true

  test "digest drift invalidates" do
    assert AshA2A.Replan.StalePlan.stale?(%{projection_digest: "a"}, %{projection_digest: "b"})
  end
end
