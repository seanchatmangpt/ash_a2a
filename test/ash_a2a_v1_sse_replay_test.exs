defmodule AshA2A.V1SSEReplayTest.SlowStreamAgent do
  @moduledoc false
  # Real `AshA2A.Protocol.Agent` GenServer whose `handle_message/2` returns a
  # slow lazy stream (5 text parts, 60 ms apart) so a subscriber can be killed
  # mid-stream and a second connection can resubscribe while the task is still
  # live, exactly as a reconnecting v1.0 client would.
  use AshA2A.Protocol.Agent, name: "v1-sse-replay", description: "streams five parts slowly"

  @impl AshA2A.Protocol.Agent
  def handle_message(_message, _context) do
    {:stream,
     Stream.map(1..5, fn i ->
       Process.sleep(60)
       AshA2A.Protocol.Part.Text.new("part #{i}")
     end)}
  end
end

defmodule AshA2A.V1SSEReplayTest do
  @moduledoc """
  A2A v1.0 conformance court for `tasks/resubscribe` and SSE `Last-Event-ID`
  backlog replay, over the real wire with zero mocks: real Bandit loopback
  listener serving `AshA2A.A2ATransport.Plug`, a real `AshA2A.A2ATransport`
  supervision tree (`AshA2A.A2ATransport.TaskEvents` ETS event log), a real
  streaming `AshA2A.Protocol.Agent` GenServer, and real HTTP client
  connections (Req). SSE frames are parsed from the real wire bytes, including
  the `id:` (task-local event sequence) lines the transport writes.

  Spec semantics under court (https://a2a-protocol.org/latest/specification/):

    * S3.1.6 (`tasks/resubscribe`): "Establishes a streaming connection to
      receive updates for an existing task"; the operation "MUST return a
      `Task` object as the first event in the stream"; the "stream MUST
      terminate when the task reaches a terminal state"; reconnection after a
      network interruption by opening a new stream is a supported scenario.
    * S3.2.3: a `StreamResponse` "MUST contain exactly one of" `task`,
      `message`, `statusUpdate`, `artifactUpdate` — every frame's `result` is
      one of those single-key wrappers.
    * Event ordering (S3.5.2): "All implementations MUST deliver events in the
      order they were generated."

  Last-Event-ID replay and the `id:` sequence lines are implementation-
  provided (the spec text reachable here does not spell them out); this court
  pins the real behavior as conformance reality.
  """

  use ExUnit.Case, async: true

  alias AshA2A.V1SSEReplayTest.SlowStreamAgent
  alias AshA2A.Test.EphemeralHttp

  setup do
    uniq = System.unique_integer([:positive])
    agent = :"v1_sse_replay_#{uniq}"
    transport = :"a2a_transport_v1sse_#{uniq}"
    start_supervised!({SlowStreamAgent, name: agent})
    start_supervised!({AshA2A.A2ATransport, name: transport})

    http =
      EphemeralHttp.start!(
        {AshA2A.A2ATransport.Plug, agent: agent, base_url: "http://x/a2a", transport: transport}
      )

    %{url: http.base_url, agent: agent, transport: transport}
  end

  # -- wire helpers -------------------------------------------------------------

  defp envelope(method, params),
    do: %{
      "jsonrpc" => "2.0",
      "id" => System.unique_integer([:positive]),
      "method" => method,
      "params" => params
    }

  defp message do
    {:ok, encoded} = AshA2A.Protocol.JSON.encode(AshA2A.Protocol.Message.new_user("go"))
    encoded
  end

  # Opens `method` in a separate process that forwards every raw chunk of the
  # streaming response to the test process, then signals closure. Returns the
  # spawned process.
  defp open_streaming(url, method, params, headers \\ []) do
    parent = self()

    spawn(fn ->
      Req.post!(url,
        json: envelope(method, params),
        headers: headers,
        retry: false,
        receive_timeout: 15_000,
        into: fn {:data, data}, acc ->
          send(parent, {:chunk, self(), data})
          {:cont, acc}
        end
      )

      send(parent, {:stream_closed, self()})
    end)
  end

  defp open_stream(url), do: open_streaming(url, "message/stream", %{"message" => message()})

  defp resubscribe_async(url, task_id, headers \\ []),
    do: open_streaming(url, "tasks/resubscribe", %{"id" => task_id}, headers)

  # Blocking resubscribe: fine for connections that terminate on their own
  # (terminal task, error envelope).
  defp resubscribe(url, task_id, headers \\ []) do
    Req.post!(url,
      json: envelope("tasks/resubscribe", %{"id" => task_id}),
      headers: headers,
      retry: false,
      receive_timeout: 10_000
    )
  end

  # Parses real SSE bytes into `{:frames, [{id, result}]}` plus the count of
  # `:`-prefixed keepalive comment lines. A frame is one `id:` line (optional
  # for comment-only frames) and one `data:` line; frames are `\n\n`-separated.
  defp parse_sse(body) do
    {frames, keepalives} =
      body
      |> String.split("\n\n", trim: true)
      |> Enum.flat_map_reduce(0, fn frame, keepalives ->
        lines = String.split(frame, "\n")
        comments = Enum.filter(lines, &String.starts_with?(&1, ":"))
        keepalives = keepalives + length(comments)

        data_lines = Enum.filter(lines, &String.starts_with?(&1, "data: "))

        frames =
          for "data: " <> json <- data_lines do
            id =
              case Enum.find(lines, &String.starts_with?(&1, "id: ")) do
                "id: " <> value -> String.to_integer(String.trim(value))
                nil -> nil
              end

            {id, Jason.decode!(json)["result"]}
          end

        {frames, keepalives}
      end)

    {:frames, frames, keepalives}
  end

  defp await_task_id(pid, acc \\ "") do
    receive do
      {:chunk, ^pid, data} ->
        case Enum.find(elem(parse_sse(acc <> data), 1), fn {_id, result} ->
               match?(%{"task" => %{"id" => _}}, result)
             end) do
          nil -> await_task_id(pid, acc <> data)
          {_id, %{"task" => %{"id" => id}}} -> id
        end
    after
      5_000 -> flunk("no first SSE frame")
    end
  end

  defp collect(pid, acc \\ "") do
    receive do
      {:chunk, ^pid, data} -> collect(pid, acc <> data)
      {:stream_closed, ^pid} -> acc
    after
      15_000 -> flunk("stream did not close")
    end
  end

  # Collects only until `pred` holds (used to disconnect mid-stream).
  defp collect_until(pid, pred, acc \\ "") do
    receive do
      {:chunk, ^pid, data} ->
        acc = acc <> data

        if pred.(acc), do: acc, else: collect_until(pid, pred, acc)

      {:stream_closed, ^pid} ->
        acc
    after
      15_000 -> flunk("stream did not produce the expected prefix")
    end
  end

  # v1.0 StreamResponse oneof unwrap.
  defp unwrap(%{"task" => task}), do: {:task, task}
  defp unwrap(%{"statusUpdate" => event}), do: {:status, event}
  defp unwrap(%{"artifactUpdate" => event}), do: {:artifact, event}

  defp artifact_texts(results) do
    for {:artifact, %{"artifact" => %{"parts" => [%{"text" => t}]}}} <-
          Enum.map(results, &unwrap/1),
        do: t
  end

  # Finality rides on the terminal status state — StatusUpdate events carry no
  # "final" boolean on the wire.
  @terminal_states ["TASK_STATE_COMPLETED", "TASK_STATE_FAILED", "TASK_STATE_CANCELED",
                    "TASK_STATE_REJECTED", "TASK_STATE_AUTH_REQUIRED"]

  defp final(results) do
    Enum.find(results, fn result ->
      case unwrap(result) do
        {:status, %{"status" => %{"state" => state}}} -> state in @terminal_states
        _ -> false
      end
    end)
  end

  defp state(%{"statusUpdate" => %{"status" => %{"state" => s}}}),
    do: s |> String.downcase() |> String.replace_prefix("task_state_", "")

  # One data frame per task-local event seq, snapshot at 0: the court's core
  # ordering invariant (spec S3.5.2) is that a connection never sees a seq go
  # backwards or repeat.
  defp assert_strictly_increasing_ids(frames) do
    ids = Enum.map(frames, &elem(&1, 0))

    assert ids == Enum.uniq(ids), "duplicate SSE ids: #{inspect(ids)}"
    assert ids == Enum.sort(ids), "SSE ids not in generation order: #{inspect(ids)}"

    :ok
  end

  @tag :serial
  test "(a) disconnect mid-stream then resubscribe without Last-Event-ID replays the full backlog in order, no gap or overlap", %{
    url: url
  } do
    a = open_stream(url)
    task_id = await_task_id(a)

    # Disconnect after the first artifact frame has reached the client.
    _prefix =
      collect_until(a, fn acc ->
        {:frames, frames, _} = parse_sse(acc)
        length(frames) >= 3
      end)

    Process.exit(a, :kill)

    resub = resubscribe(url, task_id)
    assert resub.status == 200
    assert hd(Req.Response.get_header(resub, "content-type")) =~ "text/event-stream"

    {:frames, resub_frames, _} = parse_sse(resub.body)

    # Full replay: snapshot, every part 1..5 in generation order, final.
    results = Enum.map(resub_frames, &elem(&1, 1))
    assert %{"task" => %{"id" => ^task_id}} = hd(results)
    assert artifact_texts(results) == for(i <- 1..5, do: "part #{i}")
    assert state(final(results)) == "completed"

    # No gap/overlap: the client-visible `id:` sequence is unique and ordered.
    assert_strictly_increasing_ids(resub_frames)
  end

  @tag :serial
  test "(b) resubscribing with Last-Event-ID = N replays only events after N", %{
    url: url
  } do
    a = open_stream(url)
    task_id = await_task_id(a)
    _ = collect(a)

    {:frames, all_frames, _} = url |> resubscribe(task_id) |> Map.fetch!(:body) |> parse_sse()
    all_results = Enum.map(all_frames, &elem(&1, 1))
    assert artifact_texts(all_results) == for(i <- 1..5, do: "part #{i}")

    # Full-log resubscribe: everything after the seq-1 task event replays.
    replayed_ids = tl(Enum.map(all_frames, &elem(&1, 0)))
    assert replayed_ids == [2, 3, 4, 5, 6, 7]

    # Skip through part 3 (seq 4): only seq > 4 replays.
    {:frames, tail_frames, _} =
      url |> resubscribe(task_id, [{"last-event-id", "4"}]) |> Map.fetch!(:body) |> parse_sse()

    tail_results = Enum.map(tail_frames, &elem(&1, 1))

    assert [%{"task" => %{"id" => ^task_id}} | tail_results] = tail_results
    assert artifact_texts(tail_results) == ["part 4", "part 5"]
    assert state(final(tail_results)) == "completed"
    assert Enum.all?(tl(Enum.map(tail_frames, &elem(&1, 0))), &(&1 > 4))
  end

  @tag :serial
  test "(c) Last-Event-ID beyond the log replays nothing: snapshot only, then the connection closes (terminal) or idles out (live)", %{
    url: url,
    agent: agent,
    transport: transport
  } do
    # Terminal task, huge Last-Event-ID: the backlog's final event has
    # seq <= last, so the replay halts immediately after the snapshot.
    a = open_stream(url)
    task_id = await_task_id(a)
    _ = collect(a)
    assert {:ok, %AshA2A.Protocol.Task{status: %{state: :completed}}} =
             GenServer.call(agent, {:get_task, task_id})

    resp = resubscribe(url, task_id, [{"last-event-id", "999999"}])
    assert resp.status == 200
    assert hd(Req.Response.get_header(resp, "content-type")) =~ "text/event-stream"

    {:frames, frames, _} = parse_sse(resp.body)
    assert [{0, %{"task" => %{"id" => ^task_id}}}] = frames

    # Garbage Last-Event-ID is not an error: it parses as 0, i.e. full replay.
    {:frames, garbage_frames, _} =
      url |> resubscribe(task_id, [{"last-event-id", "not-a-number"}]) |> Map.fetch!(:body) |> parse_sse()

    assert artifact_texts(Enum.map(garbage_frames, &elem(&1, 1))) == for(i <- 1..5, do: "part #{i}")

    # Same overshoot on a still-live task: the snapshot arrives, no backlog
    # event replays (all seq <= last), the live final is dropped (its seq is
    # <= last too), and the connection idles out via keepalives.
    heartbeat_url =
      EphemeralHttp.start!(
        {AshA2A.A2ATransport.Plug,
         agent: agent,
         base_url: "http://x/a2a",
         transport: transport,
         heartbeat_ms: 50,
         max_idle_ms: 300}
      ).base_url

    b = open_stream(heartbeat_url)
    task_id2 = await_task_id(b)

    r = resubscribe_async(heartbeat_url, task_id2, [{"last-event-id", "999999"}])
    body = collect(r)
    Process.exit(b, :kill)

    {:frames, frames2, keepalives} = parse_sse(body)
    assert [{0, %{"task" => %{"id" => ^task_id2}}}] = frames2
    assert keepalives >= 1
  end

  @tag :serial
  test "(d) resubscribing to a completed task replays snapshot + full backlog + final statusUpdate", %{
    url: url
  } do
    a = open_stream(url)
    task_id = await_task_id(a)
    _ = collect(a)

    resp = resubscribe(url, task_id)
    assert resp.status == 200
    assert hd(Req.Response.get_header(resp, "content-type")) =~ "text/event-stream"

    {:frames, frames, _} = parse_sse(resp.body)
    results = Enum.map(frames, &elem(&1, 1))

    # First frame is the task snapshot; the stream terminates right after the
    # final statusUpdate (terminal state), not UnsupportedOperationError.
    assert %{"task" => %{"id" => ^task_id, "status" => %{"state" => "TASK_STATE_COMPLETED"}}} =
             hd(results)

    assert artifact_texts(results) == for(i <- 1..5, do: "part #{i}")
    assert state(final(results)) == "completed"
    # The stream terminates on the final statusUpdate itself.
    assert {:status, _} = results |> List.last() |> unwrap()
    assert_strictly_increasing_ids(frames)
  end

  test "(e) resubscribing to an unknown task is a -32001 TASK_NOT_FOUND ErrorInfo JSON envelope, not an SSE stream", %{
    url: url
  } do
    resp = resubscribe(url, "no-such-task")

    assert resp.status == 200
    assert hd(Req.Response.get_header(resp, "content-type")) =~ "application/json"

    assert %{
             "error" => %{
               "code" => -32_001,
               "message" => message,
               "data" => [
                 %{
                   "@type" => "type.googleapis.com/google.rpc.ErrorInfo",
                   "domain" => "a2a-protocol.org",
                   "reason" => "TASK_NOT_FOUND"
                 }
               ]
             }
           } = resp.body

    assert is_binary(message) and message != ""
  end

  @tag :serial
  test "(f) two concurrent subscribers receive identical frame sequences", %{url: url} do
    a = open_stream(url)
    task_id = await_task_id(a)

    b = resubscribe_async(url, task_id)
    c = resubscribe_async(url, task_id)

    a_results = a |> collect() |> then(fn body -> elem(parse_sse(body), 1) end)
    b_frames = b |> collect() |> then(fn body -> elem(parse_sse(body), 1) end)
    c_frames = c |>
      collect() |>
      then(fn body -> elem(parse_sse(body), 1) end)

    # Identical {id, result} sequences from the shared ordered event log.
    assert b_frames == c_frames
    [{snapshot_id, %{"task" => %{"id" => ^task_id}}} | _] = b_frames
    assert snapshot_id == 0

    for frames <- [a_results, b_frames] do
      results = Enum.map(frames, &elem(&1, 1))

      # `a_results` excludes the snapshot chunk consumed while learning the
      # task id (await_task_id/2 drops its accumulator); both subscribers
      # still see every artifact and the final state, in generation order.
      assert artifact_texts(results) == for(i <- 1..5, do: "part #{i}")
      assert state(final(results)) == "completed"
      assert_strictly_increasing_ids(frames)
    end
  end
end
