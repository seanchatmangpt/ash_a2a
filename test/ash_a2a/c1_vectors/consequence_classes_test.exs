# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C1ConsequenceClassesTest do
  use ExUnit.Case, async: true

  test "known classes admitted unknown refused" do
    for x <- [:observe, :change, :external], do: assert(AshA2A.ConsequenceClass.admitted?(x))
    refute AshA2A.ConsequenceClass.admitted?(:unknown)
  end
end
