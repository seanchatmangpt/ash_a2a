# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.W4C.EdgeIdentity do
  @moduledoc "Identity of a graph edge: two edges are the same iff caller, callee and kind match."
  alias AshA2A.ConsequenceKernel.W4C.GraphEdge

  def key(%GraphEdge{caller: c, callee: d, kind: k}), do: {c, d, k}
  def key(%{caller: c, callee: d, kind: k}), do: {c, d, k}
end
