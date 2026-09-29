defmodule AshA2A.ReceiptChainTest do
 use ExUnit.Case, async: true
 test "chain digest binds predecessor" do
  assert AshA2A.ConsequenceKernel.ReceiptChain.next("a",%{"x"=>1}) != AshA2A.ConsequenceKernel.ReceiptChain.next("b",%{"x"=>1})
 end
end
