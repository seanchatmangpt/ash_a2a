defmodule AshA2A.SemanticWork.AuthorityCeiling do
  @moduledoc "Exact semantic-work AuthorityCeiling boundary."
  def bind(m) when is_map(m) do
    try do {:ok, %{authority: "NONE", capability: req!(m,:capability), principal: req!(m,:principal)}} catch {:missing,k} -> {:error,{:refused_missing_identity,k}} end
  end
  def bind(_), do: {:error,:refused_invalid_envelope}
  defp req!(m,k), do: Map.get(m,k) || Map.get(m,to_string(k)) || throw({:missing,k})
end
