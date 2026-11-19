# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ReplayEvidenceTest do
  use ExUnit.Case, async: true

  test "refuses effect divergence" do
    p = %{instance: %{effect_id: "a"}, prepared_digest: "p"}
    r = %{effect_id: "b", prepared_digest: "p"}

    assert {:error, :replay_effect_divergence} =
             AshA2A.ConsequenceKernel.ReplayEvidence.verify(p, r)
  end
end
