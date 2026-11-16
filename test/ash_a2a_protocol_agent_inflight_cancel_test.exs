defmodule AshA2A.ProtocolAgentInflightCancelTest.SlowAgent do
  @moduledoc false
  use AshA2A.Protocol.Agent,
    name: "protocol_inflight_cancel_agent",
    description: "Slow handler for in-flight cancel",
    version: "0.1.0",
    skills: []

  @impl AshA2A.Protocol.Agent
  def handle_message(message, _context) do
    probe = message.metadata && message.metadata["probe"]
    Process.sleep(600)
    # An interrupted worker never reaches this effect.
    if probe, do: send(:erlang.binary_to_term(probe), :handler_finished)
    {:reply, [AshA2A.Protocol.Part.Text.new("done")]}
  end
end

defmodule AshA2A.ProtocolAgentInflightCancelTest do
  @moduledoc """
  Lane L01 (UNVERIFIED, not yet run): in-flight cancel on the plain
  `AshA2A.Protocol.Agent` path (A2A v1.0 section 3.1.5). A
  `return_immediately` task whose handler is still sleeping is canceled; the
  worker is killed, so its effect never commits and the stored task stays
  `:canceled`.
  """
  use ExUnit.Case, async: true

  alias AshA2A.Protocol.Message
  alias AshA2A.ProtocolAgentInflightCancelTest.SlowAgent

  test "cancel kills the in-flight worker; effect never commits, task stays canceled" do
    name = :"protocol_inflight_cancel_#{System.unique_integer([:positive])}"
    start_supervised!({SlowAgent, [name: name, push_sender: nil]})

    probe = :erlang.term_to_binary(self())
    message = %{Message.new_user("go") | metadata: %{"probe" => probe}}

    assert {:ok, %{id: task_id}} = SlowAgent.call(name, message, return_immediately: true)

    assert :ok = SlowAgent.cancel(name, task_id)

    refute_receive :handler_finished, 900

    assert {:ok, %{status: %{state: :canceled}}} = SlowAgent.get_task(name, task_id)

    # Idempotent repeat.
    assert :ok = SlowAgent.cancel(name, task_id)
  end
end
