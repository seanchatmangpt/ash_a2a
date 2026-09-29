defmodule AshA2A.C1ReceiptPredecessorTest do
 use ExUnit.Case, async: true
 test "predecessor changes digest" do assert AshA2A.ConsequenceKernel.ReceiptChain.next("a",%{"r"=>1}) != AshA2A.ConsequenceKernel.ReceiptChain.next("b",%{"r"=>1}) end
end
