# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C1UnknownStandingTest do
  use ExUnit.Case, async: true

  test "unknown cannot derive standing" do
    assert {:error, _} = AshA2A.ConsequenceKernel.Standing.derive(%{outcome: :unknown})
  end
end
