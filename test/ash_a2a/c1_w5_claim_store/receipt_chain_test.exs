defmodule AshA2A.C1W5ClaimStore.ReceiptChainTest do
  use ExUnit.Case, async: true
  test "receipt_chain" do
    vector=Path.join([File.cwd!(),"priv","sa2a","c1","w5_claim_store_vectors","receipt_chain.json"])
    assert File.read!(vector)=~"\"case\": \"receipt_chain\""
    assert {:ok,"sha256:"<>d}=AshA2A.ConsequenceKernel.W5.ReceiptChain.append("sha256:root",%{"event"=>"claimed"}); assert byte_size(d)==64
  end
end
