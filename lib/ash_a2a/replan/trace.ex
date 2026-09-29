defmodule AshA2A.Replan.Trace do
  defstruct events: []
  def append(%__MODULE__{events:e}=t,event), do: %{t|events:[event|e]}
  def replay(%__MODULE__{events:e}), do: Enum.reverse(e)
end