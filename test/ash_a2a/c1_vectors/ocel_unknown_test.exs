# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C1OcelUnknownTest do
  use ExUnit.Case, async: true

  test "unknown remains explicit evidence" do
    p = %{instance: %{effect_id: "e", subject_digest: "s"}, prepared_digest: "p"}
    assert AshA2A.ConsequenceKernel.Ocel.project(p, :unknown)["outcome"] == "unknown"
  end
end
