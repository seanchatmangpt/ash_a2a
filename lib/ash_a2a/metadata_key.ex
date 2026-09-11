defmodule AshA2A.MetadataKey do
  @moduledoc """
  Shared helper for looking up a value in a map by an atom key, falling back
  to the key's string form when the atom key isn't present.

  Consolidates the atom-or-string lookup pattern that was previously
  hand-rolled with three different orderings across `AshA2A.ContextResolver`,
  `AshA2A.Agent`, and `AshA2A.Dispatcher`.
  """

  @doc """
  Fetches `key` from `map`, trying the atom key first and falling back to
  `Atom.to_string(key)`. Returns `{:ok, value}` if either key is present,
  `:error` otherwise.
  """
  @spec fetch(map(), atom()) :: {:ok, term()} | :error
  def fetch(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(map, Atom.to_string(key))
    end
  end

  @doc """
  Same as `fetch/2`, but returns the value directly (or `default`, which
  defaults to `nil`, when neither key is present).
  """
  @spec get(map(), atom(), term()) :: term()
  def get(map, key, default \\ nil) when is_map(map) and is_atom(key) do
    case fetch(map, key) do
      {:ok, value} -> value
      :error -> default
    end
  end
end
