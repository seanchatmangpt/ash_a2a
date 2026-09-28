defmodule AshA2A.GallClosure.CompatibilityGuard do
  @moduledoc "Bounded GALL-029/030 guard for compatibility."
  def admit(%{compatibility: v} = s) when v not in [nil, false, ""],
    do: {:ok, Map.put(s, :gall_guard, :compatibility_guard)}

  def admit(_), do: {:error, :missing_compatibility}
end
