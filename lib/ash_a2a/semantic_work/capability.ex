defmodule AshA2A.SemanticWork.Capability do
  @moduledoc "Semantic-work Capability guard."

  alias AshA2A.SemanticWork.Envelope

  def bind(m) when is_map(m) do
    with {:ok, r} <- Envelope.fetch(m, [:capability, :subject]) do
      {:ok, %{capability: r.capability, subject: r.subject, authority: "NONE"}}
    end
  end

  def bind(_), do: {:error, :refused_invalid_envelope}
end
