defmodule AshA2A.Chicago.Json do
  @moduledoc """
  JSON helpers for Chicago evidence: `safe/1` lowers arbitrary terms to
  JSON-encodable data (identity structs to their `:value`, other structs and
  opaque terms to `inspect/1` strings) so evidence can always be persisted;
  `canonical/1` encodes with recursively sorted object keys for content
  addressing.
  """

  @spec safe(term()) :: term()
  def safe(term) when is_binary(term) do
    if String.valid?(term), do: term, else: "base16:" <> Base.encode16(term, case: :lower)
  end

  def safe(term) when is_number(term) or is_boolean(term) or is_nil(term), do: term
  def safe(term) when is_atom(term), do: Atom.to_string(term)
  def safe(%AshA2A.Identity{value: value}), do: safe(value)
  def safe(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  def safe(term) when is_struct(term), do: inspect(term, limit: 50, printable_limit: 1024)
  def safe(term) when is_map(term), do: Map.new(term, fn {k, v} -> {key(k), safe(v)} end)
  def safe(term) when is_list(term), do: Enum.map(term, &safe/1)
  def safe(term) when is_tuple(term), do: term |> Tuple.to_list() |> safe()
  def safe(term), do: inspect(term)

  @spec canonical(term()) :: String.t()
  def canonical(term), do: term |> safe() |> encode_sorted() |> IO.iodata_to_binary()

  defp key(k) when is_binary(k), do: k
  defp key(k) when is_atom(k), do: Atom.to_string(k)
  defp key(k), do: inspect(k)

  # JSON objects with recursively sorted keys (objects stay objects).
  defp encode_sorted(map) when is_map(map) do
    pairs =
      map
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.map(fn {k, v} -> [JSON.encode!(k), ?:, encode_sorted(v)] end)
      |> Enum.intersperse(?,)

    [?{, pairs, ?}]
  end

  defp encode_sorted(list) when is_list(list),
    do: [?[, list |> Enum.map(&encode_sorted/1) |> Enum.intersperse(?,), ?]]

  defp encode_sorted(other), do: JSON.encode!(other)
end
