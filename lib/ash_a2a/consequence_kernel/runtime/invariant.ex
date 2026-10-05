# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.Runtime.Invariant do
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition

  def transition_path?(states),
    do:
      states
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.all?(fn [a, b] -> Transition.admit(a, b) == :ok end)
end
