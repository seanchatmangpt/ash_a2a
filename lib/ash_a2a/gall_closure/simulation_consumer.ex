defmodule AshA2A.GallClosure.SimulationConsumer do
  @moduledoc "Bounded GALL-029/030 guard for simulation_consumer."
  def admit(%{simulation_consumer: v} = s) when v not in [nil, false, ""],
    do: {:ok, Map.put(s, :gall_guard, :simulation_consumer)}

  def admit(_), do: {:error, :missing_simulation_consumer}
end
