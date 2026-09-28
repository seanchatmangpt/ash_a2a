defmodule AshA2A.SemanticWork.Budget do
  @moduledoc "Semantic-work Budget guard."

  alias AshA2A.SemanticWork.Envelope

  def bind(m) when is_map(m) do
    with {:ok, r} <- Envelope.fetch(m, [:budget, :subject]),
         {:ok, budget} <- validate_budget(r.budget),
         {:ok, consumed} <- validate_consumed(fetch_optional(m, :consumed, 0), budget) do
      {:ok, %{budget: budget, subject: r.subject, consumed: consumed}}
    end
  end

  def bind(_), do: {:error, :refused_invalid_envelope}

  defp fetch_optional(m, key, default) do
    case Map.fetch(m, key) do
      {:ok, value} when not is_nil(value) -> value
      _ -> Map.get(m, to_string(key), default) || default
    end
  end

  defp validate_budget(b) when is_integer(b) and b >= 0, do: {:ok, b}
  defp validate_budget(b), do: {:error, {:refused_budget_exceeded, {:invalid_budget, b}}}

  defp validate_consumed(c, budget) when is_integer(c) and c >= 0 and c <= budget, do: {:ok, c}

  defp validate_consumed(c, budget) when is_integer(c) and c >= 0,
    do: {:error, {:refused_budget_exceeded, {:consumed, c, :budget, budget}}}

  defp validate_consumed(c, _budget),
    do: {:error, {:refused_budget_exceeded, {:invalid_consumed, c}}}
end
