defmodule AshA2A.SemanticWork.Compatibility do
  @moduledoc "Semantic-work Compatibility guard."

  alias AshA2A.SemanticWork.Envelope

  def bind(m) when is_map(m) do
    with {:ok, r} <- Envelope.fetch(m, [:version, :accepts, :subject]) do
      {:ok, %{version: r.version, accepts: r.accepts, subject: r.subject}}
    end
  end

  def bind(_), do: {:error, :refused_invalid_envelope}
end
