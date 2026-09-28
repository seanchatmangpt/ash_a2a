defmodule AshA2A.SemanticWork.Admission do
  @moduledoc "Semantic-work Admission boundary with fail-closed identity."

  alias AshA2A.SemanticWork.Envelope

  def bind(m) when is_map(m) do
    with {:ok, r} <- Envelope.fetch(m, [:admission, :subject]) do
      {:ok,
       %{admission: r.admission, subject: r.subject, authority: Map.get(m, :authority, "NONE")}}
    end
  end

  def bind(_), do: {:error, :refused_invalid_envelope}
end
