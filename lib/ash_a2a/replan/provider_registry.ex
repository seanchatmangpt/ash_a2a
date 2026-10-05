# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.ProviderRegistry do
  @defaults [
    beam4pm: AshA2A.Replan.Port.Beam4pm,
    ferroplan: AshA2A.Replan.Port.Ferroplan,
    ash_pplan: AshA2A.Replan.Port.AshPPlan
  ]
  def defaults, do: @defaults

  def for(formalism, providers \\ @defaults),
    do: Enum.filter(providers, fn {_id, m} -> m.supports?(formalism) end)
end
