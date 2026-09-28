defmodule AshA2A.SemanticWork.Migration do
 @moduledoc "Semantic-work Migration guard."
 def bind(m) when is_map(m) do
  try do {:ok, %{from: req!(m,:from), to: req!(m,:to), subject: req!(m,:subject)}} catch {:missing,k}->{:error,{:refused_missing_identity,k}} end
 end
 def bind(_), do: {:error,:refused_invalid_envelope}
 defp req!(m,k), do: Map.get(m,k)||Map.get(m,to_string(k))||throw({:missing,k})
end
