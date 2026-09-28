defmodule AshA2A.SemanticWork.OcelBinding do
 @moduledoc "Semantic-work OcelBinding boundary with fail-closed identity."
 def bind(m) when is_map(m) do
  try do {:ok, %{event: req!(m,:event), objects: req!(m,:objects), subject: req!(m,:subject)}} catch {:missing,k}->{:error,{:refused_missing_identity,k}} end
 end
 def bind(_), do: {:error,:refused_invalid_envelope}
 defp req!(m,k), do: Map.get(m,k)||Map.get(m,to_string(k))||throw({:missing,k})
end
