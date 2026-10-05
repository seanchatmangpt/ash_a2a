defmodule AshA2A.Protocol.V1RejectedStateTest do
  @moduledoc """
  v1.0 REJECTED terminal state: real producer proof.

  The v22 court proved the REJECTED vocabulary is declared (wire map
  `AshA2A.Protocol.JSON`, conformance terminal list, `AshA2A.TaskLifecycle`
  states) but produced by NO code path. This file proves the landed producer:
  an admission-phase refusal -- an authority-gate denial or a
  capability-resolution refusal before the handler has any effect -- drives a
  real, supervised `AshA2A.Protocol.Agent` task to the real terminal
  `:rejected` state, encodes on the wire as `TASK_STATE_REJECTED`, refuses
  continuation, and is not cancelable; while a genuine mid-handler error
  still lands `:failed` (regression control).

  Chicago-style: a real `use AshA2A.Protocol.Agent` GenServer under a real
  `AshA2A.Protocol.AgentSupervisor`, real `call/3` traffic, real state-based
  assertions on the returned and re-fetched task structs, and the real wire
  codec -- no Mock/mox/patch/monkeypatch.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Protocol.{JSON, Message, Part, Task}

  defmodule RejectionAgent do
    @moduledoc """
    Real `AshA2A.Protocol.Agent` whose `handle_message/2` emits the exact
    refusal shapes the real dispatch machinery produces at admission, before
    any handler effect:

    * `"forbidden: <message>"` -- the folded form `AshA2A.Dispatcher.to_reply/1`
      emits for an Ash `class: :forbidden` denial (`class_message/2`), i.e.
      the authority gate.
    * `{:no_skill, _}` -- the capability-resolution refusal
      `AshA2A.Agent.resolve_skill_name/2` emits when no capability can be
      named for the request.
    * a plain binary error -- attempted-and-errored, the `:failed` control.
    """

    use AshA2A.Protocol.Agent,
      name: "v1_rejected_state_agent",
      description: "Produces the v1.0 REJECTED terminal state from real admission refusals.",
      skills: [
        %{
          id: "greet",
          name: "greet",
          description: "Echoes the request text back.",
          tags: []
        }
      ]

    @impl AshA2A.Protocol.Agent
    def handle_message(message, _context) do
      case Message.text(message) do
        "forbidden" ->
          # The exact folded authority-gate form the real dispatcher emits for
          # an Ash.Policy.Authorizer denial (dispatcher.ex class_message/2).
          {:error, "forbidden: denied by policy"}

        "no-skill" ->
          # The exact capability-resolution refusal resolve_skill_name/2 emits.
          {:error, {:no_skill, __MODULE__}}

        "boom" ->
          # Attempted-and-errored: the handler ran and failed mid-run.
          {:error, "disk on fire"}

        text ->
          {:reply, [Part.Text.new("ok: " <> text)]}
      end
    end
  end

  setup do
    {_sup, _registry} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [RejectionAgent])

    :ok
  end

  defp call(text, opts \\ []), do: RejectionAgent.call(RejectionAgent, Message.new_user(text), opts)

  test "authority-gate refusal lands the task terminal :rejected with a redacted reason" do
    assert {:ok, task} = call("forbidden")

    assert task.status.state == :rejected
    assert Task.terminal?(task)

    # The redacted reason is the wire-visible status message.
    assert %Message{role: :agent} = status_msg = task.status.message
    [text_part] = status_msg.parts
    assert text_part.text =~ "Rejected:"

    # Terminal :rejected is genuinely not cancelable, through the agent's own
    # cancel guard -- the state feeds back into real behavior, not a label.
    assert {:error, :not_cancelable} = RejectionAgent.cancel(RejectionAgent, task.id)

    # Persisted as :rejected in the agent's real state, not just returned
    # transiently.
    assert {:ok, %Task{status: %AshA2A.Protocol.Task.Status{state: :rejected}}} =
             RejectionAgent.get_task(RejectionAgent, task.id)
  end

  test "rejected task encodes on the wire as TASK_STATE_REJECTED" do
    assert {:ok, task} = call("forbidden")

    assert {:ok, encoded} = JSON.encode(task)
    assert encoded["status"]["state"] == "TASK_STATE_REJECTED"

    # The wire state round-trips back through the real codec.
    assert {:ok, decoded} = JSON.decode(encoded, :task)
    assert decoded.status.state == :rejected

    # And survives a real Jason encoding of the whole wire map.
    assert Jason.encode!(encoded) =~ "TASK_STATE_REJECTED"
  end

  test "follow-up continuation on the rejected task gets the documented refusal" do
    assert {:ok, task} = call("forbidden")

    assert {:error, :not_continuable} =
             RejectionAgent.call(RejectionAgent, Message.new_user("try again"),
               task_id: task.id
             )
  end

  test "capability-resolution refusal also lands terminal :rejected" do
    assert {:ok, task} = call("no-skill")

    assert task.status.state == :rejected
    assert Task.terminal?(task)
    assert {:error, :not_continuable} =
             RejectionAgent.call(RejectionAgent, Message.new_user("try again"),
               task_id: wire_id(task)
             )
  end

  test "a genuine handler error still lands terminal :failed (regression control)" do
    assert {:ok, task} = call("boom")

    assert task.status.state == :failed
    assert Task.terminal?(task)

    assert %Message{role: :agent} = status_msg = task.status.message
    [text_part] = status_msg.parts
    assert text_part.text =~ "Error:"
    assert text_part.text =~ "disk on fire"

    assert {:ok, %Task{status: %AshA2A.Protocol.Task.Status{state: :failed}}} =
             RejectionAgent.get_task(RejectionAgent, task.id)
  end

  defp wire_id(%Task{id: id}), do: id
end
