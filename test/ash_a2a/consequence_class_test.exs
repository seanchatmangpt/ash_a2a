defmodule AshA2A.ConsequenceClassTest do
  use ExUnit.Case, async: true

  test "unknown is fail closed" do
    assert {:ok, :unknown} = AshA2A.ConsequenceClass.classify(:custom)
    refute AshA2A.ConsequenceClass.admitted?(:unknown)
  end
end
