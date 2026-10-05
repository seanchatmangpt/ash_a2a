# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Security.DLP.Entropy do
  @moduledoc """
  Shannon entropy scoring for high-entropy API-key detection (FR-02.2).

  A candidate token is flagged when its per-character Shannon entropy meets
  the configured floor, which separates randomly-generated credentials from
  ordinary prose tokens of the same shape.
  """

  @doc """
  Per-character Shannon entropy of `binary`, in bits (0.0 .. 8.0).
  """
  @spec shannon_bits_per_char(binary) :: float
  def shannon_bits_per_char(binary) when is_binary(binary) do
    total = byte_size(binary)

    if total == 0 do
      0.0
    else
      freqs =
        for <<byte::8 <- binary>>, reduce: %{} do
          acc -> Map.update(acc, byte, 1, &(&1 + 1))
        end

      freqs
      |> Map.values()
      |> Enum.reduce(0.0, fn count, acc ->
        p = count / total
        acc - p * (:math.log2(p))
      end)
    end
  end

  @doc """
  True when `candidate` looks like a machine-issued secret: meets the
  entropy floor and is not a DLP pseudonym itself (so re-running the filter
  over an already-tokenized payload is idempotent).
  """
  @spec secret?(binary, number) :: boolean
  def secret?(candidate, entropy_floor) when is_binary(candidate) do
    not pseudonym?(candidate) and not String.match?(candidate, ~r/^\d+$/) and
      shannon_bits_per_char(candidate) >= entropy_floor
  end

  @doc """
  True for this filter's own pseudonym tokens (`dlt1_...`), which must never
  be re-tokenized.
  """
  @spec pseudonym?(binary) :: boolean
  def pseudonym?(binary), do: String.starts_with?(binary, AshA2A.Security.DLP.Pseudonym.prefix())
end
