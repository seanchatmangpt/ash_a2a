# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.GallClosure.InterventionClosure do
  @moduledoc "Bounded GALL-029/030 guard for closure_id."
  def admit(%{closure_id: v} = s) when v not in [nil, false, ""],
    do: {:ok, Map.put(s, :gall_guard, :intervention_closure)}

  def admit(_), do: {:error, :missing_closure}
end
