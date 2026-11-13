defmodule AshA2A.SseGenerationFramesTest.StreamAgent do
  @moduledoc false
  use AshA2A.Protocol.Agent, name: "v13-stream", description: "streams three parts"

  @impl AshA2A.Protocol.Agent
  def handle_message(_message, _context),
    do: {:stream, Stream.map(1..3, &AshA2A.Protocol.Part.Text.new("part #{&1}"))}
end

defmodule AshA2A.SseGenerationFramesTest do
  @moduledoc """
  V13 courts: the JSON-RPC SSE builder stamps strictly increasing
  `generation` on statusUpdate/artifactUpdate frames, never emits
  messageUpdate to pre-1.1 clients, and validates `lastSeenGeneration`.
  Real agent GenServer, real Plug pipeline (Plug.Test), no mocks, no sleeps.
  """

  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias AshA2A.SseGenerationFramesTest.StreamAgent

  setup do
    agent = :"v13_agent_#{System.unique_integer([:positive])}"
    start_supervised!({StreamAgent, name: agent})

    plug_opts =
      AshA2A.Protocol.Plug.init(
        agent: agent,
        base_url: "http://x/a2a",
        agent_card_opts: [capabilities: %{streaming: true}]
      )

    %{plug_opts: plug_opts}
  end

  defp stream(plug_opts, version) do
    {:ok, msg} = AshA2A.Protocol.JSON.encode(AshA2A.Protocol.Message.new_user("go"))

    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "message/stream",
        "params" => %{"message" => msg}
      })

    conn =
      conn(:post, "/", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("a2a-version", version)
      |> AshA2A.Protocol.Plug.call(plug_opts)

    for "data: " <> json <- String.split(conn.resp_body, "\n", trim: true),
        do: Jason.decode!(json)["result"]
  end

  defp gens(results) do
    for r <- results,
        key <- ["statusUpdate", "artifactUpdate"],
        inner = r[key],
        do: inner["generation"]
  end

  test "1.1 stream: statusUpdate and artifactUpdate carry strictly increasing generations", %{
    plug_opts: plug_opts
  } do
    results = stream(plug_opts, "1.1")
    gens = gens(results)

    assert length(gens) >= 2
    assert Enum.all?(gens, &(is_integer(&1) or is_binary(&1)))
    ints = Enum.map(gens, &(&1 |> to_string() |> String.to_integer()))
    assert ints == Enum.sort(Enum.uniq(ints))
    assert hd(results)["task"]
  end

  test "1.0 stream: no messageUpdate frame and no error", %{plug_opts: plug_opts} do
    results = stream(plug_opts, "1.0")
    refute Enum.any?(results, &Map.has_key?(&1, "messageUpdate"))
    refute Enum.any?(results, &Map.has_key?(&1, "error"))
    assert hd(results)["task"]
  end

  test "invalid lastSeenGeneration answers -32602 before any stream opens" do
    conn =
      AshA2A.Protocol.Plug.SSE.subscribe_task(conn(:post, "/", ""), :unused_agent, "t", 1, 100,
        params: %{"lastSeenGeneration" => -1}
      )

    assert Jason.decode!(conn.resp_body)["error"]["code"] == -32602
  end

  test "StreamError helper writes a frame with no id line and keeps the stream open" do
    conn =
      conn(:post, "/", "")
      |> put_resp_header("content-type", "text/event-stream")
      |> send_chunked(200)
      |> AshA2A.Protocol.Plug.SSE.write_stream_error(5, %AshA2A.Protocol.StreamError{
        task_id: "t-1",
        code: "INVALID_ARGUMENT",
        message: "bad"
      })

    assert conn.state == :chunked
    assert conn.resp_body =~ "\"error\""
    refute conn.resp_body =~ "id: "
  end
end
