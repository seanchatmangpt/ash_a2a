# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.W4C.KernelFilter do
  def outside(edges),
    do:
      Enum.reject(
        edges,
        &String.starts_with?(to_string(&1.caller), "Elixir.AshA2A.ConsequenceKernel")
      )
end
