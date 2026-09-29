defmodule AshA2A.C1W4B.NilDispatcherTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.W4B.EntryPolicy

  test "nil_dispatcher",
    do: assert(EntryPolicy.admit(nil, :dispatcher) == {:error, :invalid_consequence})
end
