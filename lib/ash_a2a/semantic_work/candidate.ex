defmodule AshA2A.SemanticWork.Candidate do
  @moduledoc "Semantic-work Candidate boundary with fail-closed identity."

  alias AshA2A.SemanticWork.Envelope

  def bind(m) when is_map(m) do
    with {:ok, r} <- Envelope.fetch(m, [:candidate, :subject]) do
      {:ok, %{candidate: r.candidate, subject: r.subject, standing: "CANDIDATE"}}
    end
  end

  def bind(_), do: {:error, :refused_invalid_envelope}
end
