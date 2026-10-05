# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C2.ClaimStore do
  @callback claim(String.t(), non_neg_integer()) :: :ok | {:error, :already_claimed}
  @callback complete(String.t(), term()) :: :ok | {:error, term()}
end
