defmodule AshA2A.Test.Fixture.MultiTurnConversation do
  @moduledoc """
  Real fixture resource for a real multi-turn `A2A.Agent` continuation test
  (`test/ash_a2a_agent_multi_turn_test.exs`). Every existing test in this
  suite that exercises `{:input_required, _}` (`AshA2A.Test.Fixture.Item`'s
  `create_item` skill, `test/ash_a2a_dispatcher_*_test.exs`) only proves the
  *first* turn -- a missing-argument `Ash.Error.Invalid` mapped to
  `{:input_required, _}` -- and never actually sends a real follow-up
  `A2A.Message` with `task_id:` back through a real `A2A.Agent` GenServer to
  prove the task actually resumes and the real accumulated `history` (built
  by `A2A.Agent.Runtime`, not by this test) is genuinely threaded into the
  second dispatch's Ash `context[:a2a_history]`
  (`AshA2A.Dispatcher.build_opts/2`, `lib/ash_a2a/dispatcher.ex:305-312`).

  This resource's one generic `:converse` action requires a `:text`
  argument. Omitting it on the first call makes `Ash.ActionInput.for_action/3`
  produce a real `Ash.Error.Invalid` (missing argument), which
  `AshA2A.Dispatcher.to_reply/1` maps to a real `{:input_required, _}` reply
  -- pausing the real task. The action body itself (not the test) counts how
  many prior turns are visible in `input.context[:a2a_history]` and echoes
  that count back in its result, so the *second* real dispatch (continuing
  the same real `task_id`, this time supplying `:text`) can assert on real,
  action-observed evidence that the first turn's real history entry
  (the paused agent message A2A.Agent.Runtime itself appended, plus the
  original inbound user message) was actually delivered -- not asserted by
  inspecting the task struct alone, which every other test in this suite
  already does.
  """

  use Ash.Resource,
    domain: AshA2A.Test.Fixture.MultiTurnConversationDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  actions do
    action :converse, :map do
      argument(:text, :string, allow_nil?: false)

      run(fn input, context ->
        history =
          case context do
            %{source_context: %{a2a_history: h}} when is_list(h) -> h
            _ -> Map.get(input.context || %{}, :a2a_history, [])
          end

        {:ok, %{text: input.arguments.text, prior_turns: length(history)}}
      end)
    end
  end

  a2a do
    skill(:converse, :converse, consequence: :observe)
  end
end

defmodule AshA2A.Test.Fixture.MultiTurnConversationDomain do
  @moduledoc """
  Real fixture domain for `AshA2A.Test.Fixture.MultiTurnConversation` above.
  """

  use Ash.Domain, extensions: [AshA2A]

  resources do
    resource(AshA2A.Test.Fixture.MultiTurnConversation)
  end
end

defmodule AshA2A.Test.Fixture.MultiTurnConversationAgent do
  @moduledoc """
  Real `A2A.Agent` GenServer for `AshA2A.Test.Fixture.MultiTurnConversation`,
  started under a real `A2A.AgentSupervisor` by
  `test/ash_a2a_agent_multi_turn_test.exs` -- multi-turn `task_id:`
  continuation only exercises real behavior when driven through the actual
  supervised `A2A.Agent` process (`A2A.Agent.Runtime`'s real task/history
  state machine), not a bare `AshA2A.Dispatcher.dispatch/5` call.
  """

  use AshA2A.Agent,
    resource_or_domain: AshA2A.Test.Fixture.MultiTurnConversation,
    name: "multi_turn_conversation_agent"
end
