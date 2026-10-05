defmodule AshA2A.V1ArtifactStreamingTest.StreamAgent do
  @moduledoc """
  Real `AshA2A.Agent` GenServer whose `handle_message/2` returns a real
  `{:stream, enum}` reply of three `Part.Text` chunks.

  Built with `use AshA2A.Agent` (not bare `use AshA2A.Protocol.Agent`) so it
  speaks the exact dialect `AshA2A.Transport.Plug` drives (`{:ash_a2a_get_task,
  ...}` owner-scoped reads, `AshA2A.Transport.Runtime` `{:message, ...}`
  handling), which is the emitter this file pins. `handle_message/2` is
  genuinely overridden (`defoverridable handle_message: 2`), so the
  `:resource_or_domain` fixture is never dispatched -- it exists only because
  `AshA2A.Agent.__using__/1` requires one.
  """

  use AshA2A.Agent,
    resource_or_domain: AshA2A.Test.Fixture.Echo,
    name: "v1_artifact_streaming_stream_agent"

  @impl AshA2A.Protocol.Agent
  def handle_message(_message, _context) do
    {:stream, Stream.map(1..3, fn i -> AshA2A.Protocol.Part.Text.new("chunk #{i}") end)}
  end
end

defmodule AshA2A.V1ArtifactStreamingTest.PlainAgent do
  @moduledoc """
  Real `AshA2A.Agent` GenServer whose `handle_message/2` returns a real
  non-streaming `{:reply, parts}` reply (two `Part.Text` parts), the shape
  `AshA2A.Transport.Runtime.apply_reply/2` folds into ONE artifact on the
  completed task.
  """

  use AshA2A.Agent,
    resource_or_domain: AshA2A.Test.Fixture.Echo,
    name: "v1_artifact_streaming_plain_agent"

  @impl AshA2A.Protocol.Agent
  def handle_message(_message, _context) do
    {:reply, [AshA2A.Protocol.Part.Text.new("answer-alpha"), AshA2A.Protocol.Part.Text.new("answer-beta")]}
  end
end

defmodule AshA2A.V1ArtifactStreamingTest do
  @moduledoc """
  Conformance court for A2A v1.0 artifact streaming/chunking semantics over
  the real stack: real `AshA2A.Agent` GenServers, the real
  `AshA2A.Transport.Plug` JSON-RPC/SSE pipeline (`lib/ash_a2a/transport/plug.ex`
  `stream_message/4`), the real codec (`AshA2A.Protocol.JSON`), and the real
  agent-side stream completion (`AshA2A.Protocol.Agent.Runtime.wrap_stream/3`
  -> `{:stream_done, ...}` cast). No mocks, no stubs; every reply is a real
  handler return, every frame is really encoded by the transport.

  Spec-vs-reality (A2A v1.0: `TaskArtifactUpdateEvent.append` -- "If true, the
  content of this artifact should be appended to a previously sent artifact
  with the same ID"; `lastChunk` -- "If true, this is the final chunk of the
  artifact"; `Artifact.artifactId` -- "unique within a task"; StreamResponse
  oneof `task | message | statusUpdate | artifactUpdate`; events delivered in
  generated order):

  | # | spec | reality (pinned here) |
  |---|------|------------------------|
  | 1 | chunked appends share one artifactId with `append: true` | holds on the wire: `stream_parts/4` emits ONE stable `art_*` id across the chunk frames, `append: true` on chunks 2..N, `lastChunk: true` on chunk N only |
  | 2 | final Task carries the accumulated artifact(s) | holds: after the stream drains, the agent folds all chunks into ONE artifact (parts in stream order) on the completed task |
  | 3 | artifactId unique within a task | chunk frames share one id; the final task's merged artifact id is minted by the foreign `{:stream_done, ...}` fold (`lib/ash_a2a/protocol/agent.ex`) which does not yet reuse the emitted id -- INTEGRATION ITEM, court (c) pins the current fold reality |
  | 4 | multiple artifacts per task (Task.artifacts is a set) | holds; a non-streaming reply is exactly one artifact, and the codec round-trips multi-artifact tasks |
  | 5 | append/lastChunk are wire booleans | the codec fully supports them (court (e) proves encode+decode round-trip) and the emitter now sets them on streamed chunks |
  """

  use ExUnit.Case, async: true

  alias AshA2A.Protocol.Event.ArtifactUpdate
  alias AshA2A.V1ArtifactStreamingTest.{PlainAgent, StreamAgent}

  # -- harness ---------------------------------------------------------------

  defp start_agent!(module) do
    name = :"v1_art_stream_#{System.unique_integer([:positive])}"
    start_supervised!({module, name: name})
    AshA2A.Transport.Plug.init(agent: name, base_url: "http://localhost:4000/a2a")
  end

  defp rpc(plug_opts, method, params) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => System.unique_integer([:positive]),
        "method" => method,
        "params" => params
      })

    result_map =
      :post
      |> Plug.Test.conn("/", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> AshA2A.Transport.Plug.call(plug_opts)
      |> Map.fetch!(:resp_body)
      |> Jason.decode!()

    assert %{"jsonrpc" => "2.0", "result" => result} = result_map
    result
  end

  defp stream_wire(plug_opts) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => System.unique_integer([:positive]),
        "method" => "message/stream",
        "params" => %{"message" => encoded_user_message()}
      })

    conn =
      :post
      |> Plug.Test.conn("/", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> AshA2A.Transport.Plug.call(plug_opts)

    assert conn.status == 200

    assert [ct] = Plug.Conn.get_resp_header(conn, "content-type")
    assert ct =~ "text/event-stream"
    assert Plug.Conn.get_resp_header(conn, "cache-control") == ["no-cache"]

    conn.resp_body
  end

  defp encoded_user_message do
    {:ok, encoded} = AshA2A.Protocol.JSON.encode(AshA2A.Protocol.Message.new_user("go"))
    encoded
  end

  # Every SSE frame's `result` is a v1.0 StreamResponse oneof: exactly one of
  # {"task" | "message" | "statusUpdate" | "artifactUpdate"}.
  defp sse_results(wire) do
    wire
    |> String.split("\n\n", trim: true)
    |> Enum.map(fn "data: " <> json -> Jason.decode!(json)["result"] end)
  end

  defp artifact_updates(results) do
    Enum.filter(results, &Map.has_key?(&1, "artifactUpdate"))
  end

  # tasks/get until the task is terminal-completed; the stream-completion cast
  # ({:stream_done, ...}) is asynchronous relative to the SSE response, so a
  # bounded real retry (no sleeps on the happy in-process path where the cast
  # is already FIFO-ahead of this call) keeps the court honest over any
  # transport ordering.
  defp completed_task(plug_opts, task_id, tries \\ 100)

  defp completed_task(plug_opts, task_id, tries) when tries > 0 do
    case rpc(plug_opts, "tasks/get", %{"id" => task_id}) do
      %{"status" => %{"state" => "TASK_STATE_COMPLETED"}} = task ->
        task

      _other ->
        Process.sleep(20)
        completed_task(plug_opts, task_id, tries - 1)
    end
  end

  defp completed_task(plug_opts, task_id, _tries) do
    flunk("task #{task_id} never reached TASK_STATE_COMPLETED: " <> inspect(rpc(plug_opts, "tasks/get", %{"id" => task_id})))
  end

  # -- court (a): streaming wire shape ----------------------------------------

  test "court (a): a 3-chunk stream emits a task snapshot, >=3 artifactUpdate frames, and a final terminal statusUpdate" do
    opts = start_agent!(StreamAgent)
    results = opts |> stream_wire() |> sse_results()

    assert [%{"task" => %{"id" => task_id} = snapshot} | rest] = results
    assert is_binary(task_id) and task_id != ""
    assert snapshot["contextId"] != nil

    updates = artifact_updates(rest)
    assert length(updates) >= 3

    # v1.0 StreamResponse discriminator: each frame is exactly one wrapper key.
    assert Enum.all?(results, fn frame ->
             map_size(frame) == 1 and
               (Map.has_key?(frame, "task") or Map.has_key?(frame, "statusUpdate") or
                  Map.has_key?(frame, "artifactUpdate") or Map.has_key?(frame, "message"))
           end)

    # The stream closes on the final event's terminal state (v1.0: finality is
    # the terminal TASK_STATE_*, not a "final" boolean).
    assert [%{"statusUpdate" => %{"status" => %{"state" => "TASK_STATE_COMPLETED"}}}] =
             Enum.slice(results, -1..-1//1)

    # v1.0 §TaskArtifactUpdateEvent chunking, as emitted by the real
    # AshA2A.Transport.Plug.stream_parts/4: every chunk frame carries the SAME
    # stable artifact id; chunk 1 is a new artifact (`append` unset);
    # chunks 2..N append; chunk N is the last chunk.
    assert [%{"artifactUpdate" => first} | rest_updates] = updates
    assert [%{"artifactUpdate" => last}] = Enum.slice(updates, -1..-1//1)

    chunk_id = first["artifact"]["artifactId"]
    assert chunk_id =~ ~r/^art-/

    refute Map.has_key?(first, "append"), "chunk 1 is a new artifact: no append"

    Enum.each(rest_updates, fn %{"artifactUpdate" => update} ->
      assert %{"artifact" => %{"artifactId" => ^chunk_id}} = update
      assert update["append"] == true, "chunks 2..N append to the shared artifact id"
    end)

    Enum.each(Enum.slice(updates, 0..-2//1), fn %{"artifactUpdate" => update} ->
      refute Map.has_key?(update, "lastChunk"), "only the final chunk marks lastChunk"
    end)

    assert last["lastChunk"] == true, "the final chunk marks lastChunk: true"
    assert %{"taskId" => ^task_id} = last

    Enum.each(updates, fn %{"artifactUpdate" => update} ->
      assert %{"taskId" => ^task_id, "artifact" => %{"parts" => [%{"text" => _}]}} = update
    end)

    # Real 3-chunk emitter => exactly 5 frames: snapshot + 3 updates + final.
    assert length(results) == 5
  end

  # -- court (b): accumulated artifacts on the completed task ------------------

  test "court (b): tasks/get after completion carries the accumulated artifact, parts in stream order" do
    opts = start_agent!(StreamAgent)
    [%{"task" => %{"id" => task_id}} | _] = opts |> stream_wire() |> sse_results()

    task = completed_task(opts, task_id)

    # The agent folds ALL streamed chunks into ONE artifact (parts in stream
    # order), not one artifact per chunk.
    assert [%{"artifactId" => artifact_id, "parts" => parts}] = task["artifacts"]

    assert Enum.map(parts, & &1["text"]) == ["chunk 1", "chunk 2", "chunk 3"]
    assert artifact_id =~ ~r/^art-/
  end

  # -- court (c): artifactId stability across the chunk sequence ----------------

  test "court (c): all streamed chunk frames share ONE stable artifactId, and the final task carries one merged artifact" do
    opts = start_agent!(StreamAgent)
    results = opts |> stream_wire() |> sse_results()
    [%{"task" => %{"id" => task_id}} | _] = results

    chunk_ids =
      results
      |> artifact_updates()
      |> Enum.map(fn %{"artifactUpdate" => %{"artifact" => %{"artifactId" => id}}} -> id end)

    # v1.0 reassembly semantics: the chunk sequence is addressable by one id.
    assert length(chunk_ids) == 3
    assert length(Enum.uniq(chunk_ids)) == 1
    assert hd(chunk_ids) =~ ~r/^art-/

    # The server-side accumulated artifact is ONE merged artifact with parts
    # in stream order, and its id is the SAME stable id the chunk frames
    # carried (the `{:stream_done, ...}` fold reuses the pre-minted
    # :stream_artifact_id — v1.0 reassembly keys on artifactId end to end).
    task = completed_task(opts, task_id)
    assert [%{"artifactId" => final_id, "parts" => [%{"text" => "chunk 1"}, _, _]}] = task["artifacts"]
    assert final_id == hd(chunk_ids)
  end

  # -- court (d): non-streaming handler ----------------------------------------

  test "court (d): a non-streaming reply is one artifactUpdate frame and exactly one artifact on the completed task" do
    opts = start_agent!(PlainAgent)
    results = opts |> stream_wire() |> sse_results()

    # Real shape: task snapshot, one artifactUpdate per task artifact (here 1),
    # then the final statusUpdate.
    assert [%{"task" => %{"id" => task_id}}, %{"artifactUpdate" => update}, %{"statusUpdate" => %{"status" => %{"state" => "TASK_STATE_COMPLETED"}}}] =
             results

    refute Map.has_key?(update, "append")
    refute Map.has_key?(update, "lastChunk")
    assert %{"taskId" => ^task_id, "artifact" => %{"parts" => [%{"text" => "answer-alpha"}, %{"text" => "answer-beta"}]}} =
             update

    task = completed_task(opts, task_id)
    assert [%{"artifactId" => _, "parts" => [%{"text" => "answer-alpha"}, %{"text" => "answer-beta"}]}] =
             task["artifacts"]
  end

  # -- court (e): codec round-trip of append/lastChunk -------------------------

  test "court (e): artifactUpdate frames encode/decode with append and lastChunk intact for every boolean combination" do
    artifact = AshA2A.Protocol.Artifact.new([AshA2A.Protocol.Part.Text.new("piece")], name: "replay")

    for append <- [true, false], last_chunk <- [true, false] do
      event =
        ArtifactUpdate.new("tsk-roundtrip", artifact,
          context_id: "ctx-roundtrip",
          append: append,
          last_chunk: last_chunk
        )

      {:ok, encoded} = AshA2A.Protocol.JSON.encode_stream_response(event)

      # false is a real value (put_unless_nil), so BOTH booleans always ride the wire.
      assert %{"artifactUpdate" => %{"append" => ^append, "lastChunk" => ^last_chunk} = inner} = encoded
      assert inner["taskId"] == "tsk-roundtrip"
      assert inner["contextId"] == "ctx-roundtrip"
      assert inner["artifact"]["artifactId"] == artifact.artifact_id

      assert {:ok, %ArtifactUpdate{} = decoded} = AshA2A.Protocol.JSON.decode(encoded, :event)
      assert decoded.append == append
      assert decoded.last_chunk == last_chunk
      assert decoded.task_id == "tsk-roundtrip"
      assert decoded.context_id == "ctx-roundtrip"
      assert decoded.artifact.artifact_id == artifact.artifact_id
      assert [%AshA2A.Protocol.Part.Text{text: "piece"}] = decoded.artifact.parts
    end
  end

  test "court (e): artifactUpdate frames without append/lastChunk omit both keys and decode back to nil flags" do
    event =
      ArtifactUpdate.new("tsk-bare", AshA2A.Protocol.Artifact.new([AshA2A.Protocol.Part.Text.new("x")]))

    {:ok, encoded} = AshA2A.Protocol.JSON.encode_stream_response(event)
    assert %{"artifactUpdate" => inner} = encoded
    refute Map.has_key?(inner, "append")
    refute Map.has_key?(inner, "lastChunk")

    assert {:ok, %ArtifactUpdate{append: nil, last_chunk: nil}} =
             AshA2A.Protocol.JSON.decode(encoded, :event)
  end

  test "court (e): the completed task's multiple-artifact shape round-trips through the task codec" do
    artifacts = [
      AshA2A.Protocol.Artifact.new([AshA2A.Protocol.Part.Text.new("first")], name: "one"),
      AshA2A.Protocol.Artifact.new([AshA2A.Protocol.Part.Text.new("second")], name: "two")
    ]

    task =
      AshA2A.Protocol.Task.new(id: "tsk-multi", artifacts: artifacts)
      |> AshA2A.Protocol.Agent.State.transition(:completed)

    {:ok, encoded} = AshA2A.Protocol.JSON.encode(task)

    assert {:ok, decoded} = AshA2A.Protocol.JSON.decode(encoded, :task)

    assert [%{artifact_id: id1, parts: [%AshA2A.Protocol.Part.Text{text: "first"}]},
            %{artifact_id: id2, parts: [%AshA2A.Protocol.Part.Text{text: "second"}]}] =
             decoded.artifacts

    assert id1 != id2
    assert decoded.status.state == :completed
  end
end
