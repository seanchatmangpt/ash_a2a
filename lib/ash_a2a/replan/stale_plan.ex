defmodule AshA2A.Replan.StalePlan do
  def stale?(%{projection_digest: a}, %{projection_digest: b}) when is_binary(a) and is_binary(b), do: a != b
  def stale?(_, _), do: true
end