defmodule AshA2A.SemanticWork.Recovery do
 @moduledoc "Semantic-work Recovery boundary with fail-closed identity."
 def bind(m) when is_map(m) do
  try do {:ok, %{failure: req!(m,:failure), subject: req!(m,:subject), route: req!(m,:route)}} catch {:missing,k}->{:error,{:refused_missing_identity,k}} end
 end
 def bind(_), do: {:error,:refused_invalid_envelope}
 defp req!(m,k), do: Map.get(m,k)||Map.get(m,to_string(k))||throw({:missing,k})
end
