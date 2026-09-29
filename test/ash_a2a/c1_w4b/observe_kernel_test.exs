defmodule AshA2A.C1W4B.ObserveKernelTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.W4B.EntryPolicy
  test "observe_kernel", do: assert EntryPolicy.admit(:observe, :kernel) == :ok
end
