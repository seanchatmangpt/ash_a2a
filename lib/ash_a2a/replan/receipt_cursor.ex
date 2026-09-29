defmodule AshA2A.Replan.ReceiptCursor do
  defstruct [:receipt_id, :terminal_status, :projection_digest]

  def from(r),
    do: %__MODULE__{
      receipt_id: Map.get(r, :receipt_id),
      terminal_status: Map.get(r, :terminal_status),
      projection_digest: Map.get(r, :projection_digest)
    }
end
