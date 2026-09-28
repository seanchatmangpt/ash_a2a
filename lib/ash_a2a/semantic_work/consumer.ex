defmodule AshA2A.SemanticWork.Consumer do
 @moduledoc "Semantic-work Consumer guard."
 def bind(m) when is_map(m) do
  try do {:ok, %{consumer: req!(m,:consumer), subject: req!(m,:subject), projection: req!(m,:projection)}} catch {:missing,k}->{:error,{:refused_missing_identity,k}} end
 end
 def bind(_), do: {:error,:refused_invalid_envelope}
 defp req!(m,k), do: Map.get(m,k)||Map.get(m,to_string(k))||throw({:missing,k})
end
