defmodule AshA2A.C1W4B.UnknownKernelTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.W4B.EntryPolicy
  test "unknown_kernel", do: assert EntryPolicy.admit(:unknown, :kernel) == {:error, :consequence_unclassified}
end
