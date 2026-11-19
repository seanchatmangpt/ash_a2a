# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.RefusalTaxonomyTest do
  use ExUnit.Case, async: true

  test "taxonomy contains subject drift and exhaustion" do
    codes = AshA2A.Replan.Refusal.codes()
    assert :replan_subject_drift in codes
    assert :replan_exhausted in codes
  end
end
