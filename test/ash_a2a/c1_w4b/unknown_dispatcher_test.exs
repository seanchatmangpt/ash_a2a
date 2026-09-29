defmodule AshA2A.C1W4B.UnknownDispatcherTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.W4B.EntryPolicy

  test "unknown_dispatcher",
    do: assert(EntryPolicy.admit(:unknown, :dispatcher) == {:error, :consequence_unclassified})
end
