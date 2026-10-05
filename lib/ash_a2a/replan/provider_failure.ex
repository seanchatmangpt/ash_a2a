# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.ProviderFailure do
  @enforce_keys [:provider, :reason, :attempt]
  defstruct [:provider, :reason, :attempt, :at]

  def new(p, r, a),
    do: %__MODULE__{provider: p, reason: r, attempt: a, at: System.monotonic_time()}
end
