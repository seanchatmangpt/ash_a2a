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
    # SLEEP-CLASS: SIMULATED-SLOW-HANDLER (handler must still be in flight when cancelled)
    Process.sleep(600)
    # An interrupted worker never reaches this effect.
    if probe, do: send(:erlang.binary_to_term(probe), :handler_finished)
    {:reply, [AshA2A.Protocol.Part.Text.new("done")]}
  end
end

defmodule AshA2A.ProtocolAgentInflightCancelTest do
  @moduledoc """
  Lane L01: in-flight cancel on the plain
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

  # Cancel-by-id of a fresh blocking send (W2-03).
  describe "admit_first: a fresh send is stored before its worker finishes" do
    test "tasks/get sees it and cancel by id interrupts the blocked send" do
      name = :"protocol_inflight_admit_#{System.unique_integer([:positive])}"
      start_supervised!({SlowAgent, [name: name, push_sender: nil]})

      test_pid = self()
      probe = :erlang.term_to_binary(test_pid)
      message = %{Message.new_user("go") | metadata: %{"probe" => probe}}

      sender =
        Task.async(fn ->
          SlowAgent.call(name, message, admit_first: true, notify: test_pid)
        end)

      assert_receive {:ash_a2a_task_admitted, task_id}, 1_000

      # The send is still blocked, yet the task is stored and readable.
      assert {:ok, %{status: %{state: state}}} = SlowAgent.get_task(name, task_id)
      assert state in [:submitted, :working]

      assert :ok = SlowAgent.cancel(name, task_id)

      # The blocked send is answered with the canceled task; the effect never runs.
      assert {:ok, %{id: ^task_id, status: %{state: :canceled}}} = Task.await(sender, 2_000)
      refute_receive :handler_finished, 900
      assert {:ok, %{status: %{state: :canceled}}} = SlowAgent.get_task(name, task_id)
    end

    test "another identity cannot cancel it through the owner-gated transport" do
      name = :"protocol_inflight_admit_owner_#{System.unique_integer([:positive])}"
      start_supervised!({SlowAgent, [name: name, push_sender: nil]})

      test_pid = self()
      probe = :erlang.term_to_binary(test_pid)

      message = %{
        Message.new_user("go")
        | metadata: %{"probe" => probe}
      }

      sender =
        Task.async(fn ->
          SlowAgent.call(name, message,
            admit_first: true,
            notify: test_pid,
            metadata: %{"ash_a2a.owner" => "alice", "probe" => probe}
          )
        end)

      assert_receive {:ash_a2a_task_admitted, task_id}, 1_000

      ctx = fn principal -> %{agent: name, principal: principal} end

      # Bob is refused exactly like a missing task, and nothing is canceled.
      assert {:error, _not_found} =
               AshA2A.Transport.Plug.handle_cancel(task_id, %{}, ctx.("bob"))

      assert {:error, :not_found} =
               GenServer.call(name, {:ash_a2a_get_task, "bob", task_id})

      assert {:ok, %{status: %{state: state}}} = SlowAgent.get_task(name, task_id)
      assert state in [:submitted, :working]

      # The owner can cancel it.
      assert {:ok, _wire_task} =
               AshA2A.Transport.Plug.handle_cancel(task_id, %{}, ctx.("alice"))

      assert {:ok, %{status: %{state: :canceled}}} = Task.await(sender, 2_000)
      refute_receive :handler_finished, 900
    end
  end
end
