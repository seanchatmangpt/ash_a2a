defmodule AshA2A.Gall.Closure.Determinism do
  @moduledoc "Canonical deterministic identities for GALL-029/030 closure artifacts."

  def digest(value) do
    "sha256:" <>
      (:crypto.hash(:sha256, :erlang.term_to_binary(canonical(value), [:deterministic]))
       |> Base.encode16(case: :lower))
  end

  def canonical(map) when is_map(map) and not is_struct(map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), canonical(value)} end)
    |> Enum.sort()
  end

  def canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)
  def canonical(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> canonical()
  def canonical(value), do: value
end
