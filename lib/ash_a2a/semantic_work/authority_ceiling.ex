defmodule AshA2A.SemanticWork.AuthorityCeiling do
  @moduledoc "Exact semantic-work AuthorityCeiling boundary."

  alias AshA2A.SemanticWork.Envelope

  def bind(m) when is_map(m) do
    with {:ok, r} <- Envelope.fetch(m, [:capability, :principal]) do
      {:ok, %{authority: "NONE", capability: r.capability, principal: r.principal}}
    end
  end

  def bind(_), do: {:error, :refused_invalid_envelope}
end
