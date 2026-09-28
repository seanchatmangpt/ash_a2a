defmodule AshA2A.SemanticWork.Replay do
  @moduledoc "Exact semantic-work Replay boundary."
  def bind(m) when is_map(m) do
    try do {:ok, %{receipt_id: req!(m,:receipt_id), replay_key: req!(m,:replay_key), consequence_budget: 0}} catch {:missing,k} -> {:error,{:refused_missing_identity,k}} end
  end
  def bind(_), do: {:error,:refused_invalid_envelope}
  defp req!(m,k), do: Map.get(m,k) || Map.get(m,to_string(k)) || throw({:missing,k})
end
