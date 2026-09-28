defmodule AshA2A.SemanticWork.ReceiptTest do
 use ExUnit.Case, async: true
 alias AshA2A.SemanticWork.Receipt
 test "fails closed" do
  assert {:error,_}= Receipt.bind(%{})
  assert {:error,:refused_invalid_envelope}= Receipt.bind(:invalid)
 end
end
