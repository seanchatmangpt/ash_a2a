defmodule AshA2A.GallClosure.OneDoGateTest do
  use ExUnit.Case, async: true
  alias AshA2A.GallClosure.OneDoGate

  test "bounded admission", do: assert(match?({:ok, _}, OneDoGate.admit(%{do_count: 1})))
  test "typed refusal", do: assert(OneDoGate.admit(%{}) == {:error, :invalid_do_count})

  test "admits 0 and 1 with guard tag" do
    assert {:ok, %{gall_guard: :one_do_gate}} = OneDoGate.admit(%{do_count: 0})
    assert {:ok, %{gall_guard: :one_do_gate}} = OneDoGate.admit(%{do_count: 1})
  end

  test "refuses counts other than 0 or 1" do
    for v <- [5, 2, -1, "witness", "1", 1.0, true, nil, false, ""] do
      assert OneDoGate.admit(%{do_count: v}) == {:error, :invalid_do_count}
    end
  end
end
