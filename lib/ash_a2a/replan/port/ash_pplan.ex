defmodule AshA2A.Replan.Port.AshPPlan do
  @behaviour AshA2A.Replan.Provider

  def supports?(formalism), do: formalism in [:fond, :powl]

  def propose(%{formalism: :fond} = request, opts) do
    mod = Keyword.get(opts, :ash_pplan_module, AshPPlan)

    with true <- Code.ensure_loaded?(mod),
         true <- function_exported?(mod, :select_policy, 3),
         {:ok, domain} <- fetch_domain(request),
         {:ok, initial} <- fetch_initial(request) do
      case apply(mod, :select_policy, [domain, initial, Keyword.get(opts, :policy_opts, [])]) do
        {:ok, selection} -> {:ok, Map.put(selection, :subject, Map.get(request, :subject))}
        {:error, _} = error -> error
        other -> {:error, {:invalid_ash_pplan_result, other}}
      end
    else
      false -> {:error, :ash_pplan_unavailable}
      {:error, _} = error -> error
    end
  end

  def propose(%{formalism: :powl} = request, opts) do
    mod = Keyword.get(opts, :ash_pplan_module, AshPPlan)

    if Code.ensure_loaded?(mod) and function_exported?(mod, :plan, 1) do
      case apply(mod, :plan, [Map.fetch!(request, :plan_iri)]) do
        {:ok, plan} -> {:ok, %{subject: Map.get(request, :subject), plan: plan, formalism: :powl}}
        nil -> {:error, :plan_not_found}
        other -> {:ok, %{subject: Map.get(request, :subject), plan: other, formalism: :powl}}
      end
    else
      {:error, :ash_pplan_unavailable}
    end
  end

  def propose(_request, _opts), do: {:error, :unsupported_formalism}

  defp fetch_domain(%{domain: domain}), do: {:ok, domain}
  defp fetch_domain(_), do: {:error, :missing_domain}
  defp fetch_initial(%{initial: initial}), do: {:ok, initial}
  defp fetch_initial(_), do: {:error, :missing_initial}
end
