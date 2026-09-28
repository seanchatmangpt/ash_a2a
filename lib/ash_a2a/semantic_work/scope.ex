defmodule AshA2A.SemanticWork.Scope do
  @moduledoc "Semantic-work Scope guard."

  alias AshA2A.SemanticWork.Envelope

  def bind(m) when is_map(m) do
    with {:ok, r} <- Envelope.fetch(m, [:scope, :subject]) do
      {:ok, %{scope: r.scope, subject: r.subject, exact: true}}
    end
  end

  def bind(_), do: {:error, :refused_invalid_envelope}
end
