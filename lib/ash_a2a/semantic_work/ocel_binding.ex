defmodule AshA2A.SemanticWork.OcelBinding do
  @moduledoc "Semantic-work OcelBinding boundary with fail-closed identity."

  alias AshA2A.SemanticWork.Envelope

  def bind(m) when is_map(m) do
    with {:ok, r} <- Envelope.fetch(m, [:event, :objects, :subject]) do
      {:ok, %{event: r.event, objects: r.objects, subject: r.subject}}
    end
  end

  def bind(_), do: {:error, :refused_invalid_envelope}
end
