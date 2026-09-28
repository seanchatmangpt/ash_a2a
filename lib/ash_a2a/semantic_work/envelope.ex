defmodule AshA2A.SemanticWork.Envelope do
  @moduledoc false
  # Internal helper shared by the semantic-work `bind/1` envelope modules.
  # nil, "" and false are treated as missing; atom or string keys are accepted.

  @type result :: {:ok, %{atom() => term()}} | {:error, {:refused_missing_identity, atom()}}

  @spec fetch(map(), [atom()]) :: result()
  def fetch(map, keys) when is_map(map) and is_list(keys) do
    Enum.reduce_while(keys, {:ok, %{}}, fn key, {:ok, acc} ->
      case get(map, key) do
        nil -> {:halt, {:error, {:refused_missing_identity, key}}}
        value -> {:cont, {:ok, Map.put(acc, key, value)}}
      end
    end)
  end

  defp get(map, key) do
    [Map.get(map, key), Map.get(map, to_string(key))]
    |> Enum.find(&present?/1)
  end

  defp present?(nil), do: false
  defp present?(false), do: false
  defp present?(""), do: false
  defp present?(_), do: true
end
