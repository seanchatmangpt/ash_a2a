defmodule AshA2A.SemanticWork.ExactSubject do
  @moduledoc "Exact semantic-work ExactSubject boundary."

  alias AshA2A.SemanticWork.Envelope

  def bind(m) when is_map(m) do
    with {:ok, r} <- Envelope.fetch(m, [:work_order, :checkpoint, :graph_digest]) do
      {:ok, %{work_order: r.work_order, checkpoint: r.checkpoint, graph_digest: r.graph_digest}}
    end
  end

  def bind(_), do: {:error, :refused_invalid_envelope}
end
