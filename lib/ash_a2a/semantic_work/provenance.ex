defmodule AshA2A.SemanticWork.Provenance do
  @moduledoc "Exact semantic-work Provenance boundary."
  def bind(m) when is_map(m) do
    try do {:ok, %{source: req!(m,:source), producer: req!(m,:producer), evidence_digest: req!(m,:evidence_digest)}} catch {:missing,k} -> {:error,{:refused_missing_identity,k}} end
  end
  def bind(_), do: {:error,:refused_invalid_envelope}
  defp req!(m,k), do: Map.get(m,k) || Map.get(m,to_string(k)) || throw({:missing,k})
end
