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
