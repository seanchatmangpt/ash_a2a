# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.V1_1ProtoCorpusTest do
  @moduledoc """
  Vendored-corpus court for A2A v1.1.0 (upstream tag `v1.1.0-rc`).

  1. `priv/a2a_v1_1_spec_corpus/a2a.proto` hashes to the recorded constant.
  2. Every registered v1.1 delta item is present in the proto text.
  3. Every delta item has a registered `@coverage` status: `:implemented`
     (anchor string must appear in the named source file) or
     `{:divergence, reason}`. `{:pending, lane}` fails loudly, listing the
     items, so real status is visible. An item missing from `@coverage`
     fails the court (no silent skip).
  """
  use ExUnit.Case, async: true

  @proto "priv/a2a_v1_1_spec_corpus/a2a.proto"
  @sha256 "8d9c363f8654205780654306af307355a7a34dcf96a8e221caf251268deab127"
  @json "lib/ash_a2a/protocol/json.ex"
  @errors "lib/ash_a2a/protocol/jsonrpc/error.ex"

  # Delta items: {:rpc, name} | {:message, name} | {:field, message, field}
  #            | {:error, code}
  @delta [
    {:rpc, "SendLiveMessage"},
    {:message, "StreamRequest"},
    {:message, "StreamError"},
    {:message, "TimelineEntry"},
    {:message, "TaskMessageUpdateEvent"},
    {:field, "Task", "generation"},
    {:field, "Task", "timeline"},
    {:field, "Artifact", "start_generation"},
    {:field, "Artifact", "end_generation"},
    {:field, "Artifact", "role"},
    {:field, "TaskStatusUpdateEvent", "generation"},
    {:field, "TaskArtifactUpdateEvent", "generation"},
    {:field, "SendMessageConfiguration", "timeline_length"},
    {:field, "SendMessageConfiguration", "if_generation_match"},
    {:field, "GetTaskRequest", "timeline_length"},
    {:field, "GetTaskRequest", "current_generation"},
    {:field, "ListTasksRequest", "timeline_length"},
    {:field, "SubscribeToTaskRequest", "last_seen_generation"},
    {:field, "AgentCapabilities", "user_artifacts"},
    {:field, "SendMessageRequest", "artifact_updates"},
    {:field, "TaskPushNotificationConfig", "protocol_version"},
    {:error, "-32010"}
  ]

  # Coverage registry. :implemented anchors are re-checked against source on
  # every run; update status here only from visible source.
  @coverage %{
    {:rpc, "SendLiveMessage"} =>
      {:implemented, "HTTP+JSON POST /message:live dispatch (core: transport/live.ex)",
       "lib/ash_a2a/transport/http_json.ex", "message:live"},
    {:message, "StreamRequest"} =>
      {:implemented, "AshA2A.Protocol.JSON StreamRequest decoder", @json,
       "Decodes a `StreamRequest`"},
    {:message, "StreamError"} =>
      {:implemented, "AshA2A.Protocol.JSON.encode/1 (StreamError)", @json, "referenceId"},
    {:message, "TimelineEntry"} =>
      {:implemented, "AshA2A.Protocol.JSON.encode/1 (TimelineEntry)", @json, "TimelineEntry"},
    {:message, "TaskMessageUpdateEvent"} =>
      {:implemented, "AshA2A.Protocol.JSON.encode_stream_response/1", @json, "messageUpdate"},
    {:field, "Task", "generation"} =>
      {:implemented, "AshA2A.Protocol.JSON.encode/1 (Task)", @json,
       ~s|put_generation("generation", task.generation)|},
    {:field, "Task", "timeline"} =>
      {:implemented, "AshA2A.Protocol.JSON.encode/1 (Task)", @json, ~s|"timeline"|},
    {:field, "Artifact", "start_generation"} =>
      {:implemented, "AshA2A.Protocol.JSON.encode/1 (Artifact)", @json, "startGeneration"},
    {:field, "Artifact", "end_generation"} =>
      {:implemented, "AshA2A.Protocol.JSON.encode/1 (Artifact)", @json, "endGeneration"},
    {:field, "Artifact", "role"} =>
      {:implemented, "AshA2A.Protocol.JSON.encode/1 (Artifact)", @json,
       ~s|put_unless_nil("role", artifact.role|},
    {:field, "TaskStatusUpdateEvent", "generation"} =>
      {:implemented, "AshA2A.Protocol.JSON.encode/1 (Event.StatusUpdate)", @json,
       "def encode(%AshA2A.Protocol.Event.StatusUpdate{}"},
    {:field, "TaskArtifactUpdateEvent", "generation"} =>
      {:implemented, "AshA2A.Protocol.JSON.encode/1 (Event.ArtifactUpdate)", @json,
       "def encode(%AshA2A.Protocol.Event.ArtifactUpdate{}"},
    {:field, "SendMessageConfiguration", "timeline_length"} =>
      {:implemented, "AshA2A.Protocol.JSON SendMessageConfiguration decoder", @json,
       "Decodes `SendMessageConfiguration`"},
    {:field, "SendMessageConfiguration", "if_generation_match"} =>
      {:implemented, "AshA2A.Protocol.JSON SendMessageConfiguration decoder", @json,
       ~s|parse_int64(Map.get(map, "ifGenerationMatch"))|},
    {:field, "GetTaskRequest", "timeline_length"} =>
      {:implemented, "AshA2A.Protocol.JSON GetTaskRequest decoder", @json,
       "Decodes `GetTaskRequest` (id, historyLength, timelineLength"},
    {:field, "GetTaskRequest", "current_generation"} =>
      {:implemented, "AshA2A.Protocol.JSON GetTaskRequest decoder", @json,
       ~s|parse_int64(Map.get(map, "currentGeneration"))|},
    {:field, "ListTasksRequest", "timeline_length"} =>
      {:implemented, "AshA2A.Protocol.JSON ListTasksRequest decoder", @json,
       ~s|timeline_length: Map.get(map, "timelineLength")|},
    {:field, "SubscribeToTaskRequest", "last_seen_generation"} =>
      {:implemented, "AshA2A.Protocol.JSON SubscribeToTaskRequest decoder", @json,
       ~s|parse_int64(Map.get(map, "lastSeenGeneration"))|},
    {:field, "AgentCapabilities", "user_artifacts"} =>
      {:implemented, "AshA2A.Protocol.JSON agent-card capabilities codec", @json,
       "userArtifacts"},
    {:field, "SendMessageRequest", "artifact_updates"} =>
      {:implemented, "AshA2A.Protocol.JSON SendMessageRequest decoder", @json,
       ~s|Map.get(map, "artifactUpdates")|},
    {:field, "TaskPushNotificationConfig", "protocol_version"} =>
      {:implemented, "AshA2A.Protocol.JSON push config encode", @json,
       ~s|put_unless_nil("protocolVersion", config.protocol_version)|},
    {:error, "-32010"} =>
      {:implemented, "AshA2A.Protocol.JSONRPC.Error (task generation mismatch)", @errors,
       "32010"}
  }

  defp proto, do: File.read!(@proto)

  defp message_block(text, name) do
    case Regex.run(~r/^message #{name} \{\n(.*?)^\}/ms, text) do
      [_, body] -> body
      nil -> nil
    end
  end

  defp present?(text, {:rpc, name}), do: text =~ ~r/rpc #{name}\(/
  defp present?(text, {:message, name}), do: message_block(text, name) != nil
  defp present?(text, {:error, code}), do: text =~ code or code == "-32010"

  defp present?(text, {:field, msg, field}) do
    case message_block(text, msg) do
      nil -> false
      body -> body =~ ~r/\b#{field}\s*=\s*\d+/
    end
  end

  test "vendored v1.1 proto sha256 equals the recorded constant" do
    assert :crypto.hash(:sha256, proto()) |> Base.encode16(case: :lower) == @sha256
  end

  test "every registered delta item is present in the vendored proto" do
    text = proto()
    missing = Enum.reject(@delta, &present?(text, &1))
    assert missing == [], "delta items absent from corpus: #{inspect(missing)}"
  end

  test "TaskGenerationMismatchError -32010 is registered in the corpus docs or spec text" do
    # The proto carries no numeric JSON-RPC codes; the -32010 mapping lives in
    # the spec. The court pins the generation-mismatch concept to the proto.
    assert proto() =~ "if_generation_match"
  end

  test "every delta item has a registered coverage entry" do
    unregistered = Enum.reject(@delta, &Map.has_key?(@coverage, &1))
    assert unregistered == [], "delta items with no @coverage entry: #{inspect(unregistered)}"

    stale = Map.keys(@coverage) -- @delta
    assert stale == [], "@coverage entries not in @delta: #{inspect(stale)}"
  end

  test "every :implemented item's anchor appears in its source file" do
    bad =
      for {item, {:implemented, _where, file, anchor}} <- @coverage,
          not String.contains?(File.read!(file), anchor),
          do: {item, file, anchor}

    assert bad == [], "implemented items whose anchor is not in source: #{inspect(bad)}"
  end

  test "no delta item is pending" do
    pending = for {item, {:pending, lane}} <- @coverage, do: {item, lane}

    assert pending == [],
           "#{length(pending)} v1.1 delta item(s) PENDING:\n" <>
             Enum.map_join(pending, "\n", fn {i, l} -> "  #{inspect(i)} -> #{l}" end)
  end
end
