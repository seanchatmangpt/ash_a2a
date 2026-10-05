# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.Provider do
  @callback propose(map(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback supports?(atom()) :: boolean()
end
