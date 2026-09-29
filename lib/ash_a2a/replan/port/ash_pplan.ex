defmodule AshA2A.Replan.Port.AshPPlan do
  @behaviour AshA2A.Replan.Provider
  def supports?(f), do: f in [:hddl,:fond,:powl]
  def propose(request, opts) do
    mod=Keyword.get(opts,:ash_pplan_module,AshPPlan)
    cond do
      Code.ensure_loaded?(mod) and function_exported?(mod,:plan,2) -> apply(mod,:plan,[request,opts])
      true -> {:error,:ash_pplan_unavailable}
    end
  end
end