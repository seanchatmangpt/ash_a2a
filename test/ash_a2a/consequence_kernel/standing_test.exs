defmodule AshA2A.StandingTest do
 use ExUnit.Case, async: true
 test "unknown outcome has no standing" do
  assert {:error,:standing_unknown_outcome}=AshA2A.ConsequenceKernel.Standing.derive(%{outcome: :unknown})
 end
end
