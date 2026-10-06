defmodule AshA2A.ConferenceSim.MultitrackStreamAgent do
  @moduledoc false
  # Real `AshA2A.Protocol.Agent` GenServer whose `handle_message/2` inspects the
  # inbound user text to pick a per-session (per-track) production schedule, so
  # four concurrent session tasks on ONE real transport have genuinely different
  # lifetimes: two short talks, one medium talk, and a keynote that runs long.
  use AshA2A.Protocol.Agent, name: "conf-multitrack", description: "conference with tracks of different lengths"

  alias AshA2A.Protocol.Message
  alias AshA2A.Protocol.Part

  @impl AshA2A.Protocol.Agent
  def handle_message(%Message{parts: parts}, _context) do
    track =
      Enum.find_value(parts, fn
        %Part.Text{text: t} -> t
        _ -> nil
      end) || "keynote"

    {count, delay_ms} = schedule(track)

    {:stream,
     Stream.map(1..count, fn i ->
       Process.sleep(delay_ms)
       Part.Text.new("#{track} part #{i}")
     end)}
  end

  defp schedule("track_a"), do: {3, 20}
  defp schedule("track_b"), do: {3, 20}
  defp schedule("track_c"), do: {5, 25}
  defp schedule("keynote"), do: {10, 60}
  defp schedule("loadtrack"), do: {8, 30}
end

defmodule AshA2A.ConferenceSim.MultitrackStreamCourt do
  @moduledoc """
  Conference-sim lane EV5 court: four concurrent session tasks stream on ONE
  real transport surface — real Bandit loopback listener serving
  `AshA2A.A2ATransport.Plug`, real `AshA2A.A2ATransport` supervision tree with
  its ETS event log, real streaming `AshA2A.Protocol.Agent` GenServer, real
  `Req` HTTP connections — with 12 attendee connections (3 per session, mixed
  `message/stream` + `tasks/resubscribe`) under event load.

  Spec semantics under court (https://a2a-protocol.org/latest/specification/):

    * S3.5.2: events MUST be delivered in the order they were generated —
      asserted as a strictly increasing task-local SSE `id:` sequence per
      subscriber, no duplicates.
    * S3.1.6 (`tasks/resubscribe`): reconnecting clients replay the backlog;
      with `Last-Event-ID` only events after the client's last seen seq are
      replayed — exactly the missed events, no duplicates, no gaps.
    * Session isolation: a stream for task X never carries task Y's events, a
      session ending never disturbs the others' connections, and the keynote
      stays open past the other sessions' close with no cross-session bleed.
  """

  use ExUnit.Case, async: true

  alias AshA2A.ConferenceSim.MultitrackStreamAgent
  alias AshA2A.Test.EphemeralHttp

  @tracks [
    {"track_a", 3},
    {"track_b", 3},
    {"track_c", 5},
    {"keynote", 10}
  ]

  @all_track_names ["track_a", "track_b", "track_c", "keynote", "loadtrack"]

  @terminal_states ["TASK_STATE_COMPLETED", "TASK_STATE_FAILED", "TASK_STATE_CANCELED",
                    "TASK_STATE_REJECTED", "TASK_STATE_AUTH_REQUIRED"]

  setup do
    uniq = System.unique_integer([:positive])
    agent = :"conf_multitrack_#{uniq}"
    transport = :"a2a_transport_conf_#{uniq}"
    start_supervised!({MultitrackStreamAgent, name: agent})
    start_supervised!({AshA2A.A2ATransport, name: transport})

    http =
      EphemeralHttp.start!(
        {AshA2A.A2ATransport.Plug, agent: agent, base_url: "http://x/a2a", transport: transport}
      )

    %{url: http.base_url, agent: agent, transport: transport}
  end

  # -- wire helpers ---------------------------------------------------------

  defp envelope(method, params),
    do: %{
      "jsonrpc" => "2.0",
      "id" => System.unique_integer([:positive]),
      "method" => method,
      "params" => params
    }

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

  defp open_session(url, track) do
    {:ok, encoded} = AshA2A.Protocol.JSON.encode(AshA2A.Protocol.Message.new_user(track))
    open_streaming(url, "message/stream", %{"message" => encoded})
  end

  defp resubscribe_async(url, task_id, headers \\ []),
    do: open_streaming(url, "tasks/resubscribe", %{"id" => task_id}, headers)

  defp resubscribe(url, task_id, headers) do
    Req.post!(url,
      json: envelope("tasks/resubscribe", %{"id" => task_id}),
      headers: headers,
      retry: false,
      receive_timeout: 15_000
    )
  end

  defp parse_sse(body) do
    {frames, keepalives} =
      body
      |> String.split("\n\n", trim: true)
      |> Enum.flat_map_reduce(0, fn frame, keepalives ->
        lines = String.split(frame, "\n")
        comments = Enum.filter(lines, &String.starts_with?(&1, ":"))
        keepalives = keepalives + length(comments)

        frames =
          for "data: " <> json <- Enum.filter(lines, &String.starts_with?(&1, "data: ")) do
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
      20_000 -> flunk("stream did not close")
    end
  end

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

  defp unwrap(%{"task" => task}), do: {:task, task}
  defp unwrap(%{"statusUpdate" => event}), do: {:status, event}
  defp unwrap(%{"artifactUpdate" => event}), do: {:artifact, event}

  defp artifact_texts(results) do
    for {:artifact, %{"artifact" => %{"parts" => [%{"text" => t}]}}} <-
          Enum.map(results, &unwrap/1),
        do: t
  end

  defp final_state(results) do
    Enum.find_value(results, fn result ->
      case unwrap(result) do
        {:status, %{"status" => %{"state" => state}}} when state in @terminal_states -> state
        _ -> nil
      end
    end)
  end

  defp assert_strictly_increasing_ids(frames) do
    ids = Enum.map(frames, &elem(&1, 0))

    assert ids == Enum.uniq(ids), "duplicate SSE ids: #{inspect(ids)}"
    assert ids == Enum.sort(ids), "SSE ids not in generation order: #{inspect(ids)}"
    :ok
  end

  defp expected_parts(track, count), do: for(i <- 1..count, do: "#{track} part #{i}")

  defp assert_no_cross_session_bleed(body, track) do
    for other <- @all_track_names, other != track do
      refute body =~ "#{other} part", "#{track} connection bled #{other} events"
    end

    :ok
  end

  # -- court 1: 4 sessions x 3 subscribers; ordering, terminal frames,
  #    isolation, keynote runs long ----------------------------------------

  test "four concurrent sessions, 12 subscribers: ordered, isolated, keynote runs long", %{
    url: url
  } do
    # 4 concurrent session tasks via message/stream on the setup transport.
    primaries =
      for {track, _n} <- @tracks, into: %{} do
        {track, open_session(url, track)}
      end

    task_ids =
      for {track, conn} <- primaries, into: %{} do
        {track, await_task_id(conn)}
      end

    assert 4 == map_size(task_ids) and 4 == task_ids |> Map.values() |> Enum.uniq() |> length()

    # 8 more attendee connections via tasks/resubscribe: 3 subscribers per
    # session, 12 concurrent SSE connections over the real Bandit listener.
    resubs =
      for {track, task_id} <- task_ids, k <- 1..2, into: %{} do
        {{track, k}, resubscribe_async(url, task_id)}
      end

    assert map_size(resubs) == 8

    # Temporal isolation court: track_a and track_b (3 x 20ms parts) close
    # first. Collect them to closure, then prove the keynote connection is
    # STILL delivering new chunks — its stream stayed open past the shorts'
    # close, with no cross-session bleed.
    keynote_conn = Map.fetch!(primaries, "keynote")
    a_conn = Map.fetch!(primaries, "track_a")
    b_conn = Map.fetch!(primaries, "track_b")

    body_a = collect(a_conn)
    body_b = collect(b_conn)

    # Keynote still open and producing after both short sessions ended.
    assert_receive {:chunk, ^keynote_conn, _}, 5_000

    # Drain every remaining connection to terminal closure, then court each body.
    bodies =
      for {track, conn} <- primaries, into: %{} do
        {track,
         case track do
           "track_a" -> body_a
           "track_b" -> body_b
           _ -> collect(conn)
         end}
      end

    resub_bodies =
      for {{track, k}, conn} <- resubs, into: %{} do
        {{track, k}, collect(conn)}
      end

    for {track, n} <- @tracks do
      resub_bodies_for_track = for(k <- 1..2, do: Map.fetch!(resub_bodies, {track, k}))

      # Resubscribers joined from the log snapshot: full projection, snapshot
      # frame first, every part, terminal frame, connection closed.
      for body <- resub_bodies_for_track do
        court_closed_body(body, track, n, require_snapshot: true, expect: :all_parts)
      end

      # Primaries: each primary's first chunk(s) were consumed by
      # await_task_id/2 (which drops its accumulator, replay-test precedent),
      # so each primary body is a gapless contiguous suffix of its session —
      # the resubscribers carry the full projection with the snapshot frame.
      primary = Map.fetch!(bodies, track)
      court_closed_body(primary, track, n, require_snapshot: false, expect: :suffix)
    end
  end

  defp court_closed_body(body, track, n, opts) do
    assert_no_cross_session_bleed(body, track)
    {:frames, frames, _} = parse_sse(body)
    assert_strictly_increasing_ids(frames)

    results = Enum.map(frames, &elem(&1, 1))

    if Keyword.fetch!(opts, :require_snapshot) do
      assert %{"task" => %{"id" => _}} = hd(results)
    end

    expected = expected_parts(track, n)
    got = artifact_texts(results)

    case Keyword.fetch!(opts, :expect) do
      :all_parts ->
        assert got == expected, "track #{track}: wrong artifact sequence"

      :suffix ->
        # Contiguous-suffix check: the prefix was consumed while learning the
        # task id, everything from the first surviving frame to the terminal
        # frame must still be gapless.
        suffix? = Enum.any?(0..length(expected), fn k -> Enum.drop(expected, k) == got end)
        assert suffix?, "track #{track}: artifacts not a contiguous suffix: #{inspect(got)}"
    end

    assert final_state(results) == "TASK_STATE_COMPLETED"
    assert {:status, _} = results |> List.last() |> unwrap()
    :ok
  end

  # -- court 2: disconnect mid-session, Last-Event-ID replays exactly the
  #    missed events ---------------------------------------------------------

  test "mid-session disconnect then Last-Event-ID resubscribe replays exactly the missed events", %{
    url: url
  } do
    a = open_session(url, "track_c")
    task_id = await_task_id(a)

    prefix =
      collect_until(a, fn acc ->
        {:frames, frames, _} = parse_sse(acc)
        length(frames) >= 3
      end)

    Process.exit(a, :kill)

    {:frames, seen, _} = parse_sse(prefix)
    seen_parts = artifact_texts(Enum.map(seen, &elem(&1, 1)))
    last_id = seen |> Enum.map(&elem(&1, 0)) |> Enum.max()

    resp = resubscribe(url, task_id, [{"last-event-id", Integer.to_string(last_id)}])
    assert resp.status == 200
    assert hd(Req.Response.get_header(resp, "content-type")) =~ "text/event-stream"

    {:frames, replay_frames, _} = parse_sse(resp.body)
    results = Enum.map(replay_frames, &elem(&1, 1))

    # Snapshot first, then ONLY events after last_id: no duplicates of already
    # seen parts, no gap, terminal statusUpdate closes the stream.
    assert [%{"task" => %{"id" => ^task_id}} | replay_results] = results
    assert artifact_texts(replay_results) == expected_parts("track_c", 5) -- seen_parts
    assert Enum.all?(tl(Enum.map(replay_frames, &elem(&1, 0))), &(&1 > last_id))
    assert final_state(results) == "TASK_STATE_COMPLETED"
    assert_strictly_increasing_ids(replay_frames)
  end

  # -- court 3: load — 12 concurrent SSE connections, clean teardown ---------

  test "load: 12 concurrent SSE connections over the real Bandit listener, clean teardown", %{
    url: url
  } do
    ports_before = length(:erlang.ports())

    # The setup listener IS the load surface: 12 concurrent SSE connections on
    # one real Bandit listener.
    keynote = open_session(url, "keynote")
    task_id = await_task_id(keynote)

    subs =
      for _k <- 1..11 do
        resubscribe_async(url, task_id)
      end

    conns = [keynote | subs]
    assert length(conns) == 12

    # The spawn connections all message the test process; collect/1 filters by
    # pid, so interleaved chunk traffic drains per connection correctly.
    bodies = Enum.map(conns, &collect(&1))

    parsed = Enum.map(bodies, fn body -> elem(parse_sse(body), 1) end)

    # No port exhaustion / no refused streams: every one of the 12 connections
    # received the full projection (snapshot + 10 artifacts + terminal frame).
    assert length(parsed) == 12

    for {body, frames} <- Enum.zip(bodies, parsed) do
      assert_no_cross_session_bleed(body, "keynote")
      assert_strictly_increasing_ids(frames)

      results = Enum.map(frames, &elem(&1, 1))
      assert artifact_texts(results) == expected_parts("keynote", 10)
      assert final_state(results) == "TASK_STATE_COMPLETED"
    end

    # The 11 resubscribers project the shared ordered log identically; the
    # primary's message/stream projection is courted by the content assertions
    # above (it lacks the resubscribe snapshot frame by design).
    [_primary | resubs_parsed] = parsed
    assert length(Enum.uniq(resubs_parsed)) == 1

    # Clean teardown: every client process exited, the connection mailbox
    # drains to silence, and the OS socket count stays bounded (concurrent
    # sibling tests and the shared Finch keepalive pool hold a few ports, so
    # this is a leak bound, not an exact-return-to-baseline court).
    assert Enum.all?(conns, &not Process.alive?(&1))

    eventually(fn ->
      assert length(:erlang.ports()) <= ports_before + 40
      true
    end)

    refute_receive {:chunk, _, _}, 250
    refute_receive {:stream_closed, _}, 250
    :ok
  end

  defp eventually(fun, deadline \\ nil) do
    deadline = deadline || :erlang.monotonic_time(:millisecond) + 5_000

    cond do
      fun.() -> :ok
      :erlang.monotonic_time(:millisecond) > deadline -> flunk("condition not reached")
      true ->
        Process.sleep(50)
        eventually(fun, deadline)
    end
  end
end
