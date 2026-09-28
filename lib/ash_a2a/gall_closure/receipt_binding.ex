defmodule AshA2A.GallClosure.ReceiptBinding do
  @moduledoc "Bounded GALL-029/030 guard for receipt_id."
  def admit(%{receipt_id: v}=s) when v not in [nil,false,""], do: {:ok, Map.put(s,:gall_guard,:receipt_binding)}
  def admit(_), do: {:error,:missing_receipt}
end
