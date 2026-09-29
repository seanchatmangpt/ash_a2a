defmodule AshA2A.ConsequenceKernel.W4C.ReceiptDigest do
  def digest(edges),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(edges)) |> Base.encode16(case: :lower)
end
