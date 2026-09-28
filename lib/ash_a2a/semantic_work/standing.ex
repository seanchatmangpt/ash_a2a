defmodule AshA2A.SemanticWork.Standing do
  @moduledoc """
  Semantic-work Standing boundary with fail-closed identity.

  A missing standing is reported as `"UNKNOWN"`, which is evidence-only and
  never authority. Standing must be one of UNKNOWN/OBSERVED/CANDIDATE/ADMITTED
  (case-insensitive); the result carries the normalized upper-case value.
  """

  alias AshA2A.SemanticWork.Envelope

  @allowed ~w(UNKNOWN OBSERVED CANDIDATE ADMITTED)

  def bind(m) when is_map(m) do
    with {:ok, r} <- Envelope.fetch(m, [:subject]),
         {:ok, standing} <- validate_standing(raw_standing(m)) do
      {:ok, %{standing: standing, subject: r.subject, evidence: Map.get(m, :evidence, [])}}
    end
  end

  def bind(_), do: {:error, :refused_invalid_envelope}

  defp raw_standing(m) do
    case Map.get(m, :standing) do
      nil -> Map.get(m, "standing", "UNKNOWN")
      value -> value
    end
  end

  defp validate_standing(value) when is_binary(value) do
    normalized = String.upcase(value)

    if normalized in @allowed,
      do: {:ok, normalized},
      else: {:error, {:refused_invalid_standing, value}}
  end

  defp validate_standing(value), do: {:error, {:refused_invalid_standing, value}}
end
