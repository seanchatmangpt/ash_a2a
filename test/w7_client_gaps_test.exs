# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.W7.Recorder do
  @moduledoc false
  # Real Plug served by a real Bandit listener (no mocks): records every request
  # to the test process and answers per `mode`.
  @behaviour Plug
  import Plug.Conn

  @error_info "type.googleapis.com/google.rpc.ErrorInfo"

  @task_working %{
    "id" => "t1",
    "contextId" => "c1",
    "status" => %{"state" => "TASK_STATE_WORKING"}
  }
  @task_done %{
    "id" => "t1",
    "contextId" => "c1",
    "status" => %{"state" => "TASK_STATE_COMPLETED"}
  }
  @card %{
    "name" => "w7",
    "description" => "d",
    "url" => "http://127.0.0.1/w7",
    "version" => "1.0.0",
    "skills" => [],
    "supportedInterfaces" => [],
    "capabilities" => %{},
    "defaultInputModes" => ["text/plain"],
    "defaultOutputModes" => ["text/plain"]
  }

  def init(opts), do: opts

  def call(conn, %{test: test, mode: mode} = opts) do
    {:ok, body, conn} = read_body(conn)

    send(
      test,
      {:req, conn.method, conn.request_path, conn.query_string, Map.new(conn.req_headers), body}
    )

    respond(mode, conn, body, opts)
  end

  defp json(conn, status, map) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(map))
  end

  defp respond(:unauthorized, conn, _body, _opts) do
    conn
    |> put_resp_header("www-authenticate", ~s(Bearer realm="a2a", error="invalid_token"))
    |> json(401, %{"error" => "Unauthorized"})
  end

  defp respond(:forbidden, conn, _body, _opts), do: json(conn, 403, %{"error" => "nope"})

  defp respond(:task_not_found, conn, _body, _opts) do
    json(conn, 404, %{
      "error" => %{
        "code" => 404,
        "status" => "NOT_FOUND",
        "message" => "no such task",
        "details" => [
          %{"@type" => @error_info, "reason" => "TASK_NOT_FOUND", "domain" => "a2a-protocol.org"}
        ]
      }
    })
  end

  defp respond(:task, conn, _body, _opts), do: json(conn, 200, @task_working)

  # Counter-driven: the first `working` GETs answer WORKING, then COMPLETED.
  defp respond(:await, conn, _body, %{counter: counter, working: working}) do
    n = Elixir.Agent.get_and_update(counter, fn n -> {n, n + 1} end)
    json(conn, 200, if(n < working, do: @task_working, else: @task_done))
  end

  defp respond(:sse, conn, _body, _opts) do
    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> send_chunked(200)

    {:ok, conn} = chunk(conn, "data: " <> Jason.encode!(%{"task" => @task_working}) <> "\n\n")
    {:ok, conn} = chunk(conn, "data: " <> Jason.encode!(%{"task" => @task_done}) <> "\n\n")
    conn
  end

  defp respond(:rpc, conn, body, _opts) do
    %{"id" => id, "method" => method} = Jason.decode!(body)

    result =
      case method do
        "ListTasks" ->
          %{"tasks" => [@task_working], "totalSize" => 1, "pageSize" => 1, "nextPageToken" => ""}

        "GetExtendedAgentCard" ->
          @card

        "SendMessage" ->
          %{"task" => @task_done}

        _ ->
          @task_working
      end

    json(conn, 200, %{"jsonrpc" => "2.0", "id" => id, "result" => result})
  end

  # agent-card.json is gone (404), only the legacy agent.json path serves.
  defp respond(:legacy_card, %{request_path: "/.well-known/agent.json"} = conn, _body, _opts),
    do: json(conn, 200, @card)

  defp respond(:legacy_card, conn, _body, _opts), do: json(conn, 404, %{"error" => "gone"})

  defp respond(:card, conn, _body, _opts), do: json(conn, 200, @card)
end

defmodule AshA2A.W7.Trace do
  @moduledoc false
  @behaviour AshA2A.Protocol.Client.Interceptor

  @impl true
  def before_request(req), do: Req.Request.put_header(req, "x-w7-trace", "on")

  @impl true
  def after_response(_req, response) do
    send(Process.get(:w7_test) || self(), {:after_response, response.status})
    response
  end
end

defmodule AshA2A.W7.ClientGapsTest do
  @moduledoc """
  Real-wire court for the W7 client gaps: transport selection from the card,
  symmetric stream/resubscribe/list/extended-card ops, tenant, auth,
  interceptors, streaming error bodies, await_task, discovery options.
  Servers are real Bandit listeners; no mocks.
  """

  use ExUnit.Case, async: false

  @moduletag :serial_shard

  alias AshA2A.Protocol.{AgentCard, Client}
  alias AshA2A.Protocol.Client.Auth
  alias AshA2A.Protocol.SecurityScheme.APIKey
  alias AshA2A.Test.EphemeralHttp
  alias AshA2A.W7.Recorder

  defp serve!(mode, extra \\ %{}) do
    EphemeralHttp.start!({Recorder, Map.merge(%{test: self(), mode: mode}, extra)})
  end

  defp card(attrs) do
    struct!(
      AgentCard,
      Map.merge(
        %{name: "w7", description: "d", url: "http://127.0.0.1:1", version: "1.0.0", skills: []},
        Map.new(attrs)
      )
    )
  end

  defp iface(binding, url, extra \\ %{}) do
    Map.merge(%{url: url, protocol_binding: binding, protocol_version: "1.0"}, extra)
  end

  # -- G1: from_card ---------------------------------------------------------------

  test "from_card/2 takes the first supported interface in card order" do
    c =
      card(
        supported_interfaces: [
          iface("GRPC", "http://g"),
          iface("HTTP+JSON", "http://rest.example/a2a", %{tenant: "acme"}),
          iface("JSONRPC", "http://rpc.example")
        ]
      )

    assert {:ok, client} = Client.from_card(c)
    assert client.transport == :http_json
    assert client.url == "http://rest.example/a2a"
    assert client.tenant == "acme"
    assert client.card == c
    assert client.interface.protocol_binding == "HTTP+JSON"
    assert client.version == "1.0"
  end

  test "from_card/2 :preferred_bindings overrides card order" do
    c =
      card(
        supported_interfaces: [
          iface("HTTP+JSON", "http://rest.example"),
          iface("JSONRPC", "http://rpc.example")
        ]
      )

    assert {:ok, client} = Client.from_card(c, preferred_bindings: [:jsonrpc, :http_json])
    assert client.transport == :jsonrpc
    assert client.url == "http://rpc.example"
  end

  test "from_card/2 with no usable interface answers :no_supported_interface" do
    c = card(supported_interfaces: [iface("GRPC", "http://g")])
    assert {:error, :no_supported_interface} = Client.from_card(c)

    c2 = card(supported_interfaces: [iface("JSONRPC", "http://rpc.example")])

    assert {:error, :no_supported_interface} =
             Client.from_card(c2, preferred_bindings: [:http_json])
  end

  test "from_card/2 falls back to legacy card.url + preferred_transport" do
    c =
      card(
        supported_interfaces: [],
        url: "http://legacy.example",
        preferred_transport: "HTTP+JSON"
      )

    assert {:ok, client} = Client.from_card(c)
    assert client.transport == :http_json
    assert client.url == "http://legacy.example"

    c2 = card(supported_interfaces: [], url: "http://legacy.example")
    assert {:ok, %{transport: :jsonrpc}} = Client.from_card(c2)
  end

  test "from_card/2 refuses a required card extension the client did not declare" do
    ext = %AshA2A.Protocol.AgentExtension{uri: "https://example.com/ext/required", required: true}

    c =
      card(
        supported_interfaces: [iface("JSONRPC", "http://rpc.example")],
        capabilities: %{extensions: [ext]}
      )

    assert {:error, {:required_extension_not_supported, ["https://example.com/ext/required"]}} =
             Client.from_card(c)
  end

  # -- G8: capability negotiation ---------------------------------------------------

  test "known card without streaming/push answers typed local errors (no request sent)" do
    c =
      card(
        supported_interfaces: [iface("JSONRPC", "http://127.0.0.1:1")],
        capabilities: %{streaming: false, push_notifications: false}
      )

    {:ok, client} = Client.from_card(c)

    assert {:error, :streaming_not_supported} = Client.stream_message(client, "x")

    assert {:error, :push_notifications_not_supported} =
             Client.set_push_config(client, %AshA2A.Protocol.PushNotificationConfig{
               task_id: "t1",
               url: "http://127.0.0.1:2/hook"
             })
  end

  test "send_and_stream/3 degrades to send_message/3 when the card declares no streaming" do
    server = serve!(:rpc)

    c =
      card(
        supported_interfaces: [iface("JSONRPC", server.base_url)],
        capabilities: %{streaming: false}
      )

    {:ok, client} = Client.from_card(c)

    assert {:ok, [%AshA2A.Protocol.Task{}]} = Client.send_and_stream(client, "hello")
    assert_receive {:req, "POST", "/", _, _, body}
    assert %{"method" => "SendMessage"} = Jason.decode!(body)
  end

  # -- G2: symmetric ops --------------------------------------------------------------

  test "http_json stream_message/3 reads bare StreamResponse frames" do
    server = serve!(:sse)
    client = Client.new(server.base_url, transport: :http_json)

    assert {:ok, stream} = Client.stream_message(client, "go")
    events = Enum.to_list(stream)

    assert [%AshA2A.Protocol.Task{}, %AshA2A.Protocol.Task{}] = events
    assert_receive {:req, "POST", "/message:stream", _, headers, _}
    assert headers["accept"] =~ "text/event-stream"
  end

  test "http_json resubscribe/3 is GET /tasks/{id}:subscribe and streams" do
    server = serve!(:sse)
    client = Client.new(server.base_url, transport: :http_json)

    assert {:ok, stream} = Client.resubscribe(client, "t1")
    assert [%AshA2A.Protocol.Task{} | _] = Enum.to_list(stream)
    assert_receive {:req, "GET", "/tasks/t1:subscribe", _, _, _}
  end

  test "jsonrpc list_tasks/2 and get_extended_card/2 send the v1 methods" do
    server = serve!(:rpc)
    client = Client.new(server.base_url)

    assert {:ok, %{tasks: [%AshA2A.Protocol.Task{id: "t1"}], total_size: 1}} =
             Client.list_tasks(client, page_size: 1)

    assert_receive {:req, "POST", _, _, _, body}
    assert %{"method" => "ListTasks", "params" => %{"pageSize" => 1}} = Jason.decode!(body)

    assert {:ok, %AgentCard{name: "w7"}} = Client.get_extended_card(client)
    assert_receive {:req, "POST", _, _, _, body2}
    assert %{"method" => "GetExtendedAgentCard"} = Jason.decode!(body2)
  end

  # -- G4: tenant ----------------------------------------------------------------------

  test "tenant prefixes REST paths" do
    server = serve!(:task)
    client = Client.new(server.base_url, transport: :http_json, tenant: "acme")

    assert {:ok, %AshA2A.Protocol.Task{id: "t1"}} = Client.get_task(client, "t1")
    assert_receive {:req, "GET", "/acme/tasks/t1", _, _, _}
  end

  test "tenant is sent as params.tenant over JSON-RPC" do
    server = serve!(:rpc)
    client = Client.new(server.base_url, tenant: "acme")

    assert {:ok, %AshA2A.Protocol.Task{}} = Client.get_task(client, "t1")
    assert_receive {:req, "POST", _, _, _, body}

    assert %{"method" => "GetTask", "params" => %{"tenant" => "acme", "id" => "t1"}} =
             Jason.decode!(body)
  end

  # -- G5: streaming error bodies, Last-Event-ID, await_task -----------------------------

  test "stream error bodies are decoded into typed errors, not {:unexpected_status, _}" do
    server = serve!(:task_not_found)
    client = Client.new(server.base_url, transport: :http_json)

    assert {:error, :task_not_found} = Client.stream_message(client, "go")
    assert {:error, :task_not_found} = Client.resubscribe(client, "t1")
  end

  test ":last_event_id becomes the Last-Event-ID header on resubscribe" do
    server = serve!(:task_not_found)
    client = Client.new(server.base_url, transport: :http_json)

    assert {:error, :task_not_found} = Client.resubscribe(client, "t1", last_event_id: 42)
    assert_receive {:req, "GET", "/tasks/t1:subscribe", _, headers, _}
    assert headers["last-event-id"] == "42"
  end

  test "await_task/3 polls until the task is terminal" do
    {:ok, counter} = Elixir.Agent.start_link(fn -> 0 end)
    server = serve!(:await, %{counter: counter, working: 2})
    client = Client.new(server.base_url, transport: :http_json)

    assert {:ok, task} = Client.await_task(client, "t1", interval: 5, timeout: 5_000)
    assert AshA2A.Protocol.Task.terminal?(task)
    assert Elixir.Agent.get(counter, & &1) == 3
  end

  test "await_task/3 answers {:await_timeout, last_task} when the deadline passes" do
    server = serve!(:task)
    client = Client.new(server.base_url, transport: :http_json)

    assert {:error, {:await_timeout, %AshA2A.Protocol.Task{id: "t1"}}} =
             Client.await_task(client, "t1", interval: 5, timeout: 50)
  end

  # -- G6: auth, challenges, interceptors ----------------------------------------------------

  test "Auth.parse_challenge/1 parses scheme and auth-params" do
    assert [%{scheme: "Bearer", params: %{"realm" => "a2a", "error" => "invalid_token"}}] =
             Auth.parse_challenge(~s(Bearer realm="a2a", error=invalid_token))

    assert [%{scheme: "Basic", params: %{"realm" => "x y"}}, %{scheme: "Bearer"}] =
             Auth.parse_challenge([~s(Basic realm="x y"), "Bearer"])
  end

  test "Auth.credentials/2 places bearer, basic, api-key (header/query/cookie)" do
    c =
      card(
        security_schemes: %{
          "hdr" => %APIKey{name: "X-Key", in: "header"},
          "qry" => %APIKey{name: "k", in: "query"},
          "cok" => %APIKey{name: "sid", in: "cookie"},
          "bas" => %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "basic"},
          "bea" => %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "bearer"}
        }
      )

    placed =
      Auth.credentials(
        %{"hdr" => "h1", "qry" => "q1", "cok" => "c1", "bas" => "user:pw", "bea" => "tok"},
        c
      )

    assert {"x-key", "h1"} in placed.headers
    assert {"authorization", "Bearer tok"} in placed.headers
    assert {"authorization", "Basic " <> Base.encode64("user:pw")} in placed.headers
    assert placed.query == [{"k", "q1"}]
    assert placed.cookies == [{"sid", "c1"}]
  end

  test ":auth map sends Authorization on the wire; callback form receives card requirements" do
    server = serve!(:task)
    client = Client.new(server.base_url, transport: :http_json, auth: %{"bearer_auth" => "tok-1"})
    assert {:ok, _} = Client.get_task(client, "t1")
    assert_receive {:req, "GET", "/tasks/t1", _, headers, _}
    assert headers["authorization"] == "Bearer tok-1"

    cb = fn requirements ->
      send(self(), {:requirements, requirements})
      [{"x-cb", "yes"}]
    end

    client2 = Client.new(server.base_url, transport: :http_json, auth: cb)
    assert {:ok, _} = Client.get_task(client2, "t1")
    assert_receive {:requirements, []}
    assert_receive {:req, "GET", "/tasks/t1", _, headers2, _}
    assert headers2["x-cb"] == "yes"
  end

  test "API-key auth in a query parameter reaches the server" do
    server = serve!(:task)
    c = card(security_schemes: %{"k" => %APIKey{name: "api_key", in: "query"}})

    client =
      Client.new(server.base_url, transport: :http_json, auth: %{"k" => "sekret"}, card: c)

    assert {:ok, _} = Client.get_task(client, "t1")
    assert_receive {:req, "GET", "/tasks/t1", "api_key=sekret", _, _}
  end

  test "401 surfaces the parsed WWW-Authenticate challenge; 403 surfaces the body" do
    unauth = serve!(:unauthorized)
    client = Client.new(unauth.base_url, transport: :http_json)

    assert {:error, {:unauthorized, [%{scheme: "Bearer", params: params}]}} =
             Client.get_task(client, "t1")

    assert params["realm"] == "a2a"

    # same typed error on the stream path
    assert {:error, {:unauthorized, [%{scheme: "Bearer"}]}} = Client.resubscribe(client, "t1")

    forbidden = serve!(:forbidden)
    client2 = Client.new(forbidden.base_url, transport: :http_json)
    assert {:error, {:forbidden, %{"error" => "nope"}}} = Client.get_task(client2, "t1")

    rpc_client = Client.new(unauth.base_url)
    assert {:error, {:unauthorized, _}} = Client.get_task(rpc_client, "t1")
  end

  test ":interceptors run before_request and after_response" do
    Process.put(:w7_test, self())
    server = serve!(:task)
    client = Client.new(server.base_url, transport: :http_json, interceptors: [AshA2A.W7.Trace])

    assert {:ok, _} = Client.get_task(client, "t1")
    assert_receive {:req, "GET", "/tasks/t1", _, headers, _}
    assert headers["x-w7-trace"] == "on"
    assert_receive {:after_response, 200}
  end

  # -- G9: discovery -----------------------------------------------------------------------------

  test "discover/2 agent.json fallback is opt-in on 404" do
    server = serve!(:legacy_card)

    assert {:error, {:unexpected_status, 404}} = Client.discover(server.base_url)

    assert {:ok, %AgentCard{name: "w7"}} =
             Client.discover(server.base_url, agent_json_fallback: true)
  end

  test "discover/2 cache: true serves the second call from disk without a request" do
    dir = Path.join(System.tmp_dir!(), "w7_card_cache_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    server = serve!(:card)

    assert {:ok, %AgentCard{name: "w7"}} =
             Client.discover(server.base_url, cache: true, cache_dir: dir, max_age: 300)

    assert_receive {:req, "GET", "/.well-known/agent-card.json", _, _, _}

    assert {:ok, %AgentCard{name: "w7"}} =
             Client.discover(server.base_url, cache: true, cache_dir: dir, max_age: 300)

    refute_receive {:req, _, _, _, _, _}, 0
  end

  test "cached cards still pass the admission gate (verifier fun)" do
    dir = Path.join(System.tmp_dir!(), "w7_card_cache_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    server = serve!(:card)

    assert {:ok, _} = Client.discover(server.base_url, cache: true, cache_dir: dir)

    assert {:error, {:card_signature, :nope}} =
             Client.discover(server.base_url,
               cache: true,
               cache_dir: dir,
               verify_card_signature: fn _card -> {:error, :nope} end
             )

    assert {:ok, _} =
             Client.discover(server.base_url,
               cache: true,
               cache_dir: dir,
               verify_card_signature: fn _card -> :ok end
             )
  end
end
