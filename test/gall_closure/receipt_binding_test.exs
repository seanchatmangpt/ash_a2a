defmodule AshA2A.GallClosure.ReceiptBindingTest do
  use ExUnit.Case, async: true
  alias AshA2A.GallClosure.ReceiptBinding

  test "bounded admission",
    do: assert(match?({:ok, _}, ReceiptBinding.admit(%{receipt_id: "witness"})))

  test "typed refusal", do: assert(ReceiptBinding.admit(%{}) == {:error, :missing_receipt})
end
