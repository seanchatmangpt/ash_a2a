defmodule AshA2A.SemanticWork.SourceIdentity do
  @moduledoc "Exact semantic-work SourceIdentity boundary."
  def bind(m) when is_map(m) do
    try do
      {:ok,
       %{
         repository: req!(m, :repository),
         base_sha: req!(m, :base_sha),
         source_sha: req!(m, :source_sha)
       }}
    catch
      {:missing, k} -> {:error, {:refused_missing_identity, k}}
    end
  end

  def bind(_), do: {:error, :refused_invalid_envelope}
  defp req!(m, k), do: Map.get(m, k) || Map.get(m, to_string(k)) || throw({:missing, k})
end
