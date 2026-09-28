defmodule AshA2A.SemanticWork.CommandBoundary do
  @moduledoc "Semantic-work CommandBoundary boundary with fail-closed identity."

  alias AshA2A.SemanticWork.Envelope

  def bind(m) when is_map(m) do
    with {:ok, r} <- Envelope.fetch(m, [:command, :subject]) do
      {:ok, %{command: r.command, subject: r.subject, do_authority: false}}
    end
  end

  def bind(_), do: {:error, :refused_invalid_envelope}
end
