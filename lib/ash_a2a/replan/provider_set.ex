defmodule AshA2A.Replan.ProviderSet do
  def select(providers, formalism, excluded \\ MapSet.new()) do
    Enum.find(providers, fn {id,mod} -> not MapSet.member?(excluded,id) and function_exported?(mod,:supports?,1) and mod.supports?(formalism) end)
  end
  def exclude(set,id), do: MapSet.put(set,id)
end