defmodule AshA2A.ReceiptDeterminismW2Test do
  use ExUnit.Case, async: true

  test "digests are insertion-order independent for large maps" do
    pairs = for i <- 1..200, do: {"k#{i}", i}
    a = Map.new(pairs)
    b = Map.new(Enum.reverse(pairs))
    assert AshA2A.Evidence.Class.digest(a) == AshA2A.Evidence.Class.digest(b)
  end
end
