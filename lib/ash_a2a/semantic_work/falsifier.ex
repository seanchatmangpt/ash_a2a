defmodule AshA2A.SemanticWork.Falsifier do
  @moduledoc "Semantic-work Falsifier boundary with fail-closed identity."

  alias AshA2A.SemanticWork.Envelope

  def bind(m) when is_map(m) do
    with {:ok, r} <- Envelope.fetch(m, [:claim, :counterexample, :subject]) do
      {:ok, %{claim: r.claim, counterexample: r.counterexample, subject: r.subject}}
    end
  end

  def bind(_), do: {:error, :refused_invalid_envelope}
end
