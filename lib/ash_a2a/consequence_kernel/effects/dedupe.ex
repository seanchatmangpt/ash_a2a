# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.Effects.Dedupe do
  def edges(xs), do: Enum.uniq_by(xs, &AshA2A.ConsequenceKernel.Closure.EdgeIdentity.key/1)
end
