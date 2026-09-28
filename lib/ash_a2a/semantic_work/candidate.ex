defmodule AshA2A.SemanticWork.Candidate do
  @moduledoc "Semantic-work Candidate boundary with fail-closed identity."
  def bind(m) when is_map(m) do
    try do
      {:ok, %{candidate: req!(m, :candidate), subject: req!(m, :subject), standing: "CANDIDATE"}}
    catch
      {:missing, k} -> {:error, {:refused_missing_identity, k}}
    end
  end

  def bind(_), do: {:error, :refused_invalid_envelope}
  defp req!(m, k), do: Map.get(m, k) || Map.get(m, to_string(k)) || throw({:missing, k})
end
