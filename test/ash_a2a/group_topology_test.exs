defmodule AshA2A.GroupTopologyTest do
  use ExUnit.Case, async: true

  alias AshA2A.{Identity, Topology.Group}

  test "typed identities become deterministic topology keys" do
    assert Group.key(Identity.agent("worker-1")) == "agent:worker-1"
    assert Group.key(Identity.runtime("node-a")) == "runtime:node-a"
    assert Group.key("raw") == "raw"
  end

  test "missing Group provider returns typed unsupported instead of fabricating topology" do
    unless Group.available?() do
      assert {:error, {:unsupported, :group, :lookup, 2}} =
               Group.lookup(:ash_a2a_group, Identity.agent("worker-1"))
    end
  end
end
