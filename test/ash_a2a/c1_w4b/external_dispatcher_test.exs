defmodule AshA2A.C1W4B.ExternalDispatcherTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.W4B.EntryPolicy
  test "external_dispatcher", do: assert EntryPolicy.admit(:external_do, :dispatcher) == {:error, :consequence_kernel_required}
end
