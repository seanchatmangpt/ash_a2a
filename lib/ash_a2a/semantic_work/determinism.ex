defmodule AshA2A.SemanticWork.Determinism do
  @moduledoc "Semantic-work Determinism boundary with fail-closed identity."

  alias AshA2A.SemanticWork.Envelope

  def bind(m) when is_map(m) do
    with {:ok, r} <- Envelope.fetch(m, [:seed, :subject, :replay_key]) do
      {:ok, %{seed: r.seed, subject: r.subject, replay_key: r.replay_key}}
    end
  end

  def bind(_), do: {:error, :refused_invalid_envelope}
end
