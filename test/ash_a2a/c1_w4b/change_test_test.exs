defmodule AshA2A.C1W4B.ChangeTestTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.W4B.EntryPolicy
  test "change_test", do: assert EntryPolicy.admit(:change, :test) == {:error, :consequence_kernel_required}
end
