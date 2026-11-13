defmodule AshA2A.StreamGenerationFramesTest.StreamAgent do
  @moduledoc false
  use AshA2A.Protocol.Agent, name: "v4-stream", description: "streams three parts"

  @impl AshA2A.Protocol.Agent
  def handle_message(_message, _context),
    do: {:stream, Stream.map(1..3, &AshA2A.Protocol.Part.Text.new("part #{&1}"))}
end

defmodule AshA2A.StreamGenerationFramesTest.ErrorFramePlug do
  @moduledoc false
  # Real Bandit handler: opens an SSE stream, writes a StreamError frame via
  # SSE.write_stream_error/3, then writes a further frame on the SAME stream.
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> send_chunked(200)

    conn =
      AshA2A.A2ATransport.SSE.write_stream_error(conn, 7, %AshA2A.Protocol.StreamError{
        task_id: "t-1",
        code: "INVALID_ARGUMENT",
        message: "bad request",
        reference_id: "m-1"
      })

    {:ok, conn} = chunk(conn, "data: {\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"task\":{}}}\n\n")
    conn
  end
end

defmodule AshA2A.StreamGenerationFramesTest do
  @moduledoc """
  V4 courts (real transport, real Bandit listeners, real subscriber
  processes; no mocks, no sleeps): generation on logged events, message-update
  gating by negotiated version, lastSeenGeneration resume and fallback,
  StreamError frames on a live stream, terminal-only closure.
  """

  use ExUnit.Case, async: true

  alias AshA2A.A2ATransport.TaskEvents
  alias AshA2A.Test.EphemeralHttp
  alias AshA2A.StreamGenerationFramesTest.{ErrorFramePlug, StreamAgent}

  setup do
    uniq = System.unique_integer([:positive])
    transport = :"v4_transport_#{uniq}"
    agent = :"v4_agent_#{uniq}"
    start_supervised!({AshA2A.A2ATransport, name: transport})
    start_supervised!({StreamAgent, name: agent})
    %{transport: transport, agent: agent, tid: "v4-task-#{uniq}"}
  end

  defp su(tid),
    do: %{"statusUpdate" => %{"taskId" => tid, "status" => %{"state" => "TASK_STATE_WORKING"}}}

  defp au(tid), do: %{"artifactUpdate" => %{"taskId" => tid}}
  defp mu(tid), do: %{"messageUpdate" => %{"taskId" => tid, "message" => %{}}}

  defp subscriber(transport, tid, version) do
    parent = self()

    task =
      Task.async(fn ->
        TaskEvents.subscribe(transport, tid, version: version)
        send(parent, {:subscribed, self()})
        collect(tid, [])
      end)

    assert_receive {:subscribed, _pid}, 5_000
    task
  end

  defp collect(tid, acc) do
    receive do
      {:a2a_task_event, ^tid, _seq, kind, payload, final?} ->
        acc = [{kind, payload} | acc]
        if final?, do: Enum.reverse(acc), else: collect(tid, acc)
    after
      5_000 -> flunk("subscriber deadline: got #{inspect(Enum.reverse(acc))}")
    end
  end

  test "logged events carry strictly increasing, never-duplicated generations", ctx do
    t = ctx.transport
    TaskEvents.publish(t, ctx.tid, "task", %{"task" => %{"id" => ctx.tid, "generation" => 3}})
    TaskEvents.publish(t, ctx.tid, "status-update", su(ctx.tid))
    # explicit duplicate of the last generation is replaced, not repeated
    TaskEvents.publish(t, ctx.tid, "artifact-update", au(ctx.tid), false, generation: 4)
    TaskEvents.publish(t, ctx.tid, "status-update", su(ctx.tid), false, generation: 9)
    # stale explicit generation is replaced by last + 1
    TaskEvents.publish(t, ctx.tid, "status-update", su(ctx.tid), false, generation: 2)

    gens =
      for {_, kind, p, _} <- TaskEvents.backlog(t, ctx.tid), kind != "task" do
        TaskEvents.generation_of(p)
      end

    assert gens == [4, 5, 9, 10]
  end

  test "message-update reaches only >= 1.1 subscribers; legacy stream stays ordered", ctx do
    t = ctx.transport
    legacy = subscriber(t, ctx.tid, "1.0")
    modern = subscriber(t, ctx.tid, "1.1")

    TaskEvents.publish(t, ctx.tid, "status-update", su(ctx.tid))
    TaskEvents.publish(t, ctx.tid, "message-update", mu(ctx.tid))
    TaskEvents.publish(t, ctx.tid, "status-update", su(ctx.tid), true)

    legacy_events = Task.await(legacy, 5_000)
    modern_events = Task.await(modern, 5_000)

    assert Enum.map(legacy_events, &elem(&1, 0)) == ["status-update", "status-update"]

    assert Enum.map(modern_events, &elem(&1, 0)) == [
             "status-update",
             "message-update",
             "status-update"
           ]

    gens = Enum.map(modern_events, fn {_, p} -> TaskEvents.generation_of(p) end)
    assert gens == Enum.sort(Enum.uniq(gens))

    # A late legacy subscriber's backlog also hides the message-update.
    late = TaskEvents.subscribe(t, ctx.tid, version: "1.0")
    assert Enum.all?(late, fn {_, kind, _, _} -> kind != "message-update" end)
    full = TaskEvents.subscribe(t, ctx.tid, version: "1.1")
    assert Enum.any?(full, fn {_, kind, _, _} -> kind == "message-update" end)
  end

  test "replay_from_generation: resume window, caught-up, and not-retained", ctx do
    t = ctx.transport
    for _ <- 1..4, do: TaskEvents.publish(t, ctx.tid, "status-update", su(ctx.tid))
    log = TaskEvents.backlog(t, ctx.tid)

    assert {:ok, replay, _cursor} = TaskEvents.replay_from_generation(log, 2, 4)
    assert Enum.map(replay, fn {_, _, p, _} -> TaskEvents.generation_of(p) end) == [3, 4]
    assert {:ok, [], _} = TaskEvents.replay_from_generation(log, 4, 4)
    assert :unavailable = TaskEvents.replay_from_generation(log, 99, 4)
    # task is ahead of everything the log retains -> cannot replay
    assert :unavailable = TaskEvents.replay_from_generation(log, 1, 12)
  end

  # -- HTTP: lastSeenGeneration ------------------------------------------------

  defp boot(ctx) do
    EphemeralHttp.start!(
      {AshA2A.A2ATransport.Plug,
       agent: ctx.agent, base_url: "http://x/a2a", transport: ctx.transport}
    ).base_url
  end

  defp post(url, method, params) do
    Req.post!(url,
      json: %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params},
      headers: [{"a2a-version", "1.1"}],
      retry: false,
      receive_timeout: 10_000
    ).body
  end

  defp frames(body) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.flat_map(fn frame ->
      for "data: " <> json <- String.split(frame, "\n"), do: Jason.decode!(json)["result"]
    end)
  end

  defp gen(%{"statusUpdate" => %{"generation" => g}}), do: g
  defp gen(%{"artifactUpdate" => %{"generation" => g}}), do: g
  defp gen(_), do: nil

  defp opened(ctx) do
    url = boot(ctx)
    msg = AshA2A.Protocol.Message.new_user("go")
    {:ok, encoded} = AshA2A.Protocol.JSON.encode(msg)
    results = url |> post("message/stream", %{"message" => encoded}) |> frames()
    [%{"task" => %{"id" => task_id}} | _] = results
    {url, task_id, results}
  end

  test "lastSeenGeneration set: no Task snapshot, only newer events", ctx do
    {url, task_id, results} = opened(ctx)
    gens = for r <- results, g = gen(r), do: g
    assert length(gens) >= 2
    assert gens == Enum.sort(Enum.uniq(gens))

    [cut | _] = gens
    newer = Enum.filter(gens, &(&1 > cut))

    resumed =
      url
      |> post("tasks/resubscribe", %{"id" => task_id, "lastSeenGeneration" => cut})
      |> frames()

    refute Enum.any?(resumed, &Map.has_key?(&1, "task"))
    assert for(r <- resumed, g = gen(r), do: g) == newer
  end

  test "lastSeenGeneration not retained: opens with a Task snapshot instead of failing", ctx do
    {url, task_id, _} = opened(ctx)

    resumed =
      url
      |> post("tasks/resubscribe", %{"id" => task_id, "lastSeenGeneration" => 10_000})
      |> frames()

    assert [%{"task" => %{"id" => ^task_id}} | _] = resumed
  end

  test "lastSeenGeneration unset: snapshot first (unchanged behaviour)", ctx do
    {url, task_id, _} = opened(ctx)
    resumed = url |> post("tasks/resubscribe", %{"id" => task_id}) |> frames()
    assert [%{"task" => %{"id" => ^task_id}} | _] = resumed
  end

  # -- StreamError ---------------------------------------------------------------

  test "StreamError frame is written and the stream stays open for the next frame" do
    url = EphemeralHttp.start!({ErrorFramePlug, []}).base_url
    results = Req.get!(url, retry: false, receive_timeout: 5_000).body |> frames()

    assert [%{"error" => %{"code" => "INVALID_ARGUMENT"} = err}, %{"task" => %{}}] = results
    assert err["referenceId"] == "m-1" or err["reference_id"] == "m-1"
  end

  test "an unknown StreamResponse payload kind in the log is passed through, not fatal", ctx do
    t = ctx.transport
    sub = subscriber(t, ctx.tid, "1.1")
    TaskEvents.publish(t, ctx.tid, "future-kind", %{"futureThing" => %{"x" => 1}})
    TaskEvents.publish(t, ctx.tid, "status-update", su(ctx.tid), true)
    events = Task.await(sub, 5_000)
    assert Enum.map(events, &elem(&1, 0)) == ["future-kind", "status-update"]
  end

  # -- terminal-only closure -------------------------------------------------------

  test "an interrupted status is not final; only a terminal state closes the stream", ctx do
    t = ctx.transport

    interrupted = %{
      "statusUpdate" => %{
        "taskId" => ctx.tid,
        "status" => %{"state" => "TASK_STATE_INPUT_REQUIRED"}
      }
    }

    refute TaskEvents.terminal_payload?(interrupted)
    assert TaskEvents.closing_payload?(interrupted)

    sub = subscriber(t, ctx.tid, "1.1")
    TaskEvents.publish(t, ctx.tid, "status-update", interrupted, false)

    completed = %{
      "statusUpdate" => %{"taskId" => ctx.tid, "status" => %{"state" => "TASK_STATE_COMPLETED"}}
    }

    assert TaskEvents.terminal_payload?(completed)
    TaskEvents.publish(t, ctx.tid, "status-update", completed, true)

    # collect/2 only returns at the final flag: both events were seen on one stream.
    events = Task.await(sub, 5_000)
    states = Enum.map(events, fn {_, p} -> TaskEvents.payload_state(p) end)
    assert states == ["input_required", "completed"]
  end
end
