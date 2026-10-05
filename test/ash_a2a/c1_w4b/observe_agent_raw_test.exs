# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C1W4B.ObserveAgentRawTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.W4B.EntryPolicy

  test "observe_agent_raw",
    do: assert(EntryPolicy.admit(:observe, :agent) == {:error, :invalid_consequence})
end
