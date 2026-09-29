defmodule AshA2A.C1W4B.ChangeDispatcherTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.W4B.EntryPolicy

  test "change_dispatcher",
    do: assert(EntryPolicy.admit(:change, :dispatcher) == {:error, :consequence_kernel_required})
end
