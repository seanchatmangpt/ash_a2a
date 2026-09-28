defmodule AshA2A.GallClosure.LeaseGuard do
  @moduledoc "Bounded GALL-029/030 guard for lease_epoch: must be a non-negative integer."
  def admit(%{lease_epoch: v} = s) when is_integer(v) and v >= 0,
    do: {:ok, Map.put(s, :gall_guard, :lease_guard)}

  def admit(_), do: {:error, :missing_lease}
end
