defmodule AshA2A.Test.Fixture.JSONRPCHandler do
  @moduledoc """
  Real `A2A.JSONRPC` behaviour implementation backed by a real, running
  `AshA2A.Test.Fixture.EchoAgent` `A2A.Agent` GenServer (started under a real
  `A2A.AgentSupervisor` by the test via
  `AshA2A.Test.AgentSupervisorCase.start_supervised_agents!/2`).

  This exists so `test/ash_a2a_push_notification_config_test.exs` can drive
  `A2A.JSONRPC.handle/3` -- the real transport-agnostic JSON-RPC dispatch
  layer that `A2A.Plug` itself implements against
  (`~/xaas/deps/a2a/lib/a2a/plug.ex:259-310`) -- with a handler that is
  actually wired to real ash_a2a dispatch, instead of an unused stub module.
  `handle_send/3` delegates to the real `EchoAgent.call/2`
  (`~/xaas/deps/a2a/lib/a2a/agent.ex:220-222`), which in turn drives the real
  `AshA2A.Dispatcher.dispatch/5` behind the generated agent.

  `handle_get/3` and `handle_cancel/3` are real implementations too (not
  mocks) -- they simply return `A2A.JSONRPC.Error.method_not_found/1` because
  this fixture only needs `handle_send/3` for the push-notification-config
  test, which never reaches any of these three callbacks at all: per
  `~/xaas/deps/a2a/lib/a2a/jsonrpc.ex:171`, every
  `"tasks/pushNotificationConfig/" <> _` method is intercepted by
  `A2A.JSONRPC`'s own dispatch clause before any handler callback runs.
  """

  @behaviour A2A.JSONRPC

  alias AshA2A.Test.Fixture.EchoAgent

  @impl A2A.JSONRPC
  def handle_send(message, _params, _context) do
    case Process.get(:push_notification_call_counter) do
      nil -> :ok
      counter -> Agent.update(counter, &(&1 + 1))
    end

    EchoAgent.call(EchoAgent, message)
  end

  @impl A2A.JSONRPC
  def handle_get(task_id, _params, _context) do
    {:error, A2A.JSONRPC.Error.task_not_found(task_id)}
  end

  @impl A2A.JSONRPC
  def handle_cancel(task_id, _params, _context) do
    {:error, A2A.JSONRPC.Error.task_not_cancelable(task_id)}
  end
end
