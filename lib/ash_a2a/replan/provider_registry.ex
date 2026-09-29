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
