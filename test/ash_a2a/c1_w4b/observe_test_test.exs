defmodule AshA2A.C1W4B.ObserveTestTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.W4B.EntryPolicy

  test "observe_test",
    do: assert(EntryPolicy.admit(:observe, :test) == {:error, :invalid_consequence})
end
