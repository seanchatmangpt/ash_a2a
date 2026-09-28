defmodule AshA2A.SemanticWork.Falsifier do
  @moduledoc "Semantic-work Falsifier boundary with fail-closed identity."
  def bind(m) when is_map(m) do
    try do
      {:ok,
       %{
         claim: req!(m, :claim),
         counterexample: req!(m, :counterexample),
         subject: req!(m, :subject)
       }}
    catch
      {:missing, k} -> {:error, {:refused_missing_identity, k}}
    end
  end

  def bind(_), do: {:error, :refused_invalid_envelope}
  defp req!(m, k), do: Map.get(m, k) || Map.get(m, to_string(k)) || throw({:missing, k})
end
