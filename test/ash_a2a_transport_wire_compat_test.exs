# Lane V8-Q6-f (2026-11-08): Q6 wire-conversion boundary test.
#
# Chicago discipline: real structs, real conversion calls, final-state
# assertions — no doubles. ash_a2a does not depend on the `a2a` hex
# package, so the test defines the minimal real mirror structs
# (field-identical to `a2a` 0.3.0) at the TOP LEVEL under the real module
# names (`A2A.*`) and drives the real conversion functions against them.

defmodule A2A.Part.Text do
  defstruct text: "", metadata: %{}
end

defmodule A2A.Part.Data do
  defstruct data: %{}, metadata: %{}
end

defmodule A2A.Part.File do
  defstruct file: nil, metadata: %{}
end

defmodule A2A.FileContent do
  defstruct [:name, :mime_type, :bytes, :uri]
end

defmodule A2A.Task.Status do
  defstruct [:state, :message, :timestamp]
end

defmodule A2A.Message do
  @enforce_keys [:role, :parts]
  defstruct [
    :message_id,
    :role,
    :task_id,
    :context_id,
    parts: [],
    reference_task_ids: [],
    metadata: %{},
    extensions: %{}
  ]
end

defmodule A2A.Task do
  @enforce_keys [:id, :status]
  defstruct [
    :id,
    :context_id,
    :status,
    history: [],
    artifacts: [],
    metadata: %{}
  ]
end

defmodule A2A.Artifact do
  @enforce_keys [:parts]
  defstruct [
    :artifact_id,
    :name,
    :description,
    parts: [],
    extensions: [],
    metadata: %{}
  ]
end

defmodule AshA2A.Transport.WireCompatTest do
  use ExUnit.Case, async: true

  alias AshA2A.Transport.WireCompat

  # -- wire_message?/1 ---------------------------------------------------------

  test "detects a wire-shaped A2A.Message and not a protocol message" do
    wire = %A2A.Message{message_id: "m1", role: :user, parts: []}
    proto = %AshA2A.Protocol.Message{role: :user, parts: []}

    assert WireCompat.wire_message?(wire)
    refute WireCompat.wire_message?(proto)
    refute WireCompat.wire_message?(%{role: :user})
  end

  # -- inbound: wire -> protocol -------------------------------------------------

  test "to_protocol converts a wire message with data part to protocol" do
    wire =
      %A2A.Message{
        message_id: "msg-1",
        role: :user,
        parts: [%A2A.Part.Data{data: %{"x" => 1}}],
        metadata: %{"skill" => "some_skill"}
      }

    converted = WireCompat.to_protocol(wire)

    assert %AshA2A.Protocol.Message{} = converted
    assert converted.message_id == "msg-1"
    assert converted.role == :user
    assert converted.metadata == %{"skill" => "some_skill"}

    assert [%AshA2A.Protocol.Part.Data{data: %{"x" => 1}}] = converted.parts
  end

  test "to_protocol passes protocol messages through unchanged" do
    proto = %AshA2A.Protocol.Message{
      role: :user,
      parts: [AshA2A.Protocol.Part.Text.new("hi")],
      message_id: "m-2"
    }

    assert WireCompat.to_protocol(proto) == proto
  end

  test "to_protocol recurses into text and file parts" do
    wire =
      %A2A.Message{
        role: :user,
        parts: [
          %A2A.Part.Text{text: "hello"},
          %A2A.Part.File{file: %A2A.FileContent{name: "a.txt", mime_type: "text/plain"}}
        ]
      }

    converted = WireCompat.to_protocol(wire)

    assert [
             %AshA2A.Protocol.Part.Text{text: "hello"},
             %AshA2A.Protocol.Part.File{
               file: %AshA2A.Protocol.FileContent{name: "a.txt", mime_type: "text/plain"}
             }
           ] = converted.parts
  end

  # -- outbound: protocol -> wire (encode clause) ---------------------------------

  test "to_wire converts {:ok, task} to wire task with wire status and history" do
    agent_message = %AshA2A.Protocol.Message{
      role: :agent,
      parts: [AshA2A.Protocol.Part.Text.new("done")],
      message_id: "m-3"
    }

    task = %AshA2A.Protocol.Task{
      id: "tsk-1",
      status: AshA2A.Protocol.Task.Status.new(:completed),
      history: [agent_message],
      artifacts: [AshA2A.Protocol.Artifact.new([AshA2A.Protocol.Part.Text.new("r")])]
    }

    {:ok, converted} = WireCompat.to_wire({:ok, task})

    assert %A2A.Task{} = converted
    assert converted.id == "tsk-1"
    assert %A2A.Task.Status{state: :completed} = converted.status

    assert [
             %A2A.Message{role: :agent, parts: [%A2A.Part.Text{text: "done"}]}
           ] = converted.history

    assert [%A2A.Artifact{parts: [%A2A.Part.Text{text: "r"}]}] = converted.artifacts
  end

  test "to_wire converts {:ok, message} and passes errors through" do
    proto = %AshA2A.Protocol.Message{
      role: :agent,
      parts: [AshA2A.Protocol.Part.Text.new("hi")],
      message_id: "m-4"
    }

    assert {:ok, %A2A.Message{}} = WireCompat.to_wire({:ok, proto})
    assert {:error, :whatever} = WireCompat.to_wire({:error, :whatever})
    assert WireCompat.to_wire(:bare) == :bare
  end

  # -- mirror round-trip: wire -> protocol -> wire ----------------------------------

  test "wire -> protocol -> wire round-trips a full message tree" do
    wire =
      %A2A.Message{
        message_id: "m-5",
        role: :user,
        parts: [%A2A.Part.Data{data: %{"k" => [1, 2]}}]
      }

    round_tripped =
      wire
      |> WireCompat.to_protocol()
      |> then(&{:ok, &1})
      |> WireCompat.to_wire()
      |> elem(1)

    assert round_tripped == wire
  end
end
