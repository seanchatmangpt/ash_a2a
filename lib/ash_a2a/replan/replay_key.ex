# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.ReplayKey do
  def build(subject, provider, attempt),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary({subject, provider, attempt}))
      |> Base.encode16(case: :lower)
end
