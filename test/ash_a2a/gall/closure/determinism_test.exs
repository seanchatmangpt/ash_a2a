defmodule AshA2A.Gall.Closure.DeterminismTest do
  use ExUnit.Case, async: true
  alias AshA2A.Gall.Closure.Determinism

  test "map ordering is not semantic" do
    left = %{"b" => 2, "a" => %{"y" => 1, "x" => 0}}
    right = %{"a" => %{"x" => 0, "y" => 1}, "b" => 2}
    assert Determinism.digest(left) == Determinism.digest(right)
    refute Determinism.digest(left) == Determinism.digest(Map.put(right, "b", 3))
  end
end
