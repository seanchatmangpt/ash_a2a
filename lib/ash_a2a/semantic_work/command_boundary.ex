defmodule AshA2A.SemanticWork.CommandBoundary do
  @moduledoc "Semantic-work CommandBoundary boundary with fail-closed identity."
  def bind(m) when is_map(m) do
    try do
      {:ok, %{command: req!(m, :command), subject: req!(m, :subject), do_authority: false}}
    catch
      {:missing, k} -> {:error, {:refused_missing_identity, k}}
    end
  end

  def bind(_), do: {:error, :refused_invalid_envelope}
  defp req!(m, k), do: Map.get(m, k) || Map.get(m, to_string(k)) || throw({:missing, k})
end
