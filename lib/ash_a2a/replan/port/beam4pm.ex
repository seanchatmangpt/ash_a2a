defmodule AshA2A.Replan.Port.Beam4pm do
  @behaviour AshA2A.Replan.Provider

  def supports?(formalism), do: formalism in [:hddl, :fond, :powl, :pddl]

  def propose(request, opts) do
    mod = Keyword.get(opts, :beam4pm_module, BeamPM.ReplanRouter)

    if Code.ensure_loaded?(mod) and function_exported?(mod, :execute, 4) do
      result =
        apply(mod, :execute, [
          Map.get(request, :decision, :hddl_replan),
          Map.get(request, :handle, 0),
          request,
          Keyword.delete(opts, :beam4pm_module)
        ])

      normalize(result, request)
    else
      {:error, :beam4pm_unavailable}
    end
  end

  defp normalize({:ok, candidate}, request),
    do: {:ok, Map.put_new(candidate, :subject, Map.get(request, :subject))}

  defp normalize({:recompile_required, evidence}, request),
    do:
      {:ok,
       %{subject: Map.get(request, :subject), outcome: :recompile_required, evidence: evidence}}

  defp normalize({:error, _} = error, _request), do: error
  defp normalize(other, _request), do: {:error, {:invalid_beam4pm_result, other}}
end
