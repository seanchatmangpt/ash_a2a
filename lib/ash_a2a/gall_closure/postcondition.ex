defmodule AshA2A.GallClosure.Postcondition do
  @moduledoc "Bounded GALL-029/030 guard for postcondition."
  def admit(%{postcondition: v} = s) when v not in [nil, false, ""],
    do: {:ok, Map.put(s, :gall_guard, :postcondition)}

  def admit(_), do: {:error, :missing_postcondition}
end
