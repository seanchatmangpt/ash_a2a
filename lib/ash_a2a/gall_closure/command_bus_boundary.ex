defmodule AshA2A.GallClosure.CommandBusBoundary do
  @moduledoc "Bounded GALL-029/030 guard for command_bus."
  def admit(%{command_bus: v} = s) when v not in [nil, false, ""],
    do: {:ok, Map.put(s, :gall_guard, :command_bus_boundary)}

  def admit(_), do: {:error, :missing_command_bus}
end
