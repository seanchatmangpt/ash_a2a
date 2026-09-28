defmodule AshA2A.SemanticWork.Postcondition do
  @moduledoc "Semantic-work Postcondition boundary with fail-closed identity."

  alias AshA2A.SemanticWork.Envelope

  def bind(m) when is_map(m) do
    with {:ok, r} <- Envelope.fetch(m, [:expected, :subject]) do
      {:ok, %{expected: r.expected, observed: Map.get(m, :observed), subject: r.subject}}
    end
  end

  def bind(_), do: {:error, :refused_invalid_envelope}
end
