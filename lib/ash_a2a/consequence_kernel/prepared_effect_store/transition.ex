# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.PreparedEffectStore.Transition do
  @allowed %{
    prepared: [:claimed, :refused, :released],
    claimed: [:applying, :released],
    applying: [:completed, :unknown_outcome],
    unknown_outcome: [:reconciled, :compensated]
  }
  def admit(from, to) when is_atom(from) and is_atom(to) do
    if to in Map.get(@allowed, from, []), do: :ok, else: {:error, :prepared_transition_refused}
  end
end
