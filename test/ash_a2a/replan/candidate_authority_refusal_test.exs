# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.CandidateAuthorityRefusalTest do
  use ExUnit.Case, async: true

  test "authority escalation refused" do
    assert {:error, %{code: :replan_authority_violation}} =
             AshA2A.Replan.CandidateFence.check(%{standing: :candidate, authority: :do})
  end
end
