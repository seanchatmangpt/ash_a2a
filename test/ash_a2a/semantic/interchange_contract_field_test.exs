defmodule AshA2A.Semantic.InterchangeContractFieldTest do
  use ExUnit.Case, async: true
  test "contract field" do
    b = struct(AshA2A.Semantic.InterchangeBoundary, contract: :c1)
    assert b.contract == :c1
  end
end
