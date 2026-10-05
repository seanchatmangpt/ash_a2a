# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.Runtime.ApplyingStage do
  alias AshA2A.ConsequenceKernel.Runtime.{PreparedDigest, StoreHandle}

  def run(store, prepared) do
    with {:ok, digest} <- PreparedDigest.fetch(prepared),
         do: StoreHandle.call(store, :transition, [digest, :claimed, :applying])
  end
end
