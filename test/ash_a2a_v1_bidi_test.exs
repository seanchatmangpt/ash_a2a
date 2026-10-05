defmodule AshA2A.V1BidiTest.BidiEchoAgent do
  @moduledoc false
  # Real `AshA2A.Protocol.Agent` whose skill opens a real bidi channel for its
  # own task and echoes every mid-stream client input as an output part.
  use AshA2A.Protocol.Agent, name: "bidi-echo", description: "echoes mid-stream inputs as artifacts"

  @impl AshA2A.Protocol.Agent
  def handle_message(_message, ctx) do
    channel = AshA2A.Bidi.open(ctx.task_id)

    {:stream,
     AshA2A.Bidi.Stream.map_input(
       channel,
       fn input ->
         AshA2A.Protocol.Part.Text.new("echo: " <> AshA2A.Bidi.Stream.text(input))
       end,
       timeout: 10_000
     )}
  end
end

defmodule AshA2A.V1BidiTest do
  @moduledoc """
  Bidirectional streaming court (lane ZD6): real wire, zero mocks.

  Real Bandit loopback listener serving `AshA2A.Bidi.Plug` (the unchanged
  `AshA2A.A2ATransport.A2ATransport` plug plus the per-stream input/close
  endpoints), a real `AshA2A.A2ATransport` event log, a real `AshA2A.Bidi`
  channel instance, and a real `AshA2A.Protocol.Agent` whose skill pulls
  mid-stream client inputs through `AshA2A.Bidi.Stream`. The client is a real
  HTTP client (Req) on two channels: the SSE `message/stream` connection
  (server→client) and the per-stream input endpoint (client→server). SSE
  frames are parsed from real wire bytes.

  Design choice under court (grounded in `ggen-marketplace/vendors/a2a`, the
  a2a v1.x docs): the spec's `message/stream` SSE connection is server→client
  only (the streaming doc: the connection "remains open for the server to
  push events to the client"); SSE has no client→server payload channel at
  all, and bidirectional streaming is an upstream roadmap item
  (a2aproject/A2A#1995). Until a bidi binding exists upstream, the only
  spec-native client→server channel is HTTP POST — so the missing direction
  is a **per-stream input endpoint**: `POST <mount>/bidi/<task_id>/input` and
  `/close`, JSON-RPC envelopes with the protocol's typed
  `google.rpc.ErrorInfo` refusals.
  """

  use ExUnit.Case, async: false

  alias AshA2A.Bidi.Channel
  alias AshA2A.Test.EphemeralHttp

  @terminal ["TASK_STATE_COMPLETED", "TASK_STATE_FAILED", "TASK_STATE_CANCELED",
             "TASK_STATE_REJECTED"]

  setup do
    # Self-healing against a lingering default-named instance from a previous
    # run (the skill's `AshA2A.Bidi.open/2` addresses the default name).
    case Process.whereis(AshA2A.Bidi) do
      nil -> :ok
      pid -> Supervisor.stop(pid)
    end

    uniq = System.unique_integer([:positive])
    agent = :"v1_bidi_#{uniq}"
    transport = :"a2a_transport_v1bidi_#{uniq}"

    start_supervised!({AshA2A.V1BidiTest.BidiEchoAgent, id: agent, name: agent})
    start_supervised!({AshA2A.A2ATransport, id: transport, name: transport})
    start_supervised!(AshA2A.Bidi)

    http =
      EphemeralHttp.start!(
        {AshA2A.Bidi.Plug, agent: agent, base_url: "http://x/a2a", transport: transport}
      )

    %{url: http.base_url, agent: agent, transport: transport}
  end

  # -- wire helpers -----------------------------------------------------------------

  defp envelope(method, params),
    do: %{
      "jsonrpc" => "2.0",
      "id" => System.unique_integer([:positive]),
      "method" => method,
      "params" => params
    }

  defp wire_message(text) do
    {:ok, encoded} = AshA2A.Protocol.JSON.encode(AshA2A.Protocol.Message.new_user(text))
    encoded
  end

  # Opens `message/stream` in a separate process that forwards every raw
  # chunk of the streaming response to the test process.
  defp open_stream(url) do
    parent = self()

    spawn(fn ->
      Req.post!(url,
        json: envelope("message/stream", %{"message" => wire_message("start")}),
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

  defp post_input(url, task_id, text) do
    Req.post!(url <> "/bidi/#{task_id}/input",
      json: envelope("bidi/input", %{"taskId" => task_id, "message" => wire_message(text)}),
      retry: false,
      receive_timeout: 5_000
    )
  end

  defp post_close(url, task_id) do
    Req.post!(url <> "/bidi/#{task_id}/close",
      json: envelope("bidi/close", %{"taskId" => task_id}),
      retry: false,
      receive_timeout: 5_000
    )
  end

  # -- SSE parsing (real wire bytes; an incomplete trailing frame is dropped) -------

  defp parse_sse(acc) do
    acc
    |> String.split("\n\n")
    |> Enum.drop(-1)
    |> Enum.flat_map(fn frame ->
      case Enum.find(String.split(frame, "\n"), &String.starts_with?(&1, "data: ")) do
        "data: " <> json -> [{id_of(frame), Jason.decode!(json)["result"]}]
        _ -> []
      end
    end)
  end

  defp id_of(frame) do
    case Enum.find(String.split(frame, "\n"), &String.starts_with?(&1, "id: ")) do
      "id: " <> v -> String.to_integer(String.trim(v))
      nil -> nil
    end
  end

  defp unwrap(%{"task" => t}), do: {:task, t}
  defp unwrap(%{"statusUpdate" => e}), do: {:status, e}
  defp unwrap(%{"artifactUpdate" => e}), do: {:artifact, e}

  defp artifact_texts(frames) do
    for {_id, result} <- frames,
        {:artifact, %{"artifact" => %{"parts" => [%{"text" => t}]}}} <- [unwrap(result)] do
      t
    end
  end

  defp final_state(frames) do
    frames
    |> Enum.map(&unwrap(elem(&1, 1)))
    |> Enum.find_value(fn
      {:status, %{"status" => %{"state" => state}}} -> state
      _ -> nil
    end)
  end

  # Waits until the accumulated wire bytes contain the artifact texts in
  # `expected` (as a prefix of all artifacts seen). Returns `acc`.
  defp await_artifacts(pid, acc, expected) do
    receive do
      {:chunk, ^pid, data} ->
        acc = acc <> data

        if Enum.take(artifact_texts(parse_sse(acc)), length(expected)) == expected do
          acc
        else
          await_artifacts(pid, acc, expected)
        end

      {:stream_closed, ^pid} ->
        flunk("stream closed before artifacts #{inspect(expected)}")
    after
      10_000 ->
        flunk(
          "timed out waiting for artifacts #{inspect(expected)}; wire so far: #{inspect(parse_sse(acc))}"
        )
    end
  end

  defp await_task_id(pid, acc \\ "") do
    receive do
      {:chunk, ^pid, data} ->
        acc = acc <> data

        case Enum.find(parse_sse(acc), fn {_id, result} ->
               match?(%{"task" => %{"id" => _}}, result)
             end) do
          nil ->
            await_task_id(pid, acc)

          {_id, %{"task" => %{"id" => id}}} ->
            {id, acc}
        end

      {:stream_closed, ^pid} ->
        flunk("stream closed before the task snapshot")
    after
      10_000 -> flunk("no first SSE frame")
    end
  end

  defp await_terminal(pid, acc) do
    receive do
      {:chunk, ^pid, data} ->
        acc = acc <> data
        frames = parse_sse(acc)

        if Enum.any?(frames, fn {_id, result} ->
             case unwrap(result) do
               {:status, %{"status" => %{"state" => state}}} -> state in @terminal
               _ -> false
             end
           end) do
          {frames, acc}
        else
          await_terminal(pid, acc)
        end

      {:stream_closed, ^pid} ->
        {parse_sse(acc), acc}
    after
      10_000 -> flunk("stream never finalized after explicit close")
    end
  end

  # -- courts -------------------------------------------------------------------------

  @tag :bidi_wire
  test "(a) three mid-stream inputs, three interleaved artifacts in order, explicit close finalizes COMPLETED, late input refused", %{
    url: url
  } do
    a = open_stream(url)
    {task_id, acc} = await_task_id(a)

    # Input 1 lands mid-stream; artifact 1 comes back only after it.
    r1 = post_input(url, task_id, "one")
    assert r1.status == 200
    assert %{"result" => %{"accepted" => true}} = Jason.decode!(r1.body)
    acc = await_artifacts(a, acc, ["echo: one"])

    # Input 2 only after artifact 1: proves the running skill pulls client
    # input while it is streaming, not up front.
    r2 = post_input(url, task_id, "two")
    assert %{"result" => %{"accepted" => true}} = Jason.decode!(r2.body)
    acc = await_artifacts(a, acc, ["echo: one", "echo: two"])

    r3 = post_input(url, task_id, "three")
    assert %{"result" => %{"accepted" => true}} = Jason.decode!(r3.body)
    acc = await_artifacts(a, acc, ["echo: one", "echo: two", "echo: three"])

    # Explicit close finalizes: the skill's input stream ends, the enum ends
    # normally, and the task completes on the real wire.
    rc = post_close(url, task_id)
    assert rc.status == 200
    assert %{"result" => %{"closed" => true, "taskId" => ^task_id}} = Jason.decode!(rc.body)

    {frames, _acc} = await_terminal(a, acc)

    assert artifact_texts(frames) == ["echo: one", "echo: two", "echo: three"]
    assert final_state(frames) == "TASK_STATE_COMPLETED"

    # One data frame per task-local event seq, strictly increasing.
    ids = for {id, _} <- frames, do: id
    assert ids == Enum.sort(Enum.uniq(ids))

    # Late input after completion: typed refusal, not a silent drop.
    late = post_input(url, task_id, "late")
    body = Jason.decode!(late.body)
    assert %{"code" => -32_004, "data" => [info]} = body["error"]
    assert info["reason"] == "BIDI_INPUT_CLOSED"
  end

  test "(b) input for an unknown task is -32001 TASK_NOT_FOUND", %{url: url} do
    resp = post_input(url, "no-such-task", "hi")
    assert resp.status == 200

    assert %{
             "error" => %{
               "code" => -32_001,
               "data" => [%{"domain" => "a2a-protocol.org", "reason" => "TASK_NOT_FOUND"}]
             }
           } = resp.body
  end

  test "(c) channel buffers pre-pull inputs in order; close yields :eof; late delivery is refused", %{
    url: _url
  } do
    task_id = "chan-#{System.unique_integer([:positive])}"
    channel = AshA2A.Bidi.open(task_id)

    m1 = AshA2A.Protocol.Message.new_user("first")
    m2 = AshA2A.Protocol.Message.new_user("second")

    # Delivered ahead of consumption: buffered, never dropped, in order.
    assert AshA2A.Bidi.deliver(task_id, m1) == {:ok, :accepted}
    assert AshA2A.Bidi.deliver(task_id, m2) == {:ok, :accepted}

    assert Channel.pull(channel, 1_000) == {:ok, m1}
    assert Channel.pull(channel, 1_000) == {:ok, m2}

    # Explicit close: the next pull gets :eof, later delivery is refused.
    assert AshA2A.Bidi.close(task_id) == :ok
    assert Channel.pull(channel, 1_000) == :eof
    assert AshA2A.Bidi.deliver(task_id, AshA2A.Protocol.Message.new_user("late")) ==
             {:error, :closed}
  end

  test "(d) delivery for a task that never opened a channel is a typed not_found", %{url: _url} do
    ghost = "ghost-#{System.unique_integer([:positive])}"

    assert AshA2A.Bidi.deliver(ghost, AshA2A.Protocol.Message.new_user("hi")) ==
             {:error, :not_found}
  end
end
