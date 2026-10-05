# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.PreparedEffectStore.Recovery do
  @terminal [:completed, :reconciled, :compensated, :refused]
  def disposition(%{state: s}) when s in @terminal, do: {:terminal, s}
  def disposition(%{state: :unknown_outcome}), do: {:reconcile, :unknown_outcome}
  def disposition(%{state: s}) when s in [:prepared, :claimed, :applying], do: {:resume, s}
  def disposition(_), do: {:error, :prepared_state_unknown}
end
