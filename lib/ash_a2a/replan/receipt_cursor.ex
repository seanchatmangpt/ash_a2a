# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.ReceiptCursor do
  defstruct [:receipt_id, :terminal_status, :projection_digest]

  def from(r),
    do: %__MODULE__{
      receipt_id: Map.get(r, :receipt_id),
      terminal_status: Map.get(r, :terminal_status),
      projection_digest: Map.get(r, :projection_digest)
    }
end
