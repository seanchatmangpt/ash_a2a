defmodule AshA2A.CancelInflightTest do
  @moduledoc """
  Real, unmocked coverage for research item #5: cancellation of a genuinely
  in-flight `AshA2A`-dispatched task, driven through a real `A2A.Agent`
  GenServer under a real `A2A.AgentSupervisor` -- not a bare
  `AshA2A.Dispatcher.dispatch/5` function call, and not a synthetic
  `context()` map handed straight to `AshA2A.Agent.__cancel__/2`.

  See `AshA2A.Test.Fixture.StreamItem`'s moduledoc
  (`test/support/cancel_fixture.ex`) for why a streaming `:read` skill is
  the one real mechanism that produces a task that is still `:working`
  (non-terminal, i.e. genuinely in-flight) while the agent's mailbox is
  free to accept a real concurrent `cancel/2` call -- an ordinary
  synchronous action blocks the same mailbox the cancel call would need to
  arrive through, so no real interleaving exists for it.

  No `Mock`/`mox`/`patch`/`monkeypatch` anywhere in this file: the resource,
  the agent, the supervisor, the stream, and the cancel call are all real.
  """

  use ExUnit.Case, async: true

  import AshA2A.Test.MessageHelpers

  alias AshA2A.Test.Fixture.StreamItem
  alias AshA2A.Test.Fixture.StreamItemAgent

  test "a real concurrent cancel/2 interrupts a genuinely in-flight streaming dispatch" do
    {_sup, _registry_name} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [StreamItemAgent])

    # Seed real rows through the real Ash action (bypassing A2A entirely for
    # setup) so the streaming read below has real data to stream from --
    # irrelevant to the cancel assertion itself, but proves this is a real
    # `Ash.stream!/2` over real records, not an empty/degenerate stream.
    Ash.create!(StreamItem, %{label: "one"})
    Ash.create!(StreamItem, %{label: "two"})

    handler_id = "cancel-inflight-telemetry-#{inspect(make_ref())}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:ash_a2a, :agent, :cancel],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:ash_a2a_cancel_telemetry, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    # Explicit `"skill" => "list_items"` metadata is required here: since
    # `fbc3213` ("derive canonical skills from public Ash actions"), the
    # capability index is compiled from *every* public Ash action on the
    # resource (`AshA2A.CapabilityIndex.Compiler.compile_resource/2`), not
    # just the `a2a do skill ... end` overrides declared in
    # `test/support/cancel_fixture.ex`. `StreamItem` has two public actions
    # (`:read`, exposed here as `:list_items`, and the default `:create`
    # used by this test's own `Ash.create!/2` setup calls above) -- both are
    # now real, legitimately-dispatchable skills, so
    # `AshA2A.Agent.default_skill_name/1`'s single-skill omission
    # convenience (`AshA2A.Info.capability_index/1` returning exactly one
    # entry) no longer applies and correctly refuses to guess
    # (`{:error, {:ambiguous_skill, resource}}`) when the caller doesn't say
    # which skill it means. This is real, intentional new admission
    # behavior, not a lifecycle regression: confirmed by driving
    # `AshA2A.Dispatcher.dispatch/3` directly with `:list_items` (bypassing
    # skill-name resolution entirely), which still returns a real
    # `{:stream, ...}` reply exactly as before -- only the *default* skill
    # inference changed, not dispatch or task-lifecycle admission.
    message = data_message(%{"stream" => true}, %{metadata: %{"skill" => "list_items"}})

    assert {:ok, task} = StreamItemAgent.call(StreamItemAgent, message)

    # Real, in-flight, non-terminal state: the GenServer already replied
    # (mailbox free), but the stream in `task.metadata[:stream]` has
    # deliberately not been consumed, so `A2A.Agent.Runtime.wrap_stream/3`'s
    # `{:stream_done, ...}` finalizing cast has never fired.
    assert task.status.state == :working
    assert is_function(task.metadata[:stream])

    assert :ok = StreamItemAgent.cancel(StreamItemAgent, task.id)

    # Real evidence that `AshA2A.Agent.__cancel__/2` (not just `A2A.Agent`'s
    # own state machine) actually ran: it is the one call site that emits
    # this telemetry event, and it only fires from inside
    # `A2A.Agent.Runtime.run_cancel/2`, which only runs for a real
    # non-terminal task (`~/xaas/deps/a2a/lib/a2a/agent.ex:305-309`).
    assert_receive {:ash_a2a_cancel_telemetry, cancel_meta}, 1_000
    assert cancel_meta.task_id == task.id
    assert cancel_meta.resource_or_domain == StreamItem

    # Real terminal state, fetched back through the real agent process --
    # not inferred from the `cancel/2` return value alone.
    assert {:ok, canceled_task} = StreamItemAgent.get_task(StreamItemAgent, task.id)
    assert canceled_task.status.state == :canceled

    # Real proof the state is actually terminal now: a second cancel on the
    # same task_id must be refused by `A2A.Agent`'s own real state machine.
    assert {:error, :not_cancelable} = StreamItemAgent.cancel(StreamItemAgent, task.id)
  end
end
