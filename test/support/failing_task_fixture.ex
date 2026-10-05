# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Test.Fixture.LockedAgent do
  @moduledoc """
  Real `AshA2A.Protocol.Agent` GenServer built with `use AshA2A.Agent` over the existing
  `AshA2A.Test.Fixture.Locked` resource (`test/support/fixture.ex`) -- a
  genuine Ash resource whose `authorizers: [Ash.Policy.Authorizer]` +
  `policy always() do forbid_unless(always()) end` always denies, paired
  with `AshA2A.Test.Fixture.LockedDomain`'s `authorization do authorize(:always)
  end`.

  `test/ash_a2a_test.exs` already proves `AshA2A.Dispatcher.dispatch/3`
  itself maps this denial to `{:error, %{class: :forbidden}}` -- but that
  test calls the dispatcher directly, bypassing the real `AshA2A.Protocol.Agent`
  GenServer/`AshA2A.Protocol.Agent.Runtime` task state machine entirely. This fixture
  exists to drive the SAME real forbidden dispatch through a REAL
  `AshA2A.Protocol.Agent` process instead, so `test/ash_a2a_task_failed_state_test.exs`
  can assert the real resulting `AshA2A.Protocol.Task.t()`'s `status.state` actually
  reaches `:failed` -- proving `AshA2A.Protocol.Agent.Runtime.handle_reply({:error, _},
  task)` (in the in-repo ported codec, `lib/ash_a2a/protocol/agent/runtime.ex`) really fires
  for an ash_a2a-generated agent, not just that the dispatcher classifies
  the error correctly in isolation.

  No new resource/policy authored here -- this file only wires the existing
  `Locked` fixture into a new, distinctly-named agent module so this test
  file's agent registration can't collide with any other fixture agent
  (`EchoAgent`, `WidgetAgent`) sharing the same `AshA2A.Protocol.AgentSupervisor` in a
  concurrent test run.
  """

  use AshA2A.Agent,
    resource_or_domain: AshA2A.Test.Fixture.Locked,
    name: "locked_agent_for_failed_state_test"
end
