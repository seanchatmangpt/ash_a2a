# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.W4C.ClosureReceipt do
  def issue(report) do
    case AshA2A.ConsequenceKernel.W4C.ClosurePredicate.evaluate(report) do
      {:ok, proof} -> %{standing: :derived, predicate: proof, raw_edges: 0}
      {:error, {:raw_effect_edges, edges}} -> %{standing: :refused, raw_edges: length(edges)}
    end
  end
end
