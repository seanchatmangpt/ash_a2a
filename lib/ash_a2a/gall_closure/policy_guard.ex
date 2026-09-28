defmodule AshA2A.GallClosure.PolicyGuard do
  @moduledoc "Bounded GALL-029/030 guard for policy_id."
  def admit(%{policy_id: v} = s) when v not in [nil, false, ""],
    do: {:ok, Map.put(s, :gall_guard, :policy_guard)}

  def admit(_), do: {:error, :missing_policy}
end
