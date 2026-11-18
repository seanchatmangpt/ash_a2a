# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.OcelProjectionTest do
  use ExUnit.Case, async: true

  test "projection preserves exact identity" do
    p = %{instance: %{effect_id: "e", subject_digest: "s"}, prepared_digest: "p"}
    x = AshA2A.ConsequenceKernel.Ocel.project(p, :ok)
    assert x["effect_id"] == "e"
    assert x["subject_digest"] == "s"
  end
end
