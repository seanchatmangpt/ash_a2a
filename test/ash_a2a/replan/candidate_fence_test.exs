# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.CandidateFenceTest do
  use ExUnit.Case, async: true

  test "candidate has no authority" do
    assert :ok = AshA2A.Replan.CandidateFence.check(%{standing: :candidate, authority: :none})
  end
end
