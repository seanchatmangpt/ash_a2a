defmodule AshA2A.C1W5.ReceiptChainTest do
  use ExUnit.Case, async: true

  test "receipt_chain" do
    p = Path.join([File.cwd!(), "priv", "sa2a", "c1", "w5_vectors", "receipt_chain.json"])
    assert File.read!(p) =~ "\"sa2a-c1-w5-v1\""
  end
end
