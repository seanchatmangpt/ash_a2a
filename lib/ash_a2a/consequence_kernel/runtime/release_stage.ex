# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.Runtime.ReleaseStage do
  alias AshA2A.ConsequenceKernel.Runtime.{PreparedDigest, StoreHandle}

  def release(s, p, from) when from in [:prepared, :claimed] do
    with {:ok, digest} <- PreparedDigest.fetch(p),
         do: StoreHandle.call(s, :transition, [digest, from, :released])
  end

  def release(_, _, from), do: {:error, {:release_after_apply_forbidden, from}}
end
