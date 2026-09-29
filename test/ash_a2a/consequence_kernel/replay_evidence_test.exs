defmodule AshA2A.ReplayEvidenceTest do
  use ExUnit.Case, async: true

  test "refuses effect divergence" do
    p = %{instance: %{effect_id: "a"}, prepared_digest: "p"}
    r = %{effect_id: "b", prepared_digest: "p"}

    assert {:error, :replay_effect_divergence} =
             AshA2A.ConsequenceKernel.ReplayEvidence.verify(p, r)
  end
end
