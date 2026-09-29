defmodule AshA2A.C1W4B.ExternalAgentTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.W4B.EntryPolicy
  test "external_agent", do: assert EntryPolicy.admit(:external_do, :agent) == {:error, :consequence_kernel_required}
end
