# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Effector do
  @callback apply(AshA2A.PreparedEffect.t()) ::
              {:ok, term()} | {:unknown, term()} | {:error, term()}
end
