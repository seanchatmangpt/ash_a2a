defmodule AshA2A.SemanticWork.Receipt do
  @moduledoc "Exact semantic-work Receipt boundary."
  def bind(m) when is_map(m) do
    try do
      {:ok,
       %{
         receipt_id: req!(m, :receipt_id),
         subject: req!(m, :subject),
         standing: Map.get(m, :standing, "CANDIDATE")
       }}
    catch
      {:missing, k} -> {:error, {:refused_missing_identity, k}}
    end
  end

  def bind(_), do: {:error, :refused_invalid_envelope}
  defp req!(m, k), do: Map.get(m, k) || Map.get(m, to_string(k)) || throw({:missing, k})
end
