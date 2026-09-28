defmodule AshA2A.SemanticWork.Provenance do
  @moduledoc "Exact semantic-work Provenance boundary."

  alias AshA2A.SemanticWork.Envelope

  def bind(m) when is_map(m) do
    with {:ok, r} <- Envelope.fetch(m, [:source, :producer, :evidence_digest]) do
      {:ok, %{source: r.source, producer: r.producer, evidence_digest: r.evidence_digest}}
    end
  end

  def bind(_), do: {:error, :refused_invalid_envelope}
end
