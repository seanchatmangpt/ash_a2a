defmodule AshA2A.GallClosure.RecoveryRoute do
  @moduledoc "Bounded GALL-029/030 guard for recovery."
  def admit(%{recovery: v}=s) when v not in [nil,false,""], do: {:ok, Map.put(s,:gall_guard,:recovery_route)}
  def admit(_), do: {:error,:missing_recovery}
end
