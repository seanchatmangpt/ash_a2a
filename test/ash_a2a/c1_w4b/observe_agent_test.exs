defmodule AshA2A.C1W4B.ObserveAgentTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.W4B.EntryPolicy
  test "observe_agent", do: assert EntryPolicy.admit(:observe, :observation) == :ok
end
