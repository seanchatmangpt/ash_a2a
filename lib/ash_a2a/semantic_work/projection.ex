defmodule AshA2A.SemanticWork.Projection do
  @moduledoc "Semantic-work Projection guard."
  def bind(m) when is_map(m) do
    try do
      {:ok,
       %{
         projection: req!(m, :projection),
         source_subject: req!(m, :source_subject),
         derived: true
       }}
    catch
      {:missing, k} -> {:error, {:refused_missing_identity, k}}
    end
  end

  def bind(_), do: {:error, :refused_invalid_envelope}
  defp req!(m, k), do: Map.get(m, k) || Map.get(m, to_string(k)) || throw({:missing, k})
end
