defmodule AshA2A.OnCancelHookTest do
  @moduledoc """
  Real, unmocked coverage for the ARD task-lifecycle gap: task cancellation
  semantics needed a real, observable hook a resource author can use for
  Ash-side compensation on cancel (`AshA2A.OnCancel`, the `on_cancel:` skill
  option in `AshA2A.Dsl`).

  Same real in-flight mechanism as `test/ash_a2a_cancel_inflight_test.exs`
  (a streaming `:read` skill produces a genuinely `:working`, non-terminal
  task with the agent's mailbox free -- see that file and
  `test/support/cancel_fixture.ex` for the full rationale). This file adds
  a real `on_cancel:` hook to the skill and asserts on real state a
  supervised `Agent` recorded (`AshA2A.Test.Fixture.OnCancelRecorder`), not
  on "was this called".

  No `Mock`/`mox`/`patch`/`monkeypatch` anywhere in this file: the resource,
  the agent, the supervisor, the stream, the hook module, the recorder
  `Agent`, and the cancel call are all real.
  """

  use ExUnit.Case, async: true

  import AshA2A.Test.MessageHelpers

  alias AshA2A.Test.Fixture.OnCancelErrorStreamItem
  alias AshA2A.Test.Fixture.OnCancelErrorStreamItemAgent
  alias AshA2A.Test.Fixture.OnCancelRecorder
  alias AshA2A.Test.Fixture.OnCancelStreamItem
  alias AshA2A.Test.Fixture.OnCancelStreamItemAgent

  test "a real on_cancel hook runs real Ash-side compensation on a genuine cancel" do
    {:ok, _recorder} = start_supervised(OnCancelRecorder)

    {_sup, _registry_name} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [
        OnCancelStreamItemAgent
      ])

    Ash.create!(OnCancelStreamItem, %{label: "one"})

    message = data_message(%{"stream" => true}, %{metadata: %{"skill" => "list_items"}})

    assert {:ok, task} = OnCancelStreamItemAgent.call(OnCancelStreamItemAgent, message)
    assert task.status.state == :working
    assert is_function(task.metadata[:stream])

    # Real proof the hook has not already run before cancel: nothing
    # recorded yet.
    assert OnCancelRecorder.records() == []

    assert :ok = OnCancelStreamItemAgent.cancel(OnCancelStreamItemAgent, task.id)

    assert {:ok, canceled_task} =
             OnCancelStreamItemAgent.get_task(OnCancelStreamItemAgent, task.id)

    assert canceled_task.status.state == :canceled

    # Real state, not an interaction assertion: the hook module really ran
    # and really appended to the real recorder `Agent`.
    assert [{exec_context, task_id, context_id}] = OnCancelRecorder.records()
    assert task_id == task.id
    assert context_id == task.context_id
    assert exec_context.domain == OnCancelStreamItem
  end

  test "a raising on_cancel hook is caught, cancel still succeeds, and the failure is reported" do
    {_sup, _registry_name} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [
        OnCancelErrorStreamItemAgent
      ])

    Ash.create!(OnCancelErrorStreamItem, %{label: "one"})

    handler_id = "on-cancel-hook-error-telemetry-#{inspect(make_ref())}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:ash_a2a, :agent, :cancel_hook_error],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:ash_a2a_cancel_hook_error_telemetry, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    message = data_message(%{"stream" => true}, %{metadata: %{"skill" => "list_items"}})

    assert {:ok, task} =
             OnCancelErrorStreamItemAgent.call(OnCancelErrorStreamItemAgent, message)

    assert task.status.state == :working

    # The real assertion: a hook that raises does not crash the cancel
    # call -- `handle_cancel/1`'s `:ok` contract with `A2A.Agent`'s own
    # state machine holds regardless.
    assert :ok = OnCancelErrorStreamItemAgent.cancel(OnCancelErrorStreamItemAgent, task.id)

    assert {:ok, canceled_task} =
             OnCancelErrorStreamItemAgent.get_task(OnCancelErrorStreamItemAgent, task.id)

    assert canceled_task.status.state == :canceled

    assert_receive {:ash_a2a_cancel_hook_error_telemetry, error_meta}, 1_000
    assert error_meta.task_id == task.id
    assert error_meta.resource_or_domain == OnCancelErrorStreamItem
    assert error_meta.error.kind == :error
    assert error_meta.error.reason =~ "deliberate on_cancel hook failure"
  end
end
