defmodule AshA2A.C1W4B.ChangeKernelTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.W4B.EntryPolicy
  test "change_kernel", do: assert EntryPolicy.admit(:change, :kernel) == :ok
end
