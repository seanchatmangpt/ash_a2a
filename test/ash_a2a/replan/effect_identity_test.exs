# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.EffectIdentityTest do
  use ExUnit.Case, async: true

  test "requires same effect and subject" do
    assert AshA2A.Replan.EffectIdentity.preserve?(%{actuation_id: "a", projection_digest: "p"}, %{
             actuation_id: "a",
             projection_digest: "p"
           })

    refute AshA2A.Replan.EffectIdentity.preserve?(%{actuation_id: "a", projection_digest: "p"}, %{
             actuation_id: "b",
             projection_digest: "p"
           })
  end
end
