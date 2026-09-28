defmodule AshA2A.GallClosure.FindingBinding do
  @moduledoc "Bounded GALL-029/030 guard for finding_id."
  def admit(%{finding_id: v}=s) when v not in [nil,false,""], do: {:ok, Map.put(s,:gall_guard,:finding_binding)}
  def admit(_), do: {:error,:missing_finding}
end
