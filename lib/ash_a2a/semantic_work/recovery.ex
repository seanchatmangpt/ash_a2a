defmodule AshA2A.SemanticWork.Recovery do
  @moduledoc "Semantic-work Recovery boundary with fail-closed identity."

  alias AshA2A.SemanticWork.Envelope

  def bind(m) when is_map(m) do
    with {:ok, r} <- Envelope.fetch(m, [:failure, :subject, :route]) do
      {:ok, %{failure: r.failure, subject: r.subject, route: r.route}}
    end
  end

  def bind(_), do: {:error, :refused_invalid_envelope}
end
