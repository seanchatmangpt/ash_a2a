defmodule AshA2A.GallClosure.ObservationGuard do
  @moduledoc "Bounded GALL-029/030 guard for observation_id."
  def admit(%{observation_id: v} = s) when v not in [nil, false, ""],
    do: {:ok, Map.put(s, :gall_guard, :observation_guard)}

  def admit(_), do: {:error, :missing_observation}
end
