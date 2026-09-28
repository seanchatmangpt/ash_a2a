defmodule AshA2A.SemanticWork.GraphIdentity do
  @moduledoc "Exact semantic-work GraphIdentity boundary."
  def bind(m) when is_map(m) do
    try do {:ok, %{graph_digest: req!(m,:graph_digest), algorithm: Map.get(m,:algorithm,"sha256")}} catch {:missing,k} -> {:error,{:refused_missing_identity,k}} end
  end
  def bind(_), do: {:error,:refused_invalid_envelope}
  defp req!(m,k), do: Map.get(m,k) || Map.get(m,to_string(k)) || throw({:missing,k})
end
