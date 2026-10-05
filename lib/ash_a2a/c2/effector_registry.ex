# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C2.EffectorRegistry do
  def fetch(effect, registry) do
    case Map.fetch(registry, effect.capability) do
      {:ok, effector} when is_atom(effector) -> {:ok, effector}
      :error -> {:error, :unknown_effector}
    end
  end
end
