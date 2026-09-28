defmodule AshA2A.GallClosure.ReplayBinding do
  @moduledoc "Bounded GALL-029/030 guard for replay_id."
  def admit(%{replay_id: v}=s) when v not in [nil,false,""], do: {:ok, Map.put(s,:gall_guard,:replay_binding)}
  def admit(_), do: {:error,:missing_replay}
end
