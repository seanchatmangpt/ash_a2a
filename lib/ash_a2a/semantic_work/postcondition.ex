defmodule AshA2A.SemanticWork.Postcondition do
  @moduledoc "Semantic-work Postcondition boundary with fail-closed identity."
  def bind(m) when is_map(m) do
    try do
      {:ok,
       %{
         expected: req!(m, :expected),
         observed: Map.get(m, :observed),
         subject: req!(m, :subject)
       }}
    catch
      {:missing, k} -> {:error, {:refused_missing_identity, k}}
    end
  end

  def bind(_), do: {:error, :refused_invalid_envelope}
  defp req!(m, k), do: Map.get(m, k) || Map.get(m, to_string(k)) || throw({:missing, k})
end
