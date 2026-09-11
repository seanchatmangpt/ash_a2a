defmodule AshA2AAgentMultiTurnTest do
  @moduledoc """
  Real multi-turn `task_id:` continuation through a real `A2A.Agent`
  GenServer process (not a bare `AshA2A.Dispatcher.dispatch/5` call, and not
  just an assertion on the paused task struct's shape).

  This is the one genuinely-untested surface from item #1 of this session's
  research: every existing `{:input_required, _}` test in this suite
  (`test/ash_a2a_dispatcher_*_test.exs`) proves only the *first* turn --
  that a missing-argument `Ash.Error.Invalid` maps to `{:input_required, _}`
  -- and stops there. None of them sends a real follow-up `A2A.Message` back
  through `A2A.Agent.call/3` with `task_id:` set to prove the paused task
  actually resumes, nor that `A2A.Agent.Runtime`'s real accumulated
  `history` genuinely reaches `AshA2A.Dispatcher`'s
  `context[:a2a_history]` on the second turn.

  Chicago-style throughout: a real supervised `A2A.Agent` process
  (`AshA2A.Test.Fixture.MultiTurnConversationAgent`), real `A2A.Agent.call/3`
  calls, real state-based assertions on the real returned `A2A.Task.t()` and
  on real values the fixture's own Ash action computed from real
  `input.context[:a2a_history]` -- no Mock/mox/patch/monkeypatch.
  """

  use ExUnit.Case, async: true

  import AshA2A.Test.MessageHelpers

  alias AshA2A.Test.Fixture.MultiTurnConversationAgent

  setup do
    {_sup, _registry_name} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [
        MultiTurnConversationAgent
      ])

    :ok
  end

  test "a paused :input_required task resumes under the same real task_id and sees real prior history" do
    # Turn 1: omit the required `:text` argument. `Ash.ActionInput.for_action/3`
    # raises a real `Ash.Error.Invalid` (missing argument), which
    # `AshA2A.Dispatcher.to_reply/1` maps to a real `{:input_required, _}`
    # reply -- pausing the real task under a real `A2A.Agent`-assigned
    # `task_id`.
    assert {:ok, turn1} =
             MultiTurnConversationAgent.call(MultiTurnConversationAgent, data_message(%{}))

    assert turn1.status.state == :input_required
    assert is_binary(turn1.id)
    task_id = turn1.id

    # The paused task's real history already carries the real inbound user
    # message from turn 1 (A2A.Agent.Runtime's own bookkeeping, not this
    # test's).
    assert Enum.any?(turn1.history, &(&1.role == :user))

    # Turn 2: continue the SAME real task_id, this time supplying `:text`.
    # This is the actual multi-turn continuation this item targets -- a real
    # follow-up `A2A.Agent.call/3` naming the paused task, not a fresh call.
    assert {:ok, turn2} =
             MultiTurnConversationAgent.call(
               MultiTurnConversationAgent,
               data_message(%{text: "second turn"}),
               task_id: task_id
             )

    # Same real task, real state machine, now resolved.
    assert turn2.id == task_id
    assert turn2.status.state == :completed

    assert [%A2A.Artifact{parts: [%A2A.Part.Data{data: result}]}] = turn2.artifacts

    # The fixture's real Ash action itself counted
    # `length(input.context[:a2a_history])` on this second, real dispatch --
    # proof (produced by real Ash action code, not asserted from outside)
    # that the real turn-1 history (the original user message, plus the
    # real `:input_required` agent reply `A2A.Agent.Runtime` appended) was
    # genuinely threaded into this second call's Ash `context:` opt, not
    # just present on the task struct this test can already see directly.
    assert result[:text] == "second turn"
    assert result[:prior_turns] >= 1

    # The real accumulated history on the resumed task also includes both
    # real turns end to end.
    assert Enum.count(turn2.history, &(&1.role == :user)) == 2

    # Getting the task back out by id proves it's genuinely the same
    # real, persisted task -- not a same-shaped new one.
    assert {:ok, fetched} =
             MultiTurnConversationAgent.get_task(MultiTurnConversationAgent, task_id)

    assert fetched.id == task_id
    assert fetched.status.state == :completed
  end
end
