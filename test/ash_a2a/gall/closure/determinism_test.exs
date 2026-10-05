# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Gall.Closure.DeterminismTest do
  use ExUnit.Case, async: true
  alias AshA2A.Gall.Closure.Determinism

  test "map ordering is not semantic" do
    left = %{"b" => 2, "a" => %{"y" => 1, "x" => 0}}
    right = %{"a" => %{"x" => 0, "y" => 1}, "b" => 2}
    assert Determinism.digest(left) == Determinism.digest(right)
    refute Determinism.digest(left) == Determinism.digest(Map.put(right, "b", 3))
  end

  test "tuples and lists do not collide" do
    refute Determinism.digest({:a, 1}) == Determinism.digest([:a, 1])
  end

  test "atom keys and string keys do not collide" do
    refute Determinism.digest(%{a: 1}) == Determinism.digest(%{"a" => 1})
  end

  test "key order is irrelevant for mixed key types and format is preserved" do
    a = Map.new([{:z, 1}, {"y", 2}, {3, 4}])
    b = Map.new([{3, 4}, {"y", 2}, {:z, 1}])
    assert Determinism.digest(a) == Determinism.digest(b)
    assert "sha256:" <> hex = Determinism.digest(a)
    assert byte_size(hex) == 64
  end
end
