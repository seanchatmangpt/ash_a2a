# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.W4C.ClosurePredicate do
  alias AshA2A.ConsequenceKernel.W4C.RawEffectEdges

  def evaluate(report) do
    case RawEffectEdges.from_report(report) do
      [] -> {:ok, :zero_consequential_raw_effect_edges}
      edges -> {:error, {:raw_effect_edges, edges}}
    end
  end
end
