defmodule AshA2A.C1W4B.ObserveAgentRawTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.W4B.EntryPolicy

  test "observe_agent_raw",
    do: assert(EntryPolicy.admit(:observe, :agent) == {:error, :invalid_consequence})
end
