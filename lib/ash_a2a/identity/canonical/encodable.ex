# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Identity.Canonical.Encodable do
  @moduledoc false
  @max_depth 32
  @max_bytes 1_048_576
  @max_int 9_007_199_254_740_991

  @doc "Size cap (bytes) applied to canonical output before hashing (RFC-007 E-F)."
  def max_bytes, do: @max_bytes
  def validate(value), do: validate(value, 0)
  defp validate(_, d) when d > @max_depth, do: {:error, :canonical_depth_exceeded}

  defp validate(v, _) when is_integer(v) and abs(v) > @max_int,
    do: {:error, :canonical_integer_out_of_range}

  defp validate(v, _) when is_nil(v) or is_boolean(v) or is_integer(v), do: :ok

  defp validate(v, _) when is_binary(v),
    do: if(String.valid?(v), do: :ok, else: {:error, :canonical_invalid_utf8})

  defp validate(v, _) when is_float(v), do: {:error, :canonical_float_forbidden}
  defp validate(v, d) when is_list(v), do: reduce(v, d + 1)
  defp validate(v, d) when is_map(v), do: with(:ok <- keys(v), do: reduce(Map.values(v), d + 1))
  defp validate(_, _), do: {:error, :canonical_type_forbidden}

  defp reduce(xs, d),
    do:
      Enum.reduce_while(xs, :ok, fn x, :ok ->
        case validate(x, d) do
          :ok -> {:cont, :ok}
          e -> {:halt, e}
        end
      end)

  defp keys(m) do
    ks = Map.keys(m)
    names = Enum.map(ks, &to_string/1)

    cond do
      Enum.any?(ks, &(not (is_binary(&1) or is_atom(&1)))) ->
        {:error, :canonical_key_type_forbidden}

      length(names) != length(Enum.uniq(names)) ->
        {:error, :canonical_key_collision}

      true ->
        :ok
    end
  end
end
