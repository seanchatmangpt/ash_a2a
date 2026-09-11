defmodule AshA2A.Test.Fixture.LockedAgent do
  @moduledoc """
  Real `A2A.Agent` GenServer built with `use AshA2A.Agent` over the existing
  `AshA2A.Test.Fixture.Locked` resource (`test/support/fixture.ex`) -- a
  genuine Ash resource whose `authorizers: [Ash.Policy.Authorizer]` +
  `policy always() do forbid_unless(always()) end` always denies, paired
  with `AshA2A.Test.Fixture.LockedDomain`'s `authorization do authorize(:always)
  end`.

  `test/ash_a2a_test.exs` already proves `AshA2A.Dispatcher.dispatch/3`
  itself maps this denial to `{:error, %{class: :forbidden}}` -- but that
  test calls the dispatcher directly, bypassing the real `A2A.Agent`
  GenServer/`A2A.Agent.Runtime` task state machine entirely. This fixture
  exists to drive the SAME real forbidden dispatch through a REAL
  `A2A.Agent` process instead, so `test/ash_a2a_task_failed_state_test.exs`
  can assert the real resulting `A2A.Task.t()`'s `status.state` actually
  reaches `:failed` -- proving `A2A.Agent.Runtime.handle_reply({:error, _},
  task)` (`~/xaas/deps/a2a/lib/a2a/agent/runtime.ex:99-103`) really fires
  for an ash_a2a-generated agent, not just that the dispatcher classifies
  the error correctly in isolation.

  No new resource/policy authored here -- this file only wires the existing
  `Locked` fixture into a new, distinctly-named agent module so this test
  file's agent registration can't collide with any other fixture agent
  (`EchoAgent`, `WidgetAgent`) sharing the same `A2A.AgentSupervisor` in a
  concurrent test run.
  """

  use AshA2A.Agent,
    resource_or_domain: AshA2A.Test.Fixture.Locked,
    name: "locked_agent_for_failed_state_test"
end
