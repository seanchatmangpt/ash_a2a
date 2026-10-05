# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.W4C.ZeroEdgeGuard do
  def admit([]), do: :ok
  def admit(edges), do: {:error, {:raw_effect_edges, length(edges)}}
end
