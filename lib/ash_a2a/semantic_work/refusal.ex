defmodule AshA2A.SemanticWork.Refusal do
  @moduledoc "Semantic-work Refusal guard."
  def bind(m) when is_map(m) do
    try do
      {:ok, %{code: req!(m, :code), subject: req!(m, :subject), standing: "REFUSED"}}
    catch
      {:missing, k} -> {:error, {:refused_missing_identity, k}}
    end
  end

  def bind(_), do: {:error, :refused_invalid_envelope}
  defp req!(m, k), do: Map.get(m, k) || Map.get(m, to_string(k)) || throw({:missing, k})
end
