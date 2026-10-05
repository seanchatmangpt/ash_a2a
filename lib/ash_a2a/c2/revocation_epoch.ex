# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C2.RevocationEpoch do
  def valid?(cert, current) when is_integer(current), do: cert.revocation_epoch == current
end
