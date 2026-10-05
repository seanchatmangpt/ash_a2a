# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.PresenceTopologyTest do
  use ExUnit.Case, async: true

  alias AshA2A.{Identity, Topology.Presence}

  test "presence keys preserve typed machine identity" do
    assert Presence.key(Identity.agent("agent-1")) == "agent:agent-1"
    assert Presence.key(Identity.task("task-1")) == "task:task-1"
  end

  test "missing host Presence module returns typed unsupported" do
    missing = AshA2A.Test.MissingPresence
    refute Presence.available?(missing)

    assert {:error, {:unsupported, :phoenix_presence, ^missing, :list, 1}} =
             Presence.list(missing, "agents")
  end
end
