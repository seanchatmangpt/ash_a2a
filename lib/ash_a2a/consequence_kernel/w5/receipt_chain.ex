defmodule AshA2A.ConsequenceKernel.W5.ReceiptChain do
  def append(prev, event) when is_binary(prev) and is_map(event),
    do:
      :crypto.hash(:sha256, prev <> :erlang.term_to_binary(event, [:deterministic]))
      |> Base.encode16(case: :lower)

  def append(_, _), do: {:error, :invalid_receipt_chain}
end
