defmodule AshA2A.GallClosure.CommandIdentity do
  @moduledoc "Bounded GALL-029/030 guard for command_id."
  def admit(%{command_id: v}=s) when v not in [nil,false,""], do: {:ok, Map.put(s,:gall_guard,:command_identity)}
  def admit(_), do: {:error,:missing_command}
end
