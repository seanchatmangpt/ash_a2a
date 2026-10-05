# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C1W4B.UnknownObservationTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.W4B.EntryPolicy

  test "unknown_observation",
    do: assert(EntryPolicy.admit(:unknown, :observation) == {:error, :consequence_unclassified})
end
