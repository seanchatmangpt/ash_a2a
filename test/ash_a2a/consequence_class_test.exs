# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceClassTest do
  use ExUnit.Case, async: true

  test "unknown is fail closed" do
    assert {:ok, :unknown} = AshA2A.ConsequenceClass.classify(:custom)
    refute AshA2A.ConsequenceClass.admitted?(:unknown)
  end
end
