# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.UnknownOutcomeTest do
  use ExUnit.Case, async: true

  test "unknown retains effect identity" do
    p = %{instance: %{effect_id: "e"}, prepared_digest: "p"}
    x = AshA2A.ConsequenceKernel.UnknownOutcome.new(p, :ambiguous)
    assert x.effect_id == "e"
  end
end
