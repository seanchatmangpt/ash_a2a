# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.W4B.UnknownOutcomePolicy do
  @moduledoc false
  def next(:unknown_outcome, :retry), do: {:error, :reconciliation_required}
  def next(:unknown_outcome, action) when action in [:reconcile, :compensate], do: {:ok, action}
  def next(state, _) when state in [:completed, :failed], do: {:ok, :terminal}
  def next(_, _), do: {:error, :invalid_outcome}
end
