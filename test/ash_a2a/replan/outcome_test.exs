defmodule AshA2A.Replan.OutcomeTest do
  use ExUnit.Case, async: true

  test "unknown is recoverable" do
    assert AshA2A.Replan.Outcome.recoverable?(:unknown_outcome)
  end
end
