defmodule AshA2A.C1W4B.ExternalTestTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.W4B.EntryPolicy

  test "external_test",
    do: assert(EntryPolicy.admit(:external_do, :test) == {:error, :consequence_kernel_required})
end
