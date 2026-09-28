defmodule AshA2A.SemanticWork.Refusal do
  @moduledoc "Semantic-work Refusal guard."

  alias AshA2A.SemanticWork.Envelope

  def bind(m) when is_map(m) do
    with {:ok, r} <- Envelope.fetch(m, [:code, :subject]) do
      {:ok, %{code: r.code, subject: r.subject, standing: "REFUSED"}}
    end
  end

  def bind(_), do: {:error, :refused_invalid_envelope}
end
