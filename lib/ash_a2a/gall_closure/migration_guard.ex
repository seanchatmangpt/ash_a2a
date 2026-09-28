defmodule AshA2A.GallClosure.MigrationGuard do
  @moduledoc "Bounded GALL-029/030 guard for representation_version."
  def admit(%{representation_version: v}=s) when v not in [nil,false,""], do: {:ok, Map.put(s,:gall_guard,:migration_guard)}
  def admit(_), do: {:error,:missing_version}
end
