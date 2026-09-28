defmodule AshA2A.SemanticWork.Provider do
  @moduledoc "Semantic-work Provider guard."

  alias AshA2A.SemanticWork.Envelope

  def bind(m) when is_map(m) do
    with {:ok, r} <- Envelope.fetch(m, [:provider, :subject, :contract]) do
      {:ok, %{provider: r.provider, subject: r.subject, contract: r.contract}}
    end
  end

  def bind(_), do: {:error, :refused_invalid_envelope}
end
