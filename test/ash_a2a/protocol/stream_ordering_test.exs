# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Protocol.StreamOrderingTest.SlowStreamAgent do
  @moduledoc false
  # Real agent whose handle_message/2 returns a slow lazy stream (5 parts,
  # 40 ms apart) so concurrent subscribers can attach mid-stream.
  use AshA2A.Protocol.Agent, name: "slow-ordering", description: "streams five parts slowly"

  @impl AshA2A.Protocol.Agent
  def handle_message(_message, _context) do
    {:stream,
     Stream.map(1..5, fn i ->
       Process.sleep(40)
       AshA2A.Protocol.Part.Text.new("part #{i}")
     end)}
  end
end

defmodule AshA2A.Protocol.StreamOrderingTest do
  @moduledoc """
  STREAM-ORDER-002/003/004 and STREAM-SUB-001/002 courts over the real wire.

  `AshA2A.Protocol.Plug` serving `message/stream` and `tasks/resubscribe`
  through a running `AshA2A.A2ATransport` instance (the new `:transport`
  option): two concurrent subscribers over real Bandit HTTP, SSE frames
  parsed from real wire bytes, resubscribe with a real `Last-Event-ID`
  header. No mocks.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Protocol.StreamOrderingTest.SlowStreamAgent
  alias AshA2A.Test.EphemeralHttp

  setup do
    uniq = System.unique_integer([:positive])
    agent = :"slow_ordering_#{uniq}"
    transport = :"stream_ordering_#{uniq}"
    start_supervised!({SlowStreamAgent, name: agent})
    start_supervised!({AshA2A.A2ATransport, name: transport})

    http =
      EphemeralHttp.start!(
        {AshA2A.Protocol.Plug,
         agent: agent,
         base_url: "http://x/a2a",
         transport: transport,
         agent_card_opts: [capabilities: %{streaming: true}]}
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

  # Opens a streaming request in a separate process; each raw chunk is
  # forwarded to the test process which buffers and parses complete SSE
  # frames (a chunk boundary can split a frame).
  defp open_stream(url, method, params) do
    parent = self()

    spawn(fn ->
      Req.post!(url,
        json: envelope(method, params),
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

  # Collects raw chunks until the stream closes, then parses every complete
  # SSE frame (a chunk boundary can split a frame, so we buffer the whole
  # body first).
  defp drain(pid, acc \\ "") do
    receive do
      {:chunk, ^pid, data} -> drain(pid, acc <> data)
      {:stream_closed, ^pid} -> full_frames(acc)
    after
      10_000 -> flunk("stream did not close")
    end
  end

  defp await_task_id(pid, acc \\ "") do
    receive do
      {:chunk, ^pid, data} ->
        case full_frames(acc <> data) do
          [{_seq, %{"task" => %{"id" => id, "status" => _}}} | _] -> id
          _ -> await_task_id(pid, acc <> data)
        end
    after
      5_000 -> flunk("no first SSE frame")
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

  defp unwrap(%{"task" => task}), do: {:task, task}
  defp unwrap(%{"statusUpdate" => event}), do: {:status, event}
  defp unwrap(%{"artifactUpdate" => event}), do: {:artifact, event}

  defp artifact_texts(results) do
    for {_seq, result} <- results,
        {:artifact, %{"artifact" => %{"parts" => [%{"text" => t}]}}} <- [unwrap(result)] do
      t
    end
  end

  @terminal_states ["TASK_STATE_COMPLETED", "TASK_STATE_FAILED", "TASK_STATE_CANCELED",
                    "TASK_STATE_REJECTED", "TASK_STATE_AUTH_REQUIRED"]

  defp final(results) do
    Enum.find(results, fn {_seq, result} ->
      case unwrap(result) do
        {:status, %{"status" => %{"state" => state}}} -> state in @terminal_states
        _ -> false
      end
    end)
  end

  defp state({_, %{"statusUpdate" => %{"status" => %{"state" => s}}}}),
    do: s |> String.downcase() |> String.replace_prefix("task_state_", "")

  defp seqs(results), do: for({seq, _} <- results, do: seq)

  test "STREAM-SUB-001: first event of message/stream is a Task object", %{url: url} do
    a = open_stream(url, "message/stream", %{"message" => message()})
    frames = drain(a)

    assert [{seq, %{"task" => %{"id" => _, "status" => %{"state" => _}}}} | _] = frames
    assert seq == "1"
  end

  test "STREAM-ORDER-002/003: two concurrent subscribers receive the same events in the same order",
       %{url: url} do
    a = open_stream(url, "message/stream", %{"message" => message()})
    task_id = await_task_id(a)

    # B attaches mid-stream through tasks/resubscribe: backlog replay + live.
    b = open_stream(url, "tasks/resubscribe", %{"id" => task_id})

    a_results = drain(a)
    b_results = drain(b)

    a_artifacts = artifact_texts(a_results)
    b_artifacts = artifact_texts(b_results)

    assert a_artifacts == for(i <- 1..5, do: "part #{i}")
    assert b_artifacts == a_artifacts

    # Same events, same order: identical seq tokens across subscribers. The
    # resubscriber's opening snapshot carries the synthetic seq "0" (it
    # replaces the logged snapshot event), and A consumed its seq-1 snapshot
    # in await_task_id/1, so both lists cover seqs 2..7.
    assert seqs(b_results) -- ["0"] == seqs(a_results)
    assert state(final(a_results)) == "completed"
    assert final(b_results) == final(a_results)
  end

  test "STREAM-ORDER-004: closing one stream does not affect the other", %{url: url} do
    a = open_stream(url, "message/stream", %{"message" => message()})
    task_id = await_task_id(a)
    b = open_stream(url, "tasks/resubscribe", %{"id" => task_id})

    # Kill A's connection mid-stream; B must still run to completion.
    Process.exit(a, :kill)
    b_results = drain(b)

    assert artifact_texts(b_results) == for(i <- 1..5, do: "part #{i}")
    assert state(final(b_results)) == "completed"
  end

  test "STREAM-SUB-002: the stream terminates at the terminal state", %{url: url} do
    a = open_stream(url, "message/stream", %{"message" => message()})
    task_id = await_task_id(a)

    frames = drain(a)

    # The final status event is the last frame on the wire.
    {last_seq, last_result} = List.last(frames)
    assert {:status, %{"status" => %{"state" => "TASK_STATE_COMPLETED"}}} = unwrap(last_result)
    assert seqs(frames) == for(n <- 2..String.to_integer(last_seq), do: Integer.to_string(n))

    # A resubscriber after terminal gets the retained backlog replay and the
    # stream CLOSES after the terminal frame — it does not hang.
    tail = resubscribe(url, task_id) |> Map.fetch!(:body) |> full_frames()
    assert state(final(tail)) == "completed"
    assert {_, last_result} = List.last(tail)
    assert {:status, %{"status" => %{"state" => "TASK_STATE_COMPLETED"}}} = unwrap(last_result)
  end

  test "resubscribe with Last-Event-ID replays only missed events", %{url: url} do
    a = open_stream(url, "message/stream", %{"message" => message()})
    task_id = await_task_id(a)
    all = drain(a)

    tail =
      resubscribe(url, task_id, [{"last-event-id", "4"}])
      |> Map.fetch!(:body)
      |> full_frames()

    assert artifact_texts(all) == for(i <- 1..5, do: "part #{i}")
    assert artifact_texts(tail) == ["part 4", "part 5"]
    assert state(final(tail)) == "completed"
  end

  defp full_frames(body) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.flat_map(fn frame ->
      id_line = frame |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "id: "))
      data_line = frame |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "data: "))

      case {id_line, data_line} do
        {"id: " <> seq, "data: " <> json} -> [{seq, Jason.decode!(json)["result"]}]
        _ -> []
      end
    end)
  end
end
