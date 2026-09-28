defmodule AshA2A.SemanticWork.Policy do
  @moduledoc "Semantic-work Policy guard."

  alias AshA2A.SemanticWork.Envelope

  def bind(m) when is_map(m) do
    with {:ok, r} <- Envelope.fetch(m, [:policy, :subject]) do
      {:ok, %{policy: r.policy, subject: r.subject, decision: Map.get(m, :decision, "UNKNOWN")}}
    end
  end

  def bind(_), do: {:error, :refused_invalid_envelope}
end
