# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Test.Fixture.JSONRPCHandler do
  @moduledoc """
  Real `AshA2A.Protocol.JSONRPC` behaviour implementation backed by a real, running
  `AshA2A.Test.Fixture.EchoAgent` `AshA2A.Protocol.Agent` GenServer (started under a real
  `AshA2A.Protocol.AgentSupervisor` by the test via
  `AshA2A.Test.AgentSupervisorCase.start_supervised_agents!/2`).

  This exists so `test/ash_a2a_push_notification_config_test.exs` can drive
  `AshA2A.Protocol.JSONRPC.handle/3` -- the real transport-agnostic JSON-RPC dispatch
  layer that `AshA2A.Protocol.Plug` itself implements against (in the in-repo
  ported codec, `lib/ash_a2a/protocol/plug.ex`) -- with a handler that is
  actually wired to real ash_a2a dispatch, instead of an unused stub module.
  `handle_send/3` delegates to the real `EchoAgent.call/2` (in the in-repo
  ported codec, `lib/ash_a2a/protocol/agent.ex`), which in turn drives the real
  `AshA2A.Dispatcher.dispatch/5` behind the generated agent.

  `handle_get/3` and `handle_cancel/3` are real implementations too (not
  mocks) -- they simply return `AshA2A.Protocol.JSONRPC.Error.method_not_found/1` because
  this fixture only needs `handle_send/3` for the push-notification-config
  test, which never reaches any of these three callbacks at all: per the
  in-repo ported codec's `lib/ash_a2a/protocol/jsonrpc.ex`, every
  `"tasks/pushNotificationConfig/" <> _` method is intercepted by
  `AshA2A.Protocol.JSONRPC`'s own dispatch clause before any handler callback runs.
  """

  @behaviour AshA2A.Protocol.JSONRPC

  alias AshA2A.Test.Fixture.EchoAgent

  @impl AshA2A.Protocol.JSONRPC
  def handle_send(message, _params, _context) do
    case Process.get(:push_notification_call_counter) do
      nil -> :ok
      counter -> Agent.update(counter, &(&1 + 1))
    end

    EchoAgent.call(EchoAgent, message)
  end

  @impl AshA2A.Protocol.JSONRPC
  def handle_get(task_id, _params, _context) do
    {:error, AshA2A.Protocol.JSONRPC.Error.task_not_found(task_id)}
  end

  @impl AshA2A.Protocol.JSONRPC
  def handle_cancel(task_id, _params, _context) do
    {:error, AshA2A.Protocol.JSONRPC.Error.task_not_cancelable(task_id)}
  end
end
