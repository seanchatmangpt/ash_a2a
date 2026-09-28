defmodule AshA2A.SemanticWork.Lease do
  @moduledoc "Exact semantic-work Lease boundary."
  def bind(m) when is_map(m) do
    try do {:ok, %{lease_id: req!(m,:lease_id), subject: req!(m,:subject), expires_at: req!(m,:expires_at)}} catch {:missing,k} -> {:error,{:refused_missing_identity,k}} end
  end
  def bind(_), do: {:error,:refused_invalid_envelope}
  defp req!(m,k), do: Map.get(m,k) || Map.get(m,to_string(k)) || throw({:missing,k})
end
