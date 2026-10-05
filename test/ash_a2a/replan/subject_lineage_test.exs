# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.SubjectLineageTest do
  use ExUnit.Case, async: true

  test "refuses subject drift" do
    assert {:error, %{code: :replan_subject_drift}} = AshA2A.Replan.SubjectLineage.guard("a", "b")
  end
end
