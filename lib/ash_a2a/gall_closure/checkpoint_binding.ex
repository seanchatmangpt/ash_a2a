# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.GallClosure.CheckpointBinding do
  @moduledoc "Bounded GALL-029/030 guard for checkpoint."
  def admit(%{checkpoint: v} = s) when v not in [nil, false, ""],
    do: {:ok, Map.put(s, :gall_guard, :checkpoint_binding)}

  def admit(_), do: {:error, :missing_checkpoint}
end
