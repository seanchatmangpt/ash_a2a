defmodule AshA2A.SemanticWork.Provider do
 @moduledoc "Semantic-work Provider guard."
 def bind(m) when is_map(m) do
  try do {:ok, %{provider: req!(m,:provider), subject: req!(m,:subject), contract: req!(m,:contract)}} catch {:missing,k}->{:error,{:refused_missing_identity,k}} end
 end
 def bind(_), do: {:error,:refused_invalid_envelope}
 defp req!(m,k), do: Map.get(m,k)||Map.get(m,to_string(k))||throw({:missing,k})
end
