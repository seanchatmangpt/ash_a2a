defmodule AshA2A.SemanticWork.Lease do
  @moduledoc "Exact semantic-work Lease boundary."

  alias AshA2A.SemanticWork.Envelope

  def bind(m) when is_map(m) do
    with {:ok, r} <- Envelope.fetch(m, [:lease_id, :subject, :expires_at]),
         :ok <- validate_expires_at(r.expires_at) do
      {:ok, %{lease_id: r.lease_id, subject: r.subject, expires_at: r.expires_at}}
    end
  end

  def bind(_), do: {:error, :refused_invalid_envelope}

  defp validate_expires_at(v) when is_integer(v), do: :ok
  defp validate_expires_at(%DateTime{}), do: :ok
  defp validate_expires_at(_), do: {:error, {:refused_invalid_lease, :expires_at}}
end
