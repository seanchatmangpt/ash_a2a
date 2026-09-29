defmodule AshA2A.C1W4B.ChangeObservationTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.W4B.EntryPolicy

  test "change_observation",
    do: assert(EntryPolicy.admit(:change, :observation) == {:error, :consequence_kernel_required})
end
