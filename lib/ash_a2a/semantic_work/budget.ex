defmodule AshA2A.SemanticWork.Budget do
  @moduledoc "Semantic-work Budget guard."
  def bind(m) when is_map(m) do
    try do
      {:ok,
       %{budget: req!(m, :budget), subject: req!(m, :subject), consumed: Map.get(m, :consumed, 0)}}
    catch
      {:missing, k} -> {:error, {:refused_missing_identity, k}}
    end
  end

  def bind(_), do: {:error, :refused_invalid_envelope}
  defp req!(m, k), do: Map.get(m, k) || Map.get(m, to_string(k)) || throw({:missing, k})
end
