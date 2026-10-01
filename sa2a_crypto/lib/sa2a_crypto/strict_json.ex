defmodule Sa2aCrypto.StrictJson do
  @moduledoc """
  Strict JSON decode for every wire/file path sa2a_crypto owns.

  Refuses duplicate object keys at any depth (`{:error, :duplicate_key}`) and, with
  `canonical: true` (default), any input whose bytes are not exactly the JCS (RFC 8785)
  encoding of what it decodes to (`{:error, :non_canonical}`). Plain `Jason.decode/1` keeps
  the last duplicate silently, so two parsers can disagree about one byte string.
  """

  @spec decode(binary(), keyword()) ::
          {:ok, term()} | {:error, :malformed_json | :duplicate_key | :non_canonical}
  def decode(bin, opts \\ [])

  def decode(bin, opts) when is_binary(bin) do
    with {:ok, ordered} <- parse(bin),
         {:ok, term} <- unordered(ordered),
         :ok <- canonical(term, bin, Keyword.get(opts, :canonical, true)) do
      {:ok, term}
    end
  end

  def decode(_, _), do: {:error, :malformed_json}

  defp parse(bin) do
    case Jason.decode(bin, objects: :ordered_objects) do
      {:ok, t} -> {:ok, t}
      _ -> {:error, :malformed_json}
    end
  end

  defp unordered(%Jason.OrderedObject{values: pairs}) do
    keys = Enum.map(pairs, &elem(&1, 0))

    if length(keys) != length(Enum.uniq(keys)) do
      {:error, :duplicate_key}
    else
      pairs
      |> Enum.reduce_while({:ok, %{}}, fn {k, v}, {:ok, acc} ->
        case unordered(v) do
          {:ok, x} -> {:cont, {:ok, Map.put(acc, k, x)}}
          e -> {:halt, e}
        end
      end)
    end
  end

  defp unordered(list) when is_list(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn v, {:ok, acc} ->
      case unordered(v) do
        {:ok, x} -> {:cont, {:ok, [x | acc]}}
        e -> {:halt, e}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      e -> e
    end
  end

  defp unordered(v), do: {:ok, v}

  defp canonical(_, _, false), do: :ok

  defp canonical(term, bin, true) do
    if Jcs.encode(term) == bin, do: :ok, else: {:error, :non_canonical}
  rescue
    _ -> {:error, :non_canonical}
  end
end
