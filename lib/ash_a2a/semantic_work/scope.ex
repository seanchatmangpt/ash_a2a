defmodule AshA2A.SemanticWork.Scope do
  @moduledoc "Semantic-work Scope guard."
  def bind(m) when is_map(m) do
    try do
      {:ok, %{scope: req!(m, :scope), subject: req!(m, :subject), exact: true}}
    catch
      {:missing, k} -> {:error, {:refused_missing_identity, k}}
    end
  end

  def bind(_), do: {:error, :refused_invalid_envelope}
  defp req!(m, k), do: Map.get(m, k) || Map.get(m, to_string(k)) || throw({:missing, k})
end
