defmodule AshA2A.W3SSEStreamTest.MessageAgent do
  @moduledoc false
  use AshA2A.Protocol.Agent, name: "w3-message", description: "answers with a bare message"

  @impl AshA2A.Protocol.Agent
  def handle_message(_message, _context),
    do: {:message, [AshA2A.Protocol.Part.Text.new("direct answer")]}
end

defmodule AshA2A.W3SSEStreamTest.StreamAgent do
  @moduledoc false
  use AshA2A.Protocol.Agent, name: "w3-stream", description: "streams three parts"

  @impl AshA2A.Protocol.Agent
  def handle_message(_message, _context),
    do: {:stream, Stream.map(1..3, &AshA2A.Protocol.Part.Text.new("part #{&1}"))}
end

defmodule AshA2A.W3SSEStreamTest do
  @moduledoc """
  W3 court: message/stream per spec section 3.1.2 over a real Bandit listener
  and real agent GenServers (no mocks): a bare Message answer is one `message`
  frame then close; the final artifact chunk carries `lastChunk: true` with the
  agent's own artifactId; Last-Event-ID replays only seq > N; the resubscribe
  snapshot frame carries no `id:` line.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Test.EphemeralHttp
  alias AshA2A.W3SSEStreamTest.{MessageAgent, StreamAgent}

  defp boot(agent_mod) do
    uniq = System.unique_integer([:positive])
    agent = :"w3_agent_#{uniq}"
    transport = :"w3_transport_#{uniq}"
    start_supervised!({agent_mod, name: agent})
    start_supervised!({AshA2A.A2ATransport, name: transport})

    http =
      EphemeralHttp.start!(
        {AshA2A.A2ATransport.Plug, agent: agent, base_url: "http://x/a2a", transport: transport}
      )

    http.base_url
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

  defp post(url, method, params, headers \\ []) do
    Req.post!(url,
      json: envelope(method, params),
      headers: headers,
      retry: false,
      receive_timeout: 10_000
    ).body
  end

  # Returns [{id | nil, result}] from raw SSE bytes.
  defp frames(body) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.flat_map(fn frame ->
      lines = String.split(frame, "\n")

      for "data: " <> json <- lines do
        id =
          case Enum.find(lines, &String.starts_with?(&1, "id: ")) do
            "id: " <> v -> String.to_integer(String.trim(v))
            nil -> nil
          end

        {id, Jason.decode!(json)["result"]}
      end
    end)
  end

  test "message/stream answered with a bare Message yields exactly one message frame then closes" do
    url = boot(MessageAgent)
    body = post(url, "message/stream", %{"message" => message()})

    assert [{nil, %{"message" => %{"parts" => [%{"text" => "direct answer"}]}} = result}] =
             frames(body)

    assert map_size(result) == 1
  end

  test "final artifact chunk carries lastChunk true, earlier chunks do not, one shared artifactId" do
    url = boot(StreamAgent)
    body = post(url, "message/stream", %{"message" => message()})
    results = body |> frames() |> Enum.map(&elem(&1, 1))

    updates = for %{"artifactUpdate" => u} <- results, do: u
    assert length(updates) == 3
    assert updates |> Enum.map(& &1["artifact"]["artifactId"]) |> Enum.uniq() |> length() == 1

    {init, [last]} = Enum.split(updates, -1)
    assert Enum.all?(init, &(not Map.has_key?(&1, "lastChunk") or &1["lastChunk"] == false))
    assert last["lastChunk"] == true

    refute Enum.any?(results, fn
             %{"statusUpdate" => su} -> Map.has_key?(su, "final")
             _ -> false
           end)
  end

  test "resubscribe snapshot frame has no id line; Last-Event-ID replays only seq > N" do
    url = boot(StreamAgent)
    body = post(url, "message/stream", %{"message" => message()})
    [{_, %{"task" => %{"id" => task_id}}} | _] = frames(body)

    all = frames(post(url, "tasks/resubscribe", %{"id" => task_id}))
    assert [{nil, %{"task" => _}} | replayed] = all
    ids = Enum.map(replayed, &elem(&1, 0))
    assert Enum.all?(ids, &is_integer/1)
    assert ids == Enum.sort(ids)

    cut = Enum.at(ids, 1)

    after_cut =
      url
      |> post("tasks/resubscribe", %{"id" => task_id}, [{"last-event-id", Integer.to_string(cut)}])
      |> frames()
      |> tl()

    assert Enum.all?(after_cut, fn {id, _} -> id > cut end)
    assert length(after_cut) == length(Enum.filter(ids, &(&1 > cut)))

    non_int =
      url
      |> post("tasks/resubscribe", %{"id" => task_id}, [{"last-event-id", "garbage"}])
      |> frames()
      |> tl()

    assert Enum.map(non_int, &elem(&1, 0)) == ids
  end
end
