defmodule AshA2A.Replan.ProviderResultTest do
  use ExUnit.Case, async: true

  test "normalizes provider id" do
    assert {:ok, %{provider: :p, candidate: %{x: 1}}} =
             AshA2A.Replan.ProviderResult.normalize({:ok, %{x: 1}}, :p)
  end
end
