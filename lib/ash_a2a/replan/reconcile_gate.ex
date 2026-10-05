# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.ReconcileGate do
  def allow?(%{terminal_status: :unknown_outcome}), do: {:error, %{code: :reconcile_required}}
  def allow?(_), do: :ok
end
