# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C1PreparedStore.PreparedUnknownTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition

  test "prepared_unknown",
    do:
      assert(
        Transition.admit(:prepared, :unknown_outcome) == {:error, :prepared_transition_refused}
      )
end
