# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.W4C.ReportSchema do
  def valid?(%{edges: edges}) when is_list(edges), do: true
  def valid?(_), do: false
end
