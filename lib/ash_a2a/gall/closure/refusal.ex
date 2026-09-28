defmodule AshA2A.Gall.Closure.Refusal do
  @moduledoc "Normalizes GALL closure failures into stable, non-retry-inventing refusal records."

  def normalize({:refused_gall, boundary, reason}) do
    %{status: :refused, boundary: boundary, reason: reason, retry: false, standing: :refused}
  end

  def normalize({:error, {:refused_gall, boundary, reason}}),
    do: normalize({:refused_gall, boundary, reason})

  def normalize(reason),
    do: %{status: :refused, boundary: :unknown, reason: reason, retry: false, standing: :refused}
end
