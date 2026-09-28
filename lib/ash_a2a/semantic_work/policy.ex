defmodule AshA2A.SemanticWork.Policy do
 @moduledoc "Semantic-work Policy guard."
 def bind(m) when is_map(m) do
  try do {:ok, %{policy: req!(m,:policy), subject: req!(m,:subject), decision: Map.get(m,:decision,"UNKNOWN")}} catch {:missing,k}->{:error,{:refused_missing_identity,k}} end
 end
 def bind(_), do: {:error,:refused_invalid_envelope}
 defp req!(m,k), do: Map.get(m,k)||Map.get(m,to_string(k))||throw({:missing,k})
end
