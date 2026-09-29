defmodule AshA2A.C1W4B.ObserveDispatcherTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.W4B.EntryPolicy

  test "observe_dispatcher",
    do: assert(EntryPolicy.admit(:observe, :dispatcher) == {:error, :invalid_consequence})
end
