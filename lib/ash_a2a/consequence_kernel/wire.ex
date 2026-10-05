# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.Wire do
  def encode(value) do
    {:ok, Jcs.encode(value)}
  rescue
    _ -> {:error, :canonical_unencodable}
  end

  def digest(value), do: AshA2A.Identity.Canonical.digest(value)
end
