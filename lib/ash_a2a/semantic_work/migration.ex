defmodule AshA2A.SemanticWork.Migration do
  @moduledoc "Semantic-work Migration guard."

  alias AshA2A.SemanticWork.Envelope

  def bind(m) when is_map(m) do
    with {:ok, r} <- Envelope.fetch(m, [:from, :to, :subject]) do
      {:ok, %{from: r.from, to: r.to, subject: r.subject}}
    end
  end

  def bind(_), do: {:error, :refused_invalid_envelope}
end
