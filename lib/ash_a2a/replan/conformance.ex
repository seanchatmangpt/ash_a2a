# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.Conformance do
  def check(candidate, subject) do
    with :ok <- AshA2A.Replan.CandidateFence.check(candidate),
         :ok <- AshA2A.Replan.SubjectLineage.guard(Map.get(candidate, :subject, subject), subject),
         do: :ok
  end
end
