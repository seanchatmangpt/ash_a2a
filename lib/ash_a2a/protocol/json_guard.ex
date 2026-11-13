# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Protocol.JSONGuard do
  @moduledoc """
  Depth-capped JSON decoding for untrusted request bodies.

  `Jason.decode/1` has no nesting limit, so a megabyte of `[` is a cheap way to
  burn CPU and stack. `decode/2` first scans the raw bytes (string-aware) and
  refuses bodies nested deeper than `max_depth`, then decodes normally.
  """

  @default_max_depth 64

  @doc "Decodes `body`, refusing nesting deeper than `max_depth` (default #{@default_max_depth})."
  @spec decode(binary(), pos_integer()) ::
          {:ok, term()} | {:error, {:nesting_exceeded, pos_integer()} | Jason.DecodeError.t()}
  def decode(body, max_depth \\ @default_max_depth) when is_binary(body) do
    if within_depth?(body, max_depth),
      do: Jason.decode(body),
      else: {:error, {:nesting_exceeded, max_depth}}
  end

  @doc "True when the structural nesting of `body` never exceeds `max_depth`."
  @spec within_depth?(binary(), pos_integer()) :: boolean()
  def within_depth?(body, max_depth), do: scan(body, 0, max_depth, false)

  defp scan(<<>>, _depth, _max, _in_string), do: true

  defp scan(<<?\\, _escaped, rest::binary>>, depth, max, true), do: scan(rest, depth, max, true)

  defp scan(<<?", rest::binary>>, depth, max, in_string),
    do: scan(rest, depth, max, not in_string)

  defp scan(<<_, rest::binary>>, depth, max, true), do: scan(rest, depth, max, true)

  defp scan(<<c, rest::binary>>, depth, max, false) when c in [?[, ?{] do
    if depth + 1 > max, do: false, else: scan(rest, depth + 1, max, false)
  end

  defp scan(<<c, rest::binary>>, depth, max, false) when c in [?], ?}],
    do: scan(rest, max(depth - 1, 0), max, false)

  defp scan(<<_, rest::binary>>, depth, max, false), do: scan(rest, depth, max, false)
end
