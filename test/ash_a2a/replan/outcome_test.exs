# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.OutcomeTest do
  use ExUnit.Case, async: true

  test "unknown is recoverable" do
    assert AshA2A.Replan.Outcome.recoverable?(:unknown_outcome)
  end
end
