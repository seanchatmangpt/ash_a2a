defmodule AshA2A.SemanticWork.Standing do
  @moduledoc "Semantic-work Standing boundary with fail-closed identity."
  def bind(m) when is_map(m) do
    try do
      {:ok,
       %{
         standing: Map.get(m, :standing, "UNKNOWN"),
         subject: req!(m, :subject),
         evidence: Map.get(m, :evidence, [])
       }}
    catch
      {:missing, k} -> {:error, {:refused_missing_identity, k}}
    end
  end

  def bind(_), do: {:error, :refused_invalid_envelope}
  defp req!(m, k), do: Map.get(m, k) || Map.get(m, to_string(k)) || throw({:missing, k})
end
