defmodule AshA2A.SemanticWork.Replay do
  @moduledoc "Exact semantic-work Replay boundary."

  alias AshA2A.SemanticWork.Envelope

  def bind(m) when is_map(m) do
    with {:ok, r} <- Envelope.fetch(m, [:receipt_id, :replay_key]) do
      {:ok, %{receipt_id: r.receipt_id, replay_key: r.replay_key, consequence_budget: 0}}
    end
  end

  def bind(_), do: {:error, :refused_invalid_envelope}
end
