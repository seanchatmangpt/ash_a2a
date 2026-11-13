# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.LiveSessionStreaming.LiveAgent do
  @moduledoc false
  use AshA2A.Protocol.Agent,
    name: "v5_live",
    description: "v1.1 live session fixture",
    capabilities: %{streaming: true, user_artifacts: true}

  alias AshA2A.Protocol.{Message, Part}

  @impl AshA2A.Protocol.Agent
  def handle_message(message, _context) do
    case Message.text(message) do
      "slow" ->
        send(:v5_probe, {:handler_started, self()})

        receive do
          :release -> {:reply, [Part.Text.new("slow done")]}
        end

      "answer" ->
        {:reply, [Part.Text.new("done")]}

      _ask ->
        {:input_required, [Part.Text.new("which one?")]}
    end
  end
end

defmodule AshA2A.LiveSessionStreaming.StreamOnlyAgent do
  @moduledoc false
  use AshA2A.Protocol.Agent,
    name: "v5_stream_only",
    description: "streaming without userArtifacts",
    capabilities: %{streaming: true}

  @impl AshA2A.Protocol.Agent
  def handle_message(_message, _context),
    do: {:input_required, [AshA2A.Protocol.Part.Text.new("more?")]}
end

defmodule AshA2A.LiveSessionStreaming.PlainAgent do
  @moduledoc false
  use AshA2A.Protocol.Agent, name: "v5_plain", description: "no capabilities"

  @impl AshA2A.Protocol.Agent
  def handle_message(_message, _context),
    do: {:reply, [AshA2A.Protocol.Part.Text.new("ok")]}
end

defmodule AshA2A.LiveSessionStreamingTest do
  use ExUnit.Case, async: false

  alias AshA2A.Protocol.{Message, StreamError}
  alias AshA2A.Protocol.Event.{ArtifactUpdate, StatusUpdate}
  alias AshA2A.Protocol.Task, as: T
  alias AshA2A.Transport.Live
  alias AshA2A.LiveSessionStreaming.{LiveAgent, PlainAgent, StreamOnlyAgent}

  setup do
    unless Process.whereis(AshA2A.Transport.Live.Registry),
      do: start_supervised!(Live.Supervisor)

    Process.register(self(), :v5_probe)
    :ok
  end

  defp start_agent(module) do
    name = :"v5_agent_#{System.unique_integer([:positive])}"

    start_supervised!(%{
      id: name,
      start: {module, :start_link, [[name: name]]}
    })

    name
  end

  defp msg(text, extra \\ %{}) do
    Map.merge(
      %{
        "messageId" => "m-#{System.unique_integer([:positive])}",
        "role" => "user",
        "parts" => [%{"text" => text}]
      },
      extra
    )
  end

  defp send_req(text, extra \\ %{}), do: %{"sendMessage" => %{"message" => msg(text, extra)}}

  defp open!(agent) do
    {:ok, session} = Live.open(agent, %{}, self())
    {session, Live.session_id(session)}
  end

  defp open_bound_on_ask(agent) do
    {session, sid} = open!(agent)
    assert :ok = Live.uplink(session, send_req("ask"))
    assert_receive {:a2a_live, ^sid, %T{status: %{state: :input_required}} = task}, 2_000
    {session, sid, task}
  end

  test "send_message opens with a snapshot, input_required, then a second message on the same stream" do
    agent = start_agent(LiveAgent)
    {session, sid, task} = open_bound_on_ask(agent)

    assert is_binary(task.id)
    refute Map.has_key?(task.metadata, :stream)

    # second message: no taskId, applies to the bound task
    assert :ok = Live.uplink(session, send_req("answer"))

    assert_receive {:a2a_live, ^sid, %StatusUpdate{status: %{state: :completed}} = status}, 2_000
    assert status.task_id == task.id
    assert is_integer(status.generation)
    assert_receive {:a2a_live_closed, ^sid, :terminal}, 2_000

    # downlink closed: session process cleaned itself up
    ref = Process.monitor(session)
    assert_receive {:DOWN, ^ref, :process, ^session, _}, 2_000
  end

  test "request naming a different task is a StreamError and the stream stays open" do
    agent = start_agent(LiveAgent)
    {session, sid, _task} = open_bound_on_ask(agent)

    bad = send_req("answer", %{"messageId" => "wrong-task-1", "taskId" => "tsk-someone-else"})
    assert :ok = Live.uplink(session, bad)

    assert_receive {:a2a_live, ^sid,
                    %StreamError{code: "INVALID_ARGUMENT", reference_id: "wrong-task-1"}},
                   2_000

    assert Process.alive?(session)

    # still usable
    assert :ok = Live.uplink(session, send_req("answer"))
    assert_receive {:a2a_live, ^sid, %StatusUpdate{status: %{state: :completed}}}, 2_000
  end

  test "subscribe after the first request is a StreamError, stream stays open" do
    agent = start_agent(LiveAgent)
    {session, sid, task} = open_bound_on_ask(agent)

    assert :ok = Live.uplink(session, %{"subscribe" => %{"taskId" => task.id}})
    assert_receive {:a2a_live, ^sid, %StreamError{code: "FAILED_PRECONDITION"}}, 2_000
    assert Process.alive?(session)
  end

  test "unknown payload kind and malformed requests are StreamErrors" do
    agent = start_agent(LiveAgent)
    {session, sid, _task} = open_bound_on_ask(agent)

    assert :ok = Live.uplink(session, %{"futureThing" => %{"x" => 1}})
    assert_receive {:a2a_live, ^sid, %StreamError{code: "UNIMPLEMENTED"}}, 2_000

    bad = %{
      "sendMessage" => %{
        "message" => %{
          "messageId" => "bad-1",
          "role" => "not-a-role",
          "parts" => [%{"text" => "x"}]
        }
      }
    }

    assert :ok = Live.uplink(session, bad)

    assert_receive {:a2a_live, ^sid,
                    %StreamError{code: "INVALID_ARGUMENT", reference_id: "bad-1"}},
                   2_000

    assert Process.alive?(session)
  end

  test "agent not accepting input is UNAVAILABLE while a send is in flight" do
    agent = start_agent(LiveAgent)
    {session, sid} = open!(agent)

    assert :ok = Live.uplink(session, send_req("slow"))
    assert_receive {:handler_started, handler}, 2_000

    assert :ok = Live.uplink(session, send_req("answer", %{"messageId" => "busy-1"}))

    assert_receive {:a2a_live, ^sid, %StreamError{code: "UNAVAILABLE", reference_id: "busy-1"}},
                   2_000

    send(handler, :release)
    assert_receive {:a2a_live, ^sid, %T{status: %{state: :completed}}}, 2_000
    assert_receive {:a2a_live_closed, ^sid, :terminal}, 2_000
  end

  test "subscribe-first opens with a snapshot of an existing task" do
    agent = start_agent(LiveAgent)
    {:ok, task} = AshA2A.Protocol.call(agent, "ask")
    {session, sid} = open!(agent)

    assert :ok = Live.uplink(session, %{"subscribe" => %{"taskId" => task.id}})
    assert_receive {:a2a_live, ^sid, %T{id: id, status: %{state: :input_required}}}, 2_000
    assert id == task.id
  end

  test "subscribe to an unknown task is not_found" do
    agent = start_agent(LiveAgent)
    {session, _sid} = open!(agent)

    assert {:error, :not_found} =
             Live.uplink(session, %{"subscribe" => %{"taskId" => "tsk-nope"}})

    # first request failed: stream is still unbound and usable
    assert :ok = Live.uplink(session, send_req("ask"))
  end

  test "subscribe with lastSeenGeneration skips the snapshot; unreplayable generation resyncs" do
    agent = start_agent(LiveAgent)
    {:ok, task} = AshA2A.Protocol.call(agent, "ask")
    seen = T.Generation.generation_of(task)

    {session, sid} = open!(agent)

    assert :ok =
             Live.uplink(session, %{
               "subscribe" => %{"taskId" => task.id, "lastSeenGeneration" => seen}
             })

    assert {:ack, %T{}} = Live.uplink_call(agent, %{}, send_req("answer", %{"taskId" => task.id}))

    assert_receive {:a2a_live, ^sid, first}, 2_000
    refute match?(%T{}, first)
    assert_receive {:a2a_live, ^sid, %StatusUpdate{status: %{state: :completed}}}, 2_000

    # a generation the server cannot replay from (in the future) -> snapshot
    agent2 = start_agent(LiveAgent)
    {:ok, task2} = AshA2A.Protocol.call(agent2, "ask")
    {session2, sid2} = open!(agent2)

    assert :ok =
             Live.uplink(session2, %{
               "subscribe" => %{"taskId" => task2.id, "lastSeenGeneration" => 9_999}
             })

    assert_receive {:a2a_live, ^sid2, %T{id: id2}}, 2_000
    assert id2 == task2.id
  end

  test "ack-only uplink call never duplicates events on the downlink" do
    agent = start_agent(LiveAgent)
    {_session, sid, task} = open_bound_on_ask(agent)

    assert {:ack, %T{id: id}} =
             Live.uplink_call(agent, %{}, send_req("answer", %{"taskId" => task.id}))

    assert id == task.id

    assert_receive {:a2a_live_closed, ^sid, :terminal}, 2_000

    # session is gone, so the mailbox is complete: exactly one completed status
    events = drain(sid)
    completed = Enum.filter(events, &match?(%StatusUpdate{status: %{state: :completed}}, &1))
    assert length(completed) == 1
    refute Enum.any?(events, &match?(%T{}, &1))
  end

  test "uplink_call routes by live_session_id and rejects unknown sessions" do
    agent = start_agent(LiveAgent)
    {_session, sid, _task} = open_bound_on_ask(agent)

    assert {:error, :unknown_session} =
             Live.uplink_call(agent, %{live_session_id: "live-nope"}, send_req("answer"))

    assert {:ack, %T{}} =
             Live.uplink_call(agent, %{live_session_id: sid}, send_req("answer"))

    assert_receive {:a2a_live, ^sid, %StatusUpdate{status: %{state: :completed}}}, 2_000
  end

  test "uplink_call without any downlink creates the task and returns only an ack" do
    agent = start_agent(LiveAgent)

    assert {:ack, %T{status: %{state: :input_required}}} =
             Live.uplink_call(agent, %{}, send_req("ask"))

    assert {:error, %StreamError{code: "FAILED_PRECONDITION"}} =
             Live.uplink_call(agent, %{}, %{"subscribe" => %{"taskId" => "tsk-x"}})
  end

  test "streaming must be declared" do
    plain = start_agent(PlainAgent)
    assert {:error, :unsupported_operation} = Live.open(plain, %{}, self())
    assert {:error, :unsupported_operation} = Live.uplink_call(plain, %{}, send_req("hi"))
  end

  test "artifactUpdates need user_artifacts" do
    agent = start_agent(StreamOnlyAgent)
    {session, sid} = open!(agent)

    req = %{
      "sendMessage" => %{
        "message" => msg("hi", %{"messageId" => "art-msg-1"}),
        "artifactUpdates" => [
          %{"artifact" => %{"artifactId" => "a1", "parts" => [%{"text" => "data"}]}}
        ]
      }
    }

    assert :ok = Live.uplink(session, req)

    assert_receive {:a2a_live, ^sid,
                    %StreamError{code: "UNSUPPORTED_OPERATION", reference_id: "art-msg-1"}},
                   2_000
  end

  test "client artifactUpdates are applied and observable as artifact updates" do
    agent = start_agent(LiveAgent)
    {session, sid, task} = open_bound_on_ask(agent)

    req = %{
      "sendMessage" => %{
        "message" => msg("ask again"),
        "artifactUpdates" => [
          %{
            "artifact" => %{"artifactId" => "client-a1", "parts" => [%{"text" => "payload"}]},
            "lastChunk" => true
          }
        ]
      }
    }

    assert :ok = Live.uplink(session, req)

    assert_receive {:a2a_live, ^sid, %ArtifactUpdate{artifact: %{artifact_id: "client-a1"}} = ev},
                   2_000

    assert ev.task_id == task.id
    assert is_integer(ev.generation)
  end

  test "downlink death cleans the session up" do
    agent = start_agent(LiveAgent)
    parent = self()

    dl =
      spawn(fn ->
        send(parent, :dl_up)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :dl_up, 2_000
    {:ok, session} = Live.open(agent, %{}, dl)
    ref = Process.monitor(session)
    send(dl, :stop)
    assert_receive {:DOWN, ^ref, :process, ^session, _}, 2_000
  end

  test "encode/1 yields the StreamResponse wrapper maps" do
    agent = start_agent(LiveAgent)
    {_session, _sid, task} = open_bound_on_ask(agent)

    assert %{"task" => %{"id" => id}} = Live.encode(task)
    assert id == task.id

    err = Live.encode(%StreamError{code: "UNAVAILABLE", reference_id: "r1"})
    assert %{"error" => %{"code" => "UNAVAILABLE", "referenceId" => "r1"}} = err
    assert %{"message" => _} = Live.encode(Message.new_agent("x"))
  end

  defp drain(sid, acc \\ []) do
    receive do
      {:a2a_live, ^sid, event} -> drain(sid, [event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
