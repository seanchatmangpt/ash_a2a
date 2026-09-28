defmodule AshA2A.SemanticWork.WorkOrder do
  @moduledoc "Exact semantic-work WorkOrder boundary."

  alias AshA2A.SemanticWork.Envelope

  def bind(m) when is_map(m) do
    with {:ok, r} <- Envelope.fetch(m, [:work_order, :subject, :acceptance]) do
      {:ok, %{work_order: r.work_order, subject: r.subject, acceptance: r.acceptance}}
    end
  end

  def bind(_), do: {:error, :refused_invalid_envelope}
end
