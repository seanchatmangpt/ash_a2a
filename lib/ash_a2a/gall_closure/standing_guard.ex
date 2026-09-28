defmodule AshA2A.GallClosure.StandingGuard do
  @moduledoc "Bounded GALL-029/030 guard for standing."
  def admit(%{standing: v}=s) when v not in [nil,false,""], do: {:ok, Map.put(s,:gall_guard,:standing_guard)}
  def admit(_), do: {:error,:missing_standing}
end
