defmodule AshA2A.GallClosure.Falsifier do
  @moduledoc "Bounded GALL-029/030 guard for falsifier."
  def admit(%{falsifier: v} = s) when v not in [nil, false, ""],
    do: {:ok, Map.put(s, :gall_guard, :falsifier)}

  def admit(_), do: {:error, :missing_falsifier}
end
