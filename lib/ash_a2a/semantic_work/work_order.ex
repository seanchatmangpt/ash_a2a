defmodule AshA2A.SemanticWork.WorkOrder do
  @moduledoc "Exact semantic-work WorkOrder boundary."
  def bind(m) when is_map(m) do
    try do {:ok, %{work_order: req!(m,:work_order), subject: req!(m,:subject), acceptance: req!(m,:acceptance)}} catch {:missing,k} -> {:error,{:refused_missing_identity,k}} end
  end
  def bind(_), do: {:error,:refused_invalid_envelope}
  defp req!(m,k), do: Map.get(m,k) || Map.get(m,to_string(k)) || throw({:missing,k})
end
