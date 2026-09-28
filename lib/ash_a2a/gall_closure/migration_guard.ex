defmodule AshA2A.GallClosure.MigrationGuard do
  @moduledoc """
  Bounded GALL-029/030 guard for representation_version.

  Must be a non-empty (non-blank) binary or a positive integer.
  """
  def admit(%{representation_version: v} = s) do
    if valid_version?(v),
      do: {:ok, Map.put(s, :gall_guard, :migration_guard)},
      else: {:error, :missing_version}
  end

  def admit(_), do: {:error, :missing_version}

  defp valid_version?(v) when is_binary(v), do: String.trim(v) != ""
  defp valid_version?(v) when is_integer(v), do: v > 0
  defp valid_version?(_), do: false
end
