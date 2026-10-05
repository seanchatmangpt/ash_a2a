# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.EffectIdentity do
  def preserve?(a, b) do
    Map.get(a, :actuation_id) == Map.get(b, :actuation_id) and
      AshA2A.Replan.SubjectLineage.same?(a, b)
  end
end
