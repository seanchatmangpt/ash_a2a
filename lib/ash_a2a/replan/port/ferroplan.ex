defmodule AshA2A.Replan.Port.Ferroplan do
  @behaviour AshA2A.Replan.Provider
  def supports?(f), do: f in [:hddl,:fond,:pddl]
  def propose(request, opts) do
    mod=Keyword.get(opts,:ferroplan_module,BeamPM.Ferroplan)
    if Code.ensure_loaded?(mod) and function_exported?(mod,:plan_production,4), do: apply(mod,:plan_production,[Map.fetch!(request,:domain),Map.fetch!(request,:problem),Map.get(request,:extra,%{}),opts]), else: {:error,:ferroplan_unavailable}
  end
end