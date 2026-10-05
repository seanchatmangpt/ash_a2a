# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.W4C.RawEffectEdges do
  alias AshA2A.ConsequenceKernel.W4C.{GraphEdge, GraphReport}

  def from_report(edges) do
    edges
    |> GraphReport.normalize()
    |> Enum.filter(&GraphEdge.consequential?/1)
    |> Enum.reject(fn edge ->
      String.starts_with?(to_string(edge.caller), "Elixir.AshA2A.ConsequenceKernel")
    end)
  end
end
