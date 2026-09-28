defmodule AshA2A.SemanticWork.Consumer do
  @moduledoc "Semantic-work Consumer guard."

  alias AshA2A.SemanticWork.Envelope

  def bind(m) when is_map(m) do
    with {:ok, r} <- Envelope.fetch(m, [:consumer, :subject, :projection]) do
      {:ok, %{consumer: r.consumer, subject: r.subject, projection: r.projection}}
    end
  end

  def bind(_), do: {:error, :refused_invalid_envelope}
end
