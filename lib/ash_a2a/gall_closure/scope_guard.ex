defmodule AshA2A.GallClosure.ScopeGuard do
  @moduledoc """
  Bounded GALL-029/030 guard for scope.

  Scope must be a non-empty binary, atom (not nil/booleans), non-empty list or
  non-empty map. Wildcard scopes ("*", "all", :all, :"*", also as list members)
  are refused with `:scope_escape`; absent or malformed scopes with `:missing_scope`.
  """
  @wildcards ["*", "all"]

  def admit(%{scope: v} = s) do
    case classify(v) do
      :ok -> {:ok, Map.put(s, :gall_guard, :scope_guard)}
      error -> {:error, error}
    end
  end

  def admit(_), do: {:error, :missing_scope}

  defp classify(v) when is_binary(v) do
    trimmed = String.trim(v)

    cond do
      trimmed == "" -> :missing_scope
      String.downcase(trimmed) in @wildcards -> :scope_escape
      true -> :ok
    end
  end

  defp classify(v) when v in [nil, true, false], do: :missing_scope

  defp classify(v) when is_atom(v) do
    if Atom.to_string(v) in @wildcards, do: :scope_escape, else: :ok
  end

  defp classify([]), do: :missing_scope

  defp classify(v) when is_list(v) do
    if Enum.any?(v, &(classify(&1) == :scope_escape)), do: :scope_escape, else: :ok
  end

  defp classify(v) when is_map(v), do: if(map_size(v) == 0, do: :missing_scope, else: :ok)
  defp classify(_), do: :missing_scope
end
