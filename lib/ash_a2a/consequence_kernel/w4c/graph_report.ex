# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.W4C.GraphReport do
  alias AshA2A.ConsequenceKernel.W4C.GraphEdge
  def normalize(edges) when is_list(edges), do: Enum.map(edges, &normalize_edge/1)
  defp normalize_edge(%GraphEdge{} = e), do: e

  defp normalize_edge(%{caller: c, callee: d, kind: k} = e),
    do: %GraphEdge{caller: c, callee: d, kind: k, source: Map.get(e, :source)}
end
