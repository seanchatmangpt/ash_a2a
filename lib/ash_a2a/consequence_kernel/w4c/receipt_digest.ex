# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.W4C.ReceiptDigest do
  def digest(edges),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(edges)) |> Base.encode16(case: :lower)
end
