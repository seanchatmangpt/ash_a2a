# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.EffectIdentity do
  @moduledoc false
  def derive(request_id, effect),
    do:
      AshA2A.Identity.Canonical.Migration.tagged_digest("sa2a.effect.v1", %{
        "request_id" => request_id,
        "effect" => effect
      })
end
