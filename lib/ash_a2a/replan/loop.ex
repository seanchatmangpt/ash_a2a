defmodule AshA2A.Replan.Loop do
  alias AshA2A.Replan.{AttemptBudget,ProviderSet,ProviderResult,SubjectLineage}
  def run(subject, request, providers, opts \\ []) do
    budget=AttemptBudget.new(Keyword.get(opts,:max_attempts,3)); step(subject,request,providers,MapSet.new(),budget,0,opts)
  end
  defp step(subject,request,providers,excluded,budget,attempt,opts) do
    with {:ok,next_budget} <- AttemptBudget.consume(budget),
         {id,mod} <- ProviderSet.select(providers,Map.get(request,:formalism,:hddl),excluded) || {:error,:none},
         {:ok,result} <- ProviderResult.normalize(mod.propose(Map.put(request,:subject,subject),opts),id),
         :ok <- SubjectLineage.guard(subject,Map.get(result.candidate,:subject,subject)) do {:ok,result}
    else
      {:error,:none} -> {:error,%{code: :replan_provider_unavailable}}
      {:error,%{provider:id}=failure} -> step(subject,request,providers,ProviderSet.exclude(excluded,id),budget,attempt+1,Keyword.put(opts,:last_failure,failure))
      {:error,_}=e -> e
    end
  end
end