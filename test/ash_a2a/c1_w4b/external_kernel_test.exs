defmodule AshA2A.C1W4B.ExternalKernelTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.W4B.EntryPolicy
  test "external_kernel", do: assert(EntryPolicy.admit(:external_do, :kernel) == :ok)
end
