# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C1PreparedStore.ClaimedApplyingTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition
  test "claimed_applying", do: assert(Transition.admit(:claimed, :applying) == :ok)
end
