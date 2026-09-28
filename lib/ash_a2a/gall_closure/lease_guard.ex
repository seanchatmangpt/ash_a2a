defmodule AshA2A.GallClosure.LeaseGuard do
  @moduledoc "Bounded GALL-029/030 guard for lease_epoch."
  def admit(%{lease_epoch: v} = s) when v not in [nil, false, ""],
    do: {:ok, Map.put(s, :gall_guard, :lease_guard)}

  def admit(_), do: {:error, :missing_lease}
end
