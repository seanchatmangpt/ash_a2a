defmodule AshA2A.C1W4B.ExternalObservationTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.W4B.EntryPolicy

  test "external_observation",
    do:
      assert(
        EntryPolicy.admit(:external_do, :observation) == {:error, :consequence_kernel_required}
      )
end
