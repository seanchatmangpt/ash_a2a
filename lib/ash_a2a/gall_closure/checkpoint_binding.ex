defmodule AshA2A.GallClosure.CheckpointBinding do
  @moduledoc "Bounded GALL-029/030 guard for checkpoint."
  def admit(%{checkpoint: v}=s) when v not in [nil,false,""], do: {:ok, Map.put(s,:gall_guard,:checkpoint_binding)}
  def admit(_), do: {:error,:missing_checkpoint}
end
