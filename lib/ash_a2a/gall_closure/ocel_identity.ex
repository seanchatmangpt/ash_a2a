defmodule AshA2A.GallClosure.OcelIdentity do
  @moduledoc "Bounded GALL-029/030 guard for ocel_event_id."
  def admit(%{ocel_event_id: v} = s) when v not in [nil, false, ""],
    do: {:ok, Map.put(s, :gall_guard, :ocel_identity)}

  def admit(_), do: {:error, :missing_ocel_event}
end
