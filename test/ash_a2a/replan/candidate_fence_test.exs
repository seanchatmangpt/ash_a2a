defmodule AshA2A.Replan.CandidateFenceTest do
  use ExUnit.Case, async: true

  test "candidate has no authority" do
    assert :ok = AshA2A.Replan.CandidateFence.check(%{standing: :candidate, authority: :none})
  end
end
