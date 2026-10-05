# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Gall.Closure.CapabilityPolicyTest do
  use ExUnit.Case, async: true
  alias AshA2A.Gall.Closure.CapabilityPolicy

  test "capability must be admitted and cannot be self-promoted" do
    candidate = %{capability_id: "Item.create"}
    assert {:ok, ^candidate} = CapabilityPolicy.admit(candidate, ["Item.create"])

    promoted = Map.put(candidate, :requested_capability_id, "Root.delete")

    assert {:error, {:refused_gall, :capability_policy, :self_promoted_capability}} =
             CapabilityPolicy.admit(promoted, ["Item.create"])
  end
end
