defmodule AshA2A.SemanticWork.Admission do
 @moduledoc "Semantic-work Admission boundary with fail-closed identity."
 def bind(m) when is_map(m) do
  try do {:ok, %{admission: req!(m,:admission), subject: req!(m,:subject), authority: Map.get(m,:authority,"NONE")}} catch {:missing,k}->{:error,{:refused_missing_identity,k}} end
 end
 def bind(_), do: {:error,:refused_invalid_envelope}
 defp req!(m,k), do: Map.get(m,k)||Map.get(m,to_string(k))||throw({:missing,k})
end
