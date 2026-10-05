# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C2.Effector do
  @callback perform(AshA2A.C2.PreparedEffect.t()) :: {:ok, term()} | {:error, term()}
end
