# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.Runtime.ReconciliationStage do
  alias AshA2A.ConsequenceKernel.Runtime.StoreHandle

  def reconcile(s, d, x) when x in [:reconciled, :compensated],
    do: StoreHandle.call(s, :transition, [d, :unknown_outcome, x])

  def reconcile(_, _, x), do: {:error, {:invalid_reconciliation, x}}
end
