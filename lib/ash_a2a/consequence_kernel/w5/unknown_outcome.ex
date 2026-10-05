# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.W5.UnknownOutcome do
  def next(:unknown_outcome), do: {:reconcile, :effect_id}
  def next(_), do: {:error, :not_unknown_outcome}
  def retry(:unknown_outcome), do: {:error, :retry_forbidden}
end
