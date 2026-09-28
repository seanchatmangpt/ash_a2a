defmodule AshA2A.Gall.Closure.FalsifierTest do
  use ExUnit.Case, async: true
  alias AshA2A.Gall.Closure.Falsifier

  test "negative control names exact mismatched fields" do
    assert {:ok, :not_falsified} = Falsifier.evaluate(%{count: 1}, %{count: 1})

    assert {:error, {:falsified, [%{field: :count, expected: 1, observed: 2}]}} =
             Falsifier.evaluate(%{count: 1}, %{count: 2})
  end
end
