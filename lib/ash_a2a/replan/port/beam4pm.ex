defmodule AshA2A.Replan.Port.Beam4pm do
  @behaviour AshA2A.Replan.Provider
  def supports?(f), do: f in [:hddl,:fond,:powl,:pddl]
  def propose(request, opts) do
    mod=Keyword.get(opts,:beam4pm_module,BeamPM.ReplanRouter)
    if Code.ensure_loaded?(mod) and function_exported?(mod,:execute,4), do: apply(mod,:execute,[Map.get(request,:decision,:replan),Map.get(request,:handle),request,opts]), else: {:error,:beam4pm_unavailable}
  end
end