defmodule AshA2A.V11CodecTest do
  @moduledoc """
  A2A v1.1 codec court: generation, timeline, artifact generations/role,
  MessageUpdate/StreamError, request decoders, and v1.0 legacy tolerance.
  Real encode/decode round trips; no doubles.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Protocol.{Artifact, Message, StreamError, TimelineEntry, JSON, Task}
  alias AshA2A.Protocol.Event.{ArtifactUpdate, MessageUpdate, StatusUpdate}
  alias AshA2A.Protocol.Task.Status

  defp rt(struct, type) do
    {:ok, map} = JSON.encode(struct)
    # force a real JSON hop
    map = map |> Jason.encode!() |> Jason.decode!()
    {map, JSON.decode!(map, type)}
  end

  defp user_msg(id \\ "m1"), do: %{Message.new_user("hi") | message_id: id}

  describe "Task generation + timeline" do
    test "round trips generation and timeline entries" do
      task = %Task{
        id: "t1",
        context_id: "c1",
        status: Status.new(:working),
        generation: 7,
        timeline: [
          %TimelineEntry{entry: {:message, user_msg()}, generation: 2},
          %TimelineEntry{entry: {:status, Status.new(:working)}, generation: 5}
        ]
      }

      {wire, back} = rt(task, :task)
      assert wire["generation"] == 7

      assert [%{"message" => _, "generation" => 2}, %{"status" => _, "generation" => 5}] =
               wire["timeline"]

      assert back.generation == 7

      assert [
               %TimelineEntry{entry: {:message, %Message{}}, generation: 2},
               %TimelineEntry{entry: {:status, %Status{state: :working}}, generation: 5}
             ] = back.timeline
    end

    test "generation 0 is omitted" do
      {:ok, wire} = JSON.encode(%Task{id: "t", status: Status.new(:submitted), generation: 0})
      refute Map.has_key?(wire, "generation")
    end

    test "int64 string generation decodes" do
      back =
        JSON.decode!(
          %{"id" => "t", "status" => %{"state" => "TASK_STATE_WORKING"}, "generation" => "12"},
          :task
        )

      assert back.generation == 12
    end

    test "legacy v1.0 minimal task decodes with default generation and empty timeline" do
      back = JSON.decode!(%{"id" => "t", "status" => %{"state" => "TASK_STATE_WORKING"}}, :task)
      assert back.generation == 1
      assert back.timeline == []
    end

    test "timeline fails open on unknown entry kind" do
      back =
        JSON.decode!(
          %{
            "id" => "t",
            "status" => %{"state" => "TASK_STATE_WORKING"},
            "timeline" => [%{"futureKind" => %{"x" => 1}, "generation" => 4}]
          },
          :task
        )

      assert [%TimelineEntry{entry: {:unknown, %{"futureKind" => %{"x" => 1}}}, generation: 4}] =
               back.timeline

      {:ok, wire} = JSON.encode(hd(back.timeline))
      assert wire == %{"futureKind" => %{"x" => 1}, "generation" => 4}
    end

    test "truncate_timeline keeps the last n" do
      entries = for g <- 1..3, do: %TimelineEntry{entry: {:unknown, nil}, generation: g}
      t = %Task{id: "t", status: Status.new(:working), timeline: entries}
      assert [%{generation: 3}] = Task.truncate_timeline(t, 1).timeline
      assert Task.truncate_timeline(t, 0).timeline == []
      assert Task.truncate_timeline(t, nil) == t
    end
  end

  describe "Artifact" do
    test "start/end generation and role round trip" do
      art = %Artifact{
        Artifact.new([AshA2A.Protocol.Part.Text.new("x")])
        | start_generation: 3,
          end_generation: 9,
          role: :user
      }

      {wire, back} = rt(art, :artifact)
      assert wire["startGeneration"] == 3
      assert wire["endGeneration"] == 9
      assert wire["role"] == "ROLE_USER"
      assert {back.start_generation, back.end_generation, back.role} == {3, 9, :user}
    end

    test "defaults omit the new members" do
      {wire, back} = rt(Artifact.new([AshA2A.Protocol.Part.Text.new("x")]), :artifact)
      refute Map.has_key?(wire, "startGeneration")
      refute Map.has_key?(wire, "role")
      assert {back.start_generation, back.end_generation, back.role} == {nil, nil, nil}
    end
  end

  describe "events" do
    test "status and artifact updates carry generation" do
      {w1, b1} =
        rt(StatusUpdate.new("t", Status.new(:working), generation: 4), :status_update_event)

      assert w1["generation"] == 4 and b1.generation == 4

      art = Artifact.new([AshA2A.Protocol.Part.Text.new("x")])
      {w2, b2} = rt(ArtifactUpdate.new("t", art, generation: 6), :artifact_update_event)
      assert w2["generation"] == 6 and b2.generation == 6
    end

    test "nil generation omitted on events" do
      {:ok, w} = JSON.encode(StatusUpdate.new("t", Status.new(:working)))
      refute Map.has_key?(w, "generation")
    end

    test "MessageUpdate round trips through the StreamResponse wrapper" do
      ev =
        MessageUpdate.new("t", user_msg(),
          context_id: "c",
          generation: 8,
          metadata: %{"k" => "v"}
        )

      {:ok, wrapped} = JSON.encode_stream_response(ev)
      assert Map.keys(wrapped) == ["messageUpdate"]
      back = wrapped |> Jason.encode!() |> Jason.decode!() |> JSON.decode!(:event)

      assert %MessageUpdate{task_id: "t", context_id: "c", generation: 8, metadata: %{"k" => "v"}} =
               back

      assert %Message{} = back.message
    end

    test "StreamError round trips through the StreamResponse wrapper" do
      err = %StreamError{
        task_id: "t",
        code: "INVALID_ARGUMENT",
        message: "bad",
        reference_id: "m1",
        metadata: %{"a" => 1}
      }

      {:ok, wrapped} = JSON.encode_stream_response(err)
      assert %{"error" => %{"code" => "INVALID_ARGUMENT", "referenceId" => "m1"}} = wrapped
      assert ^err = wrapped |> Jason.encode!() |> Jason.decode!() |> JSON.decode!(:event)
    end

    test "unknown StreamResponse payload kind is skipped, not an error" do
      assert {:skip, {:unknown_payload, "futureThing"}} =
               JSON.decode(%{"futureThing" => %{"a" => 1}}, :event)
    end

    test "known v1.0 wrappers still decode" do
      assert %StatusUpdate{} =
               JSON.decode!(
                 %{
                   "statusUpdate" => %{
                     "taskId" => "t",
                     "status" => %{"state" => "TASK_STATE_WORKING"}
                   }
                 },
                 :event
               )
    end
  end

  describe "card + push config" do
    test "userArtifacts capability round trips" do
      card = %AshA2A.Protocol.AgentCard{
        name: "a",
        description: "d",
        url: "https://a",
        version: "1",
        skills: [],
        capabilities: %{user_artifacts: true}
      }

      wire = JSON.encode_agent_card(card, url: "https://a") |> Jason.encode!() |> Jason.decode!()
      assert wire["capabilities"]["userArtifacts"] == true
      assert {:ok, back} = JSON.decode_agent_card(wire)
      assert back.capabilities.user_artifacts == true
    end

    test "push config protocolVersion round trips and is optional" do
      cfg = %AshA2A.Protocol.PushNotificationConfig{url: "https://h", protocol_version: "1.1"}
      {wire, back} = rt(cfg, :push_notification_config)
      assert wire["protocolVersion"] == "1.1"
      assert back.protocol_version == "1.1"

      {w2, b2} =
        rt(%AshA2A.Protocol.PushNotificationConfig{url: "https://h"}, :push_notification_config)

      refute Map.has_key?(w2, "protocolVersion")
      assert b2.protocol_version == nil
    end
  end

  describe "request decoders" do
    @msg %{"messageId" => "m1", "role" => "ROLE_USER", "parts" => [%{"text" => "hi"}]}
    @art_update %{
      "taskId" => "t",
      "contextId" => "c",
      "artifact" => %{"artifactId" => "a1", "parts" => [%{"text" => "x"}], "role" => "ROLE_USER"}
    }

    test "SendMessageRequest legacy v1.0 shape" do
      assert {:ok, %{message: %Message{}, artifact_updates: [], configuration: nil}} =
               JSON.decode_send_message_request(%{"message" => @msg})
    end

    test "message required without artifactUpdates" do
      assert {:error, {:missing_field, "message"}} = JSON.decode_send_message_request(%{})
    end

    test "message optional with artifactUpdates" do
      assert {:ok, %{message: nil, artifact_updates: [%ArtifactUpdate{task_id: "t"} = u]}} =
               JSON.decode_send_message_request(%{"artifactUpdates" => [@art_update]})

      assert u.artifact.role == :user
    end

    test "configuration carries timelineLength, historyLength, ifGenerationMatch" do
      assert {:ok, %{configuration: cfg}} =
               JSON.decode_send_message_request(%{
                 "message" => @msg,
                 "configuration" => %{
                   "timelineLength" => 5,
                   "historyLength" => 2,
                   "ifGenerationMatch" => "9",
                   "returnImmediately" => true
                 }
               })

      assert %{
               timeline_length: 5,
               history_length: 2,
               if_generation_match: 9,
               return_immediately: true
             } = cfg
    end

    test "GetTask / ListTasks / Subscribe v1.1 members" do
      assert {:ok, %{id: "t", timeline_length: 3, current_generation: 4}} =
               JSON.decode_get_task_request(%{
                 "id" => "t",
                 "timelineLength" => 3,
                 "currentGeneration" => 4
               })

      assert {:ok, %{id: "t", current_generation: nil, timeline_length: nil}} =
               JSON.decode_get_task_request(%{"id" => "t"})

      assert {:ok, %{timeline_length: 2}} =
               JSON.decode_list_tasks_request(%{"timelineLength" => 2})

      assert {:ok, %{id: "t", last_seen_generation: 11}} =
               JSON.decode_subscribe_request(%{"id" => "t", "lastSeenGeneration" => 11})

      assert {:ok, %{last_seen_generation: nil}} = JSON.decode_subscribe_request(%{"id" => "t"})
    end

    test "StreamRequest sendMessage / subscribe / unknown payload" do
      assert {:ok, %{tenant: "x", payload: {:send_message, %{message: %Message{}}}}} =
               JSON.decode_stream_request(%{
                 "tenant" => "x",
                 "sendMessage" => %{"message" => @msg}
               })

      assert {:ok, %{payload: {:subscribe, %{id: "t"}}}} =
               JSON.decode_stream_request(%{"subscribe" => %{"id" => "t"}})

      assert {:error, {:unknown_payload, ["futureOp"]}} =
               JSON.decode_stream_request(%{"tenant" => "x", "futureOp" => %{}})
    end
  end
end
