defmodule AshA2A.SemanticWork.Determinism do
 @moduledoc "Semantic-work Determinism boundary with fail-closed identity."
 def bind(m) when is_map(m) do
  try do {:ok, %{seed: req!(m,:seed), subject: req!(m,:subject), replay_key: req!(m,:replay_key)}} catch {:missing,k}->{:error,{:refused_missing_identity,k}} end
 end
 def bind(_), do: {:error,:refused_invalid_envelope}
 defp req!(m,k), do: Map.get(m,k)||Map.get(m,to_string(k))||throw({:missing,k})
end
