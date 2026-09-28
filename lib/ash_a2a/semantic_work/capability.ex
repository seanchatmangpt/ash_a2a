defmodule AshA2A.SemanticWork.Capability do
 @moduledoc "Semantic-work Capability guard."
 def bind(m) when is_map(m) do
  try do {:ok, %{capability: req!(m,:capability), subject: req!(m,:subject), authority: "NONE"}} catch {:missing,k}->{:error,{:refused_missing_identity,k}} end
 end
 def bind(_), do: {:error,:refused_invalid_envelope}
 defp req!(m,k), do: Map.get(m,k)||Map.get(m,to_string(k))||throw({:missing,k})
end
