defmodule AshA2A.SemanticWork.Receipt do
  @moduledoc "Exact semantic-work Receipt boundary."

  alias AshA2A.SemanticWork.Envelope

  def bind(m) when is_map(m) do
    with {:ok, r} <- Envelope.fetch(m, [:receipt_id, :subject]) do
      {:ok,
       %{
         receipt_id: r.receipt_id,
         subject: r.subject,
         standing: Map.get(m, :standing, "CANDIDATE")
       }}
    end
  end

  def bind(_), do: {:error, :refused_invalid_envelope}
end
