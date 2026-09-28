defmodule AshA2A.GallClosure.AuthorityCeiling do
  @moduledoc "Bounded GALL-029/030 guard for authority."
  def admit(%{authority: v}=s) when v not in [nil,false,""], do: {:ok, Map.put(s,:gall_guard,:authority_ceiling)}
  def admit(_), do: {:error,:authority_exceeded}
end
