defmodule AshA2A.Replan.Telemetry do
  @prefix [:ash_a2a,:replan]
  def emit(event,measurements,metadata), do: :telemetry.execute(@prefix ++ [event],measurements,metadata)
  def prefix, do: @prefix
end