# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.StalePlan do
  def stale?(%{projection_digest: a}, %{projection_digest: b}) when is_binary(a) and is_binary(b),
    do: a != b

  def stale?(_, _), do: true
end
