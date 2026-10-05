# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.W5.Reconciliation do
  def resolve(:observed_applied, e), do: {:completed, e}
  def resolve(:observed_not_applied, e), do: {:failed, e}
  def resolve(_, e), do: {:unknown_outcome, e}
end
