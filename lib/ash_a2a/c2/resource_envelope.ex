# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C2.ResourceEnvelope do
  @enforce_keys [:principal, :effect_digest, :budget, :generation]
  defstruct @enforce_keys

  def bound?(r, e, c),
    do:
      r.principal == e.principal and r.effect_digest == e.digest and r.generation == c.generation
end
