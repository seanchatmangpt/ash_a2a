# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.W4C.ChicagoAdapter do
  @moduledoc "Consumes graph-derived Chicago edge reports; it never invents DO authority."
  alias AshA2A.ConsequenceKernel.W4C.ClosurePredicate
  def evaluate(%{edges: edges}) when is_list(edges), do: ClosurePredicate.evaluate(edges)
  def evaluate(edges) when is_list(edges), do: ClosurePredicate.evaluate(edges)
  def evaluate(_), do: {:error, :invalid_chicago_report}
end
