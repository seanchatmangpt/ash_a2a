defmodule AshA2A.C1W4B.UnknownTestTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.W4B.EntryPolicy

  test "unknown_test",
    do: assert(EntryPolicy.admit(:unknown, :test) == {:error, :consequence_unclassified})
end
