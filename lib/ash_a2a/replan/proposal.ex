# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.Proposal do
  @enforce_keys [:subject, :candidate, :reason, :attempt]
  defstruct [:subject, :candidate, :reason, :attempt, authority: :none, standing: :candidate]

  def new(subject, candidate, reason, attempt \\ 0),
    do: %__MODULE__{subject: subject, candidate: candidate, reason: reason, attempt: attempt}
end
