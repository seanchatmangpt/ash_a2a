defmodule AshA2A.Replan.CandidateAuthorityRefusalTest do
  use ExUnit.Case, async: true

  test "authority escalation refused" do
    assert {:error, %{code: :replan_authority_violation}} =
             AshA2A.Replan.CandidateFence.check(%{standing: :candidate, authority: :do})
  end
end
