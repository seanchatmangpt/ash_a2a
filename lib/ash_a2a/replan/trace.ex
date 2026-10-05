# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.Trace do
  defstruct events: []
  def append(%__MODULE__{events: e} = t, event), do: %{t | events: [event | e]}
  def replay(%__MODULE__{events: e}), do: Enum.reverse(e)
end
