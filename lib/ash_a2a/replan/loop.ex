defmodule AshA2A.Replan.Loop do
  alias AshA2A.Replan.{AttemptBudget, ProviderResult, ProviderSet, ReplayKey, SubjectLineage}

  def run(subject, request, providers, opts \\ []) do
    budget = AttemptBudget.new(Keyword.get(opts, :max_attempts, 3))
    step(subject, request, providers, MapSet.new(), budget, 0, opts)
  end

  defp step(subject, request, providers, excluded, budget, attempt, opts) do
    case AttemptBudget.consume(budget) do
      {:error, _} = error ->
        error

      {:ok, next_budget} ->
        case ProviderSet.select(providers, Map.get(request, :formalism, :hddl), excluded) do
          nil ->
            {:error, %{code: :replan_provider_unavailable, excluded: ordered(excluded)}}

          {id, mod} ->
            request = Map.put(request, :subject, subject)

            case ProviderResult.normalize(mod.propose(request, opts), id) do
              {:ok, result} ->
                with :ok <- SubjectLineage.guard(subject, Map.get(result.candidate, :subject, subject)) do
                  {:ok,
                   result
                   |> Map.put(:attempt, attempt)
                   |> Map.put(:excluded, ordered(excluded))
                   |> Map.put(:replay_key, ReplayKey.build(subject, id, attempt))}
                end

              {:error, %{provider: ^id} = failure} ->
                step(
                  subject,
                  request,
                  providers,
                  ProviderSet.exclude(excluded, id),
                  next_budget,
                  attempt + 1,
                  Keyword.put(opts, :last_failure, failure)
                )

              {:error, _} = error ->
                error
            end
        end
    end
  end

  defp ordered(excluded), do: excluded |> MapSet.to_list() |> Enum.sort()
end
