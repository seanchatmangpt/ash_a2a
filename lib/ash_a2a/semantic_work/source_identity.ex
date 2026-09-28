defmodule AshA2A.SemanticWork.SourceIdentity do
  @moduledoc "Exact semantic-work SourceIdentity boundary."

  alias AshA2A.SemanticWork.Envelope

  def bind(m) when is_map(m) do
    with {:ok, r} <- Envelope.fetch(m, [:repository, :base_sha, :source_sha]) do
      {:ok, %{repository: r.repository, base_sha: r.base_sha, source_sha: r.source_sha}}
    end
  end

  def bind(_), do: {:error, :refused_invalid_envelope}
end
