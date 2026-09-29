defmodule AshA2A.C1ConsequenceClassesTest do
  use ExUnit.Case, async: true

  test "known classes admitted unknown refused" do
    for x <- [:observe, :change, :external], do: assert(AshA2A.ConsequenceClass.admitted?(x))
    refute AshA2A.ConsequenceClass.admitted?(:unknown)
  end
end
