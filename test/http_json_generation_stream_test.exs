# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.HttpJsonGenerationStream.Resource do
  @moduledoc "Real fixture: `:converse` parks in input_required when :text is omitted."

  use Ash.Resource,
    domain: AshA2A.HttpJsonGenerationStream.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  actions do
    action :converse, :map do
      argument(:text, :string, allow_nil?: false)

      run(fn input, _context -> {:ok, %{text: input.arguments.text}} end)
    end
  end

  a2a do
    skill(:converse, :converse, consequence: :observe)
  end
end

defmodule AshA2A.HttpJsonGenerationStream.Domain do
  @moduledoc false
  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.HttpJsonGenerationStream.Resource)
  end
end

defmodule AshA2A.HttpJsonGenerationStream.Agent do
  @moduledoc false
  use AshA2A.Agent,
    resource_or_domain: AshA2A.HttpJsonGenerationStream.Resource,
    name: "v9_http_json_agent"
end

defmodule AshA2A.HttpJsonGenerationStream.Pipeline do
  @moduledoc "Stamps a verified identity (and an opt-in second one) on every request."

  @behaviour Plug

  def init(opts) when is_map(opts), do: opts
  def init(opts), do: AshA2A.Transport.HTTPJSON.init(opts)

  def call(conn, opts) do
    conn = AshA2A.Protocol.Plug.Auth.put_identity(conn, %{identity: "alice"})
    AshA2A.Transport.HTTPJSON.call(conn, opts)
  end
end

defmodule AshA2A.HttpJsonGenerationStreamTest do
  @moduledoc """
  V9 court: the v1.1 REST/HTTP+JSON binding -- `POST /message:live`
  (downlink SSE + ack-only uplink), `ifGenerationMatch` (409), long-poll
  `currentGeneration`, `timelineLength`, `lastSeenGeneration` resume,
  `artifactUpdates` refusal, and `messageUpdate` version gating. Real Bandit,
  real agent, real `Req`; waits are deadline-bounded observations, not sleeps.
  """

  use ExUnit.Case, async: false

  @moduletag :serial_shard

  alias AshA2A.Protocol.{Artifact, Message, Part}
  alias AshA2A.Test.EphemeralHttp
  alias AshA2A.HttpJsonGenerationStream.Pipeline

  @agent AshA2A.HttpJsonGenerationStream.Agent
  @v11 [{"a2a-version", "1.1"}]
  @deadline_ms 5_000

  setup do
    {_sup, _registry} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [@agent])

    versions = Enum.uniq(AshA2A.Protocol.Version.supported_default() ++ ["1.0", "1.1"])
    opts = [agent: @agent, base_url: "http://127.0.0.1/fixture", versions: versions]

    previous = Application.get_env(:ash_a2a, :long_poll_timeout_ms)
    Application.put_env(:ash_a2a, :long_poll_timeout_ms, 10_000)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:ash_a2a, :long_poll_timeout_ms, previous),
        else: Application.delete_env(:ash_a2a, :long_poll_timeout_ms)
    end)

    {:ok, server: EphemeralHttp.start!({Pipeline, Pipeline.init(opts)})}
  end

  # -- helpers -------------------------------------------------------------------

  defp wire(parts), do: AshA2A.Protocol.JSON.encode!(Message.new_user(parts))
  defp parked, do: wire([Part.Data.new(%{})])
  defp completing, do: wire([Part.Data.new(%{"text" => "hi"})])

  defp send_message(server, message, configuration \\ %{}, headers \\ @v11) do
    Req.post!(
      url: server.base_url <> "/message:send",
      json: %{"message" => message, "configuration" => configuration},
      headers: headers,
      retry: false
    )
  end

  defp park_task(server) do
    resp = send_message(server, parked())
    assert %{"task" => %{"id" => id} = task} = resp.body
    {id, gen(task)}
  end

  defp gen(%{"generation" => g}) do
    {n, ""} = g |> to_string() |> Integer.parse()
    n
  end

  defp frames(buffer) do
    buffer
    |> String.split("\n\n")
    |> Enum.drop(-1)
    |> Enum.flat_map(fn
      "data: " <> json -> [Jason.decode!(json)]
      _comment -> []
    end)
  end

  # Opens an SSE request in a task that forwards every chunk to the test process.
  defp open_sse(method, url, json \\ nil, headers \\ @v11) do
    parent = self()
    ref = make_ref()

    task =
      Task.async(fn ->
        req_opts =
          [
            method: method,
            url: url,
            headers: headers,
            retry: false,
            receive_timeout: 20_000,
            into: fn {:data, data}, {req, resp} ->
              case Req.Response.get_header(resp, "a2a-live-session-id") do
                [sid | _] -> send(parent, {:sid, ref, sid})
                [] -> :ok
              end

              send(parent, {:sse, ref, data})
              {:cont, {req, resp}}
            end
          ] ++ if(json, do: [json: json], else: [])

        Req.request!(req_opts)
      end)

    # on_exit runs in a different process than the Task owner: kill by pid.
    on_exit(fn -> Process.exit(task.pid, :kill) end)
    {ref, task}
  end

  # The downlink's `a2a-live-session-id` response header (deadline-bounded).
  defp live_session_id(ref) do
    receive do
      {:sid, ^ref, sid} -> sid
    after
      @deadline_ms -> flunk("no a2a-live-session-id response header")
    end
  end

  defp collect_until(ref, buffer, pred) do
    deadline = System.monotonic_time(:millisecond) + @deadline_ms
    do_collect(ref, buffer, pred, deadline)
  end

  defp do_collect(ref, buffer, pred, deadline) do
    all = frames(buffer)

    if pred.(all) do
      {all, buffer}
    else
      remaining = deadline - System.monotonic_time(:millisecond)
      if remaining <= 0, do: flunk("deadline; frames so far: #{inspect(all)}")

      receive do
        {:sse, ^ref, data} -> do_collect(ref, buffer <> data, pred, deadline)
      after
        remaining -> flunk("deadline; frames so far: #{inspect(all)}")
      end
    end
  end

  defp status_updates(frames), do: Enum.filter(frames, &Map.has_key?(&1, "statusUpdate"))

  defp live_url(server), do: server.base_url <> "/message:live"

  defp live_send_body(message), do: %{"sendMessage" => %{"message" => message}}

  # -- POST /message:live ---------------------------------------------------------

  test "live downlink opens with the task snapshot, then uplink events arrive on the downlink only",
       %{
         server: server
       } do
    {ref, _task} = open_sse(:post, live_url(server), live_send_body(parked()))

    {frames0, buffer} = collect_until(ref, "", &(&1 != []))
    assert %{"task" => %{"id" => id}} = hd(frames0)

    uplink = fn ->
      Req.post!(
        url: live_url(server),
        json: live_send_body(Map.put(parked(), "taskId", id)),
        headers: @v11,
        retry: false
      )
    end

    # taskId-correlated uplink: ack Task only (bare task JSON), no event frames.
    ack = uplink.()
    assert ack.status == 200
    assert %{"id" => ^id} = ack.body
    refute Map.has_key?(ack.body, "statusUpdate")

    {_frames1, buffer} = collect_until(ref, buffer, &(length(status_updates(&1)) >= 1))

    ack2 = uplink.()
    assert ack2.status == 200

    {frames2, _buffer} = collect_until(ref, buffer, &(length(status_updates(&1)) >= 2))
    gens = frames2 |> status_updates() |> Enum.map(&gen(&1["statusUpdate"]))

    # one event per uplink: strictly increasing, no duplicates, snapshot never replayed
    assert gens == Enum.uniq(gens)
    assert gens == Enum.sort(gens)
    assert length(Enum.filter(frames2, &Map.has_key?(&1, "task"))) == 1
  end

  test "a live uplink naming another task is a 400 and a StreamError on the downlink", %{
    server: server
  } do
    {ref, _task} = open_sse(:post, live_url(server), live_send_body(parked()))
    {[%{"task" => %{"id" => _id}} | _], buffer} = collect_until(ref, "", &(&1 != []))
    sid = live_session_id(ref)

    bad =
      Req.post!(
        url: live_url(server),
        json: %{"sendMessage" => %{"message" => Map.put(parked(), "taskId", "some-other-task")}},
        headers: @v11 ++ [{"a2a-live-session-id", sid}],
        retry: false
      )

    assert bad.status == 400

    {frames, _} =
      collect_until(ref, buffer, fn fs -> Enum.any?(fs, &Map.has_key?(&1, "error")) end)

    assert %{"error" => %{"code" => "INVALID_ARGUMENT"}} =
             Enum.find(frames, &Map.has_key?(&1, "error"))
  end

  test "live downlink on an unknown task frames a StreamError and never a transport failure", %{
    server: server
  } do
    {ref, _task} =
      open_sse(:post, live_url(server), %{"subscribe" => %{"taskId" => "no-such-task"}})

    {frames, _} = collect_until(ref, "", &(&1 != []))
    assert [%{"error" => %{"code" => "TASK_NOT_FOUND", "taskId" => "no-such-task"}} | _] = frames
  end

  test "live downlink with an unknown payload kind frames UNKNOWN_PAYLOAD", %{server: server} do
    {ref, _task} = open_sse(:post, live_url(server), %{"telepathy" => %{}})
    {frames, _} = collect_until(ref, "", &(&1 != []))
    assert [%{"error" => %{"code" => "UNKNOWN_PAYLOAD"}} | _] = frames
  end

  test "live uplink with an unknown session id is a 400 JSON error", %{server: server} do
    resp =
      Req.post!(
        url: live_url(server) <> "?live_session_id=expired",
        json: live_send_body(parked()),
        headers: @v11,
        retry: false
      )

    assert resp.status == 400
    assert %{"error" => %{"code" => 400}} = resp.body
  end

  # -- ifGenerationMatch ------------------------------------------------------------

  test "ifGenerationMatch: stale generation is 409 TASK_GENERATION_MISMATCH, matching generation succeeds",
       %{
         server: server
       } do
    {id, generation} = park_task(server)
    follow_up = Map.put(parked(), "taskId", id)

    stale = send_message(server, follow_up, %{"ifGenerationMatch" => generation + 5})
    assert stale.status == 409

    assert %{"error" => %{"code" => 409, "status" => "ABORTED", "details" => details}} =
             stale.body

    assert Enum.any?(details, &(&1["reason"] == "TASK_GENERATION_MISMATCH"))

    ok = send_message(server, follow_up, %{"ifGenerationMatch" => generation})
    assert ok.status == 200
    assert %{"task" => %{"id" => ^id}} = ok.body
  end

  # -- GET /tasks/{id}: long-poll + timelineLength ------------------------------------

  test "currentGeneration below the task's generation answers immediately", %{server: server} do
    {id, _generation} = park_task(server)

    poll =
      Task.async(fn ->
        Req.get!(
          url: server.base_url <> "/tasks/#{id}?currentGeneration=0",
          headers: @v11,
          retry: false
        )
      end)

    assert %Req.Response{status: 200, body: %{"id" => ^id}} = Task.await(poll, @deadline_ms)
  end

  test "currentGeneration at the task's generation parks until the task advances", %{
    server: server
  } do
    {id, generation} = park_task(server)

    poll =
      Task.async(fn ->
        Req.get!(
          url: server.base_url <> "/tasks/#{id}?currentGeneration=#{generation}",
          headers: @v11,
          retry: false,
          receive_timeout: 15_000
        )
      end)

    # Still parked: no answer within a short observation window.
    assert Task.yield(poll, 250) == nil

    woke = send_message(server, Map.put(parked(), "taskId", id))
    assert woke.status == 200

    assert %Req.Response{status: 200, body: body} = Task.await(poll, @deadline_ms)
    assert gen(body) > generation
  end

  test "invalid query integers are 400", %{server: server} do
    {id, _} = park_task(server)

    for query <- ["timelineLength=-1", "currentGeneration=abc", "timelineLength=x"] do
      resp =
        Req.get!(url: server.base_url <> "/tasks/#{id}?" <> query, headers: @v11, retry: false)

      assert resp.status == 400, query
    end
  end

  test "timelineLength truncates GET /tasks/{id} and GET /tasks", %{server: server} do
    {id, _} = park_task(server)
    _ = send_message(server, Map.put(parked(), "taskId", id))

    full = Req.get!(url: server.base_url <> "/tasks/#{id}", headers: @v11, retry: false)
    assert length(full.body["timeline"] || []) >= 2

    one =
      Req.get!(
        url: server.base_url <> "/tasks/#{id}?timelineLength=1",
        headers: @v11,
        retry: false
      )

    assert length(one.body["timeline"] || []) == 1

    none =
      Req.get!(
        url: server.base_url <> "/tasks/#{id}?timelineLength=0",
        headers: @v11,
        retry: false
      )

    assert (none.body["timeline"] || []) == []

    list =
      Req.get!(url: server.base_url <> "/tasks?timelineLength=1", headers: @v11, retry: false)

    assert list.status == 200
    assert Enum.all?(list.body["tasks"], &(length(&1["timeline"] || []) <= 1))
  end

  # -- SubscribeToTask lastSeenGeneration ----------------------------------------------

  test "subscribe sends the snapshot first; with lastSeenGeneration it sends none", %{
    server: server
  } do
    {id, generation} = park_task(server)

    {ref, _t} = open_sse(:get, server.base_url <> "/tasks/#{id}:subscribe")
    {[first | _], _} = collect_until(ref, "", &(&1 != []))
    assert %{"task" => %{"id" => ^id}} = first

    {ref2, _t2} =
      open_sse(:get, server.base_url <> "/tasks/#{id}:subscribe?lastSeenGeneration=#{generation}")

    # The subscription is registered once an event can be observed: advance the task.
    advance = send_message(server, Map.put(parked(), "taskId", id))
    assert advance.status == 200

    {frames, _} = collect_until(ref2, "", &(&1 != []))
    refute Enum.any?(frames, &Map.has_key?(&1, "task"))
    # v1.1 emits the messageUpdate for the advancing message before the statusUpdate.
    [first_frame | _] = frames
    assert [update] = Map.values(Map.take(first_frame, ["statusUpdate", "messageUpdate"]))
    assert gen(update) > generation
  end

  # -- artifactUpdates -------------------------------------------------------------------

  test "artifactUpdates are refused 400 UNSUPPORTED_OPERATION when the capability is off", %{
    server: server
  } do
    {id, _} = park_task(server)
    artifact = AshA2A.Protocol.JSON.encode!(Artifact.new([Part.Data.new(%{"k" => "v"})]))

    resp =
      Req.post!(
        url: server.base_url <> "/message:send",
        json: %{"artifactUpdates" => [%{"taskId" => id, "artifact" => artifact}]},
        headers: @v11,
        retry: false
      )

    assert resp.status == 400
    assert %{"error" => %{"details" => [%{"reason" => "UNSUPPORTED_OPERATION"} | _]}} = resp.body
  end

  # -- version-gated frames ----------------------------------------------------------------

  test "message:stream emits messageUpdate frames only for A2A-Version >= 1.1, all stamped", %{
    server: server
  } do
    stream = fn headers ->
      Req.post!(
        url: server.base_url <> "/message:stream",
        json: %{"message" => completing()},
        headers: headers,
        retry: false
      )
    end

    new = stream.([{"a2a-version", "1.1"}])
    assert new.status == 200
    new_frames = frames(new.body)
    assert Enum.any?(new_frames, &Map.has_key?(&1, "messageUpdate"))

    final = new_frames |> status_updates() |> List.last()
    assert is_map(final["statusUpdate"]) and Map.has_key?(final["statusUpdate"], "generation")

    old = stream.([{"a2a-version", "1.0"}])
    assert old.status == 200
    old_frames = frames(old.body)
    refute Enum.any?(old_frames, &Map.has_key?(&1, "messageUpdate"))
    assert Enum.any?(old_frames, &Map.has_key?(&1, "statusUpdate"))
  end
end
