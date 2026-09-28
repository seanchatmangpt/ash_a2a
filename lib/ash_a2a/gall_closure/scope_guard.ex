defmodule AshA2A.GallClosure.ScopeGuard do
  @moduledoc "Bounded GALL-029/030 guard for scope."
  def admit(%{scope: v} = s) when v not in [nil, false, ""],
    do: {:ok, Map.put(s, :gall_guard, :scope_guard)}

  def admit(_), do: {:error, :missing_scope}
end
