defmodule AshA2A.SemanticWork.Idempotency do
  @moduledoc "Semantic-work Idempotency boundary with fail-closed identity."

  alias AshA2A.SemanticWork.Envelope

  def bind(m) when is_map(m) do
    with {:ok, r} <- Envelope.fetch(m, [:key, :subject]) do
      {:ok, %{key: r.key, subject: r.subject, consequence_budget: 1}}
    end
  end

  def bind(_), do: {:error, :refused_invalid_envelope}
end
