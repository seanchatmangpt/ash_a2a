# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Gall.Closure.Determinism do
  @moduledoc """
  Canonical deterministic identities for GALL-029/030 closure artifacts.

  Canonical form is injective over the type distinctions that matter: tuples are
  tagged (`{:tuple, [...]}`) so `{:a, 1}` and `[:a, 1]` differ; maps are encoded as
  `{:map, entries}` where each entry is `[key_type_tag, key, value]`, sorted, so
  `%{a: 1}` and `%{"a" => 1}` differ while insertion order is irrelevant.
  Digest format is `"sha256:<hex>"`.
  """

  def digest(value) do
    "sha256:" <>
      (:crypto.hash(:sha256, :erlang.term_to_binary(canonical(value), [:deterministic]))
       |> Base.encode16(case: :lower))
  end

  def canonical(map) when is_map(map) and not is_struct(map) do
    entries =
      map
      |> Enum.map(fn {key, value} -> [key_tag(key), canonical(key), canonical(value)] end)
      |> Enum.sort()

    {:map, entries}
  end

  def canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)

  def canonical(tuple) when is_tuple(tuple),
    do: {:tuple, tuple |> Tuple.to_list() |> Enum.map(&canonical/1)}

  def canonical(value), do: value

  defp key_tag(key) when is_atom(key), do: :atom
  defp key_tag(key) when is_binary(key), do: :string
  defp key_tag(key) when is_integer(key), do: :integer
  defp key_tag(key) when is_float(key), do: :float
  defp key_tag(key) when is_tuple(key), do: :tuple
  defp key_tag(key) when is_list(key), do: :list
  defp key_tag(key) when is_map(key), do: :map
  defp key_tag(_key), do: :other
end
