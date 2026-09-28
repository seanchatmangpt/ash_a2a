defmodule AshA2A.SemanticWork.Idempotency do
 @moduledoc "Semantic-work Idempotency boundary with fail-closed identity."
 def bind(m) when is_map(m) do
  try do {:ok, %{key: req!(m,:key), subject: req!(m,:subject), consequence_budget: 1}} catch {:missing,k}->{:error,{:refused_missing_identity,k}} end
 end
 def bind(_), do: {:error,:refused_invalid_envelope}
 defp req!(m,k), do: Map.get(m,k)||Map.get(m,to_string(k))||throw({:missing,k})
end
