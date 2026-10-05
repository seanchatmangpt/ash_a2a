# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Security.DLP.Luhn do
  @moduledoc """
  Luhn checksum validation for PCI-DSS PAN detection (FR-02.1/02.2).

  A digit run is only treated as a Primary Account Number when its Luhn
  checksum verifies, which keeps ordinary numbers (invoices, counts) from
  being pseudonymized by mistake.
  """

  @spec valid?(binary | charlist) :: boolean
  def valid?(digits) when is_binary(digits) do
    if String.valid?(digits) and digits != "" and Regex.match?(~r/^\d+$/, digits) do
      charlist = String.to_charlist(digits)
      initial_double? = rem(length(charlist), 2) == 0
      rem(reverse_sum(charlist, 0, initial_double?), 10) == 0
    else
      false
    end
  end

  def valid?(digits) when is_list(digits), do: digits |> List.to_string() |> valid?()

  # Standard Luhn: walking right-to-left, sum every digit; double every
  # second digit, subtracting 9 when doubling yields a two-digit number.
  # The charlist is left-to-right, so the initial doubling parity is derived
  # from the digit count.
  defp reverse_sum([], sum, _double?), do: sum

  defp reverse_sum([d | recursion], sum, double?) do
    d = d - ?0

    sum =
      if double? do
        doubled = d * 2
        sum + (if doubled > 9, do: doubled - 9, else: doubled)
      else
        sum + d
      end

    reverse_sum(recursion, sum, not double?)
  end
end
