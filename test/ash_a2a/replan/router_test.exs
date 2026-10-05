# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.RouterTest do
  use ExUnit.Case, async: true

  test "failed becomes replan" do
    assert %{kind: :replan} = AshA2A.Replan.Router.decide(%{subject: "s", outcome: :failed})
  end
end
