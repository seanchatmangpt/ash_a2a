defmodule AshA2A.ClientLiveTransportTest.RpcMismatchPlug do
  @moduledoc false
  # Real hand-written JSON-RPC server: answers every call with a v1.1
  # TASK_GENERATION_MISMATCH (-32010) error body.
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    {:ok, _body, conn} = read_body(conn)

    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "error" => %{
          "code" => -32_010,
          "message" => "generation mismatch",
          "data" => [
            %{
              "@type" => "type.googleapis.com/google.rpc.ErrorInfo",
              "reason" => "TASK_GENERATION_MISMATCH",
              "metadata" => %{"expectedGeneration" => "9", "actualGeneration" => "2"}
            }
          ]
        }
      })

    conn |> put_resp_content_type("application/json") |> send_resp(200, body)
  end
end

defmodule AshA2A.ClientLiveTransportTest do
  @moduledoc """
  V11 integration courts: the v1.1 client against the real `HTTPJSON` binding on
  a real Bandit listener over real `AshA2A.Protocol.Agent` GenServers.
  ifGenerationMatch mismatch mapping, long-poll, resubscribe with
  lastSeenGeneration, and the Live open/send/close session. Bounded by
  receive timeouts and Task.await deadlines; no sleeps.
  """

  use ExUnit.Case, async: false

  @moduletag :serial_shard

  alias AshA2A.Protocol.Client
  alias AshA2A.Protocol.Client.Live
  alias AshA2A.Protocol.Event.{MessageUpdate, StatusUpdate}
  alias AshA2A.Protocol.Task, as: T
  alias AshA2A.Test.EphemeralHttp
  alias AshA2A.Transport.HTTPJSON, as: Binding

  defmodule OpenAgent do
    use AshA2A.Protocol.Agent,
      name: "v11-client-open",
      description: "streaming, keeps tasks open",
      capabilities: %{streaming: true}

    @impl AshA2A.Protocol.Agent
    def handle_message(_message, _ctx),
      do: {:input_required, [AshA2A.Protocol.Part.Text.new("more?")]}
  end

  defmodule ArtAgent do
    use AshA2A.Protocol.Agent,
      name: "v11-client-art",
      description: "streaming + client artifacts",
      capabilities: %{streaming: true, user_artifacts: true}

    @impl AshA2A.Protocol.Agent
    def handle_message(_message, _ctx),
      do: {:input_required, [AshA2A.Protocol.Part.Text.new("more?")]}
  end

  setup do
    start_supervised!({OpenAgent, []})
    start_supervised!({ArtAgent, []})

    unless Process.whereis(AshA2A.Transport.Live.Registry),
      do: start_supervised!(AshA2A.Transport.Live.Supervisor)

    open =
      EphemeralHttp.start!(
        {Binding, Binding.init(agent: OpenAgent, base_url: "http://127.0.0.1/open")}
      )

    art =
      EphemeralHttp.start!(
        {Binding, Binding.init(agent: ArtAgent, base_url: "http://127.0.0.1/art")}
      )

    %{
      open: Client.new(open.base_url, transport: :http_json, version: "1.1"),
      art: Client.new(art.base_url, transport: :http_json, version: "1.1"),
      art_url: art.base_url
    }
  end

  test "ifGenerationMatch mismatch maps to {:task_generation_mismatch, details}", %{art: art} do
    assert {:ok, %T{id: id}} = Client.send_message(art, "hello")

    assert {:error, {:task_generation_mismatch, details}} =
             Client.send_message(art, "more", task_id: id, if_generation_match: 9_999)

    assert is_map(details)

    # artifact-only path: deterministic check against the owned task
    assert {:error, {:task_generation_mismatch, _}} =
             Client.send_message(art, nil,
               task_id: id,
               if_generation_match: 9_999,
               artifact_updates: [
                 %{
                   "taskId" => id,
                   "artifact" => %{"artifactId" => "a1", "parts" => [%{"text" => "x"}]}
                 }
               ]
             )
  end

  test "JSON-RPC -32010 maps to {:task_generation_mismatch, details}" do
    server = EphemeralHttp.start!(AshA2A.ClientLiveTransportTest.RpcMismatchPlug)
    client = Client.new(server.base_url)

    assert {:error, {:task_generation_mismatch, %{metadata: %{"expectedGeneration" => "9"}}}} =
             Client.get_task(client, "t1")
  end

  test "get_task long-poll returns once the generation advances", %{open: client} do
    assert {:ok, %T{id: id, generation: gen}} = Client.send_message(client, "hello")

    poll =
      Task.async(fn -> Client.get_task(client, id, current_generation: gen, timeout: 10_000) end)

    assert {:ok, %T{}} = Client.send_message(client, "again", task_id: id)

    assert {:ok, %T{generation: new_gen}} = Task.await(poll, 12_000)
    assert new_gen > gen
  end

  test "get_task timeline_length bounds the returned timeline", %{open: client} do
    assert {:ok, %T{id: id}} = Client.send_message(client, "one")
    assert {:ok, _} = Client.send_message(client, "two", task_id: id)

    assert {:ok, %T{timeline: timeline}} = Client.get_task(client, id, timeline_length: 1)
    assert length(timeline) <= 1
  end

  test "resubscribe with last_seen_generation sends no snapshot first", %{open: client} do
    assert {:ok, %T{id: id, generation: gen}} = Client.send_message(client, "hello")

    assert {:ok, stream} =
             Client.resubscribe(client, id,
               last_seen_generation: gen,
               timeout: 10_000,
               track_generation: true
             )

    assert {:ok, _} = Client.send_message(client, "next", task_id: id)

    assert [{:event, first} | _] = Enum.take(stream, 1)
    refute match?(%T{}, first)

    assert match?(%StatusUpdate{}, first) or match?(%MessageUpdate{}, first) or
             match?(%AshA2A.Protocol.Event.ArtifactUpdate{}, first)
  end

  test "Live open / send / close over HTTP+JSON", %{open: client} do
    assert {:ok, %T{id: id}} = Client.send_message(client, "hello")

    assert {:ok, %{events: events, session: session}} =
             Live.open(client, %{"subscribe" => %{"id" => id}}, timeout: 10_000)

    follow_up = %{AshA2A.Protocol.Message.new_user("more") | task_id: id}

    seen =
      Enum.reduce_while(events, [], fn event, acc ->
        acc = acc ++ [event]

        case event do
          %T{} ->
            assert {:ok, %T{id: ^id}} = Live.send_message(session, follow_up)
            {:cont, acc}

          %StatusUpdate{} ->
            {:halt, acc}

          %MessageUpdate{} ->
            {:halt, acc}

          _ ->
            {:cont, acc}
        end
      end)

    assert [%T{id: ^id} | rest] = seen
    assert rest != []
    assert :ok = Live.close(session)
  end

  test "Live.open refuses a JSON-RPC client", %{art_url: url} do
    assert {:error, {:transport_unsupported, :live}} =
             Live.open(Client.new(url), %{"subscribe" => %{"id" => "t"}})
  end
end
