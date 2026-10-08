# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.A2ATransport.ResubscribeTest.SlowStreamAgent do
  @moduledoc false
  # Real AshA2A.Protocol.Agent GenServer whose handle_message/2 returns a slow lazy stream
  # (5 parts, 60 ms apart) so a second subscriber can attach mid-stream.
  use AshA2A.Protocol.Agent, name: "slow-stream", description: "streams five parts slowly"

  @impl AshA2A.Protocol.Agent
  def handle_message(_message, _context) do
    {:stream,
     Stream.map(1..5, fn i ->
       Process.sleep(60)
       AshA2A.Protocol.Part.Text.new("part #{i}")
     end)}
  end
end

defmodule AshA2A.A2ATransport.ResubscribeTest do
  @moduledoc """
  `tasks/resubscribe` and multi-subscriber `message/stream` over a real
  Bandit listener serving `AshA2A.A2ATransport.Plug`, a real
  `AshA2A.A2ATransport` supervision tree, and a real streaming `AshA2A.Protocol.Agent`
  GenServer. Clients are real HTTP connections (Req); SSE frames are parsed
  from the real wire bytes. No mocks.
  """
  use ExUnit.Case, async: true

  alias AshA2A.A2ATransport.ResubscribeTest.SlowStreamAgent
  alias AshA2A.Test.EphemeralHttp

  setup do
    uniq = System.unique_integer([:positive])
    agent = :"slow_stream_#{uniq}"
    transport = :"a2a_transport_resub_#{uniq}"
    start_supervised!({SlowStreamAgent, name: agent})
    start_supervised!({AshA2A.A2ATransport, name: transport})

    http =
      EphemeralHttp.start!(
        {AshA2A.A2ATransport.Plug, agent: agent, base_url: "http://x/a2a", transport: transport}
      )

    %{url: http.base_url, agent: agent, transport: transport}
  end

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

  # Opens message/stream in a separate process that forwards each raw chunk to
  # the test process; returns that process.
  defp open_stream(url) do
    parent = self()

    spawn(fn ->
      Req.post!(url,
        json: envelope("message/stream", %{"message" => message()}),
        retry: false,
        receive_timeout: 10_000,
        into: fn {:data, data}, acc ->
          send(parent, {:chunk, self(), data})
          {:cont, acc}
        end
      )

      send(parent, {:stream_closed, self()})
    end)
  end

  defp frames(body) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.flat_map(fn frame ->
      frame
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "data: "))
      |> Enum.map(fn "data: " <> json -> Jason.decode!(json)["result"] end)
    end)
  end

  defp await_task_id(pid) do
    receive do
      {:chunk, ^pid, data} ->
        case frames(data) do
          [%{"task" => %{"id" => id, "status" => _}} | _] -> id
          _ -> await_task_id(pid)
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
      10_000 -> flunk("stream did not close")
    end
  end

  defp resubscribe(url, task_id, headers \\ []) do
    Req.post!(url,
      json: envelope("tasks/resubscribe", %{"id" => task_id}),
      headers: headers,
      retry: false,
      receive_timeout: 10_000
    )
  end

  # v1.0 wire shape: every stream frame's result is a StreamResponse oneof —
  # the snapshot carries the task, updates arrive wrapped as
  # {"statusUpdate": ...} / {"artifactUpdate": ...}.
  defp unwrap(%{"task" => task}), do: {:task, task}
  defp unwrap(%{"statusUpdate" => event}), do: {:status, event}
  defp unwrap(%{"artifactUpdate" => event}), do: {:artifact, event}

  defp artifact_texts(results) do
    for {:artifact, %{"artifact" => %{"parts" => [%{"text" => t}]}}} <- Enum.map(results, &unwrap/1),
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

  # TaskState wire spelling ("TASK_STATE_COMPLETED") normalized to "completed".
  defp state(%{"statusUpdate" => %{"status" => %{"state" => s}}}),
    do: s |> String.downcase() |> String.replace_prefix("task_state_", "")

  test "a second subscriber attached mid-stream sees the same tail and final state", %{url: url} do
    a = open_stream(url)
    task_id = await_task_id(a)

    resub = resubscribe(url, task_id)
    a_results = a |> collect() |> frames()

    assert resub.status == 200
    assert hd(Req.Response.get_header(resub, "content-type")) =~ "text/event-stream"
    b_results = frames(resub.body)

    # first resubscribe frame is the task snapshot (StreamResponse {"task": ...})
    assert %{"task" => %{"id" => ^task_id, "status" => _}} = hd(b_results)

    # v1.0: no frame carries a "final" boolean — finality is the terminal state.
    for frame <- a_results ++ b_results do
      case unwrap(frame) do
        {:status, event} -> refute Map.has_key?(event, "final")
        {:task, _task} -> :ok
        {:artifact, event} -> refute Map.has_key?(event, "final")
      end
    end
    # backlog replay + live: the resubscriber sees every part, in order
    assert artifact_texts(a_results) == for(i <- 1..5, do: "part #{i}")
    assert artifact_texts(b_results) == artifact_texts(a_results)
    assert state(final(a_results)) == "completed"
    assert final(b_results) == final(a_results)
  end

  test "the originating client disconnecting does not truncate the task", %{
    url: url,
    agent: agent
  } do
    a = open_stream(url)
    task_id = await_task_id(a)
    Process.exit(a, :kill)

    b_results = url |> resubscribe(task_id) |> Map.fetch!(:body) |> frames()

    assert artifact_texts(b_results) == for(i <- 1..5, do: "part #{i}")
    assert state(final(b_results)) == "completed"

    assert {:ok, %AshA2A.Protocol.Task{status: %{state: :completed}}} =
             GenServer.call(agent, {:get_task, task_id})
  end

  test "Last-Event-ID skips already-seen events", %{url: url} do
    a = open_stream(url)
    task_id = await_task_id(a)
    _ = collect(a)

    all = url |> resubscribe(task_id) |> Map.fetch!(:body) |> frames()
    # seq 1 = task snapshot, seq 2..6 = parts, seq 7 = final; skip through part 3 (seq 4)
    tail = url |> resubscribe(task_id, [{"last-event-id", "4"}]) |> Map.fetch!(:body) |> frames()

    assert artifact_texts(all) == for(i <- 1..5, do: "part #{i}")
    assert artifact_texts(tail) == ["part 4", "part 5"]
    assert state(final(tail)) == "completed"
  end

  test "resubscribing to a TERMINAL task with no event log is refused -32004", %{
    url: url,
    agent: agent
  } do
    # Spec §3.1.6 STREAM-SUB-003 MUST: SubscribeToTask on a terminal task
    # returns UnsupportedOperationError. With no retained log there is
    # nothing to replay, so the refusal is the whole answer.
    {:ok, task, enum} = AshA2A.Protocol.stream(agent, AshA2A.Protocol.Message.new_user("direct"))
    Enum.to_list(enum)

    resp = resubscribe(url, task.id)

    assert %{
             "error" => %{
               "code" => -32_004,
               "data" => [%{"domain" => "a2a-protocol.org", "reason" => "UNSUPPORTED_OPERATION"}]
             }
           } = resp.body
  end

  test "an unknown task id is -32001 with a TASK_NOT_FOUND ErrorInfo", %{url: url} do
    resp = resubscribe(url, "no-such-task")

    assert %{
             "error" => %{
               "code" => -32_001,
               "data" => [
                 %{
                   "@type" => "type.googleapis.com/google.rpc.ErrorInfo",
                   "domain" => "a2a-protocol.org",
                   "reason" => "TASK_NOT_FOUND"
                 }
               ]
             }
           } = resp.body
  end

  test "the v0.3 SubscribeToTask alias routes to resubscribe", %{url: url} do
    resp =
      Req.post!(url, json: envelope("SubscribeToTask", %{"id" => "no-such-task"}), retry: false)

    assert %{
             "error" => %{
               "code" => -32_001,
               "data" => [%{"domain" => "a2a-protocol.org", "reason" => "TASK_NOT_FOUND"}]
             }
           } = resp.body
  end

  test "without a running transport the plug falls back to AshA2A.Protocol.Plug's -32004", %{
    agent: agent
  } do
    opts =
      AshA2A.A2ATransport.Plug.init(agent: agent, base_url: "http://x", transport: :not_started)

    conn =
      :post
      |> Plug.Test.conn("/", Jason.encode!(envelope("tasks/resubscribe", %{"id" => "t"})))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> AshA2A.A2ATransport.Plug.call(opts)

    assert %{
             "error" => %{
               "code" => -32_004,
               "data" => [%{"domain" => "a2a-protocol.org", "reason" => "UNSUPPORTED_OPERATION"}]
             }
           } = Jason.decode!(conn.resp_body)
  end
end
