# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C1W4B.NilDispatcherTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.W4B.EntryPolicy

  test "nil_dispatcher",
    do: assert(EntryPolicy.admit(nil, :dispatcher) == {:error, :invalid_consequence})
end
