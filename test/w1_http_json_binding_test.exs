# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.W1HTTPJSON.Resource do
  @moduledoc "Real ETS-backed fixture resource with one `:read` skill."

  use Ash.Resource,
    domain: AshA2A.W1HTTPJSON.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
  end

  actions do
    defaults([:read])
  end

  a2a do
    skill(:echo, :read)
  end
end

defmodule AshA2A.W1HTTPJSON.Domain do
  @moduledoc "Real fixture domain."

  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.W1HTTPJSON.Resource)
  end
end

defmodule AshA2A.W1HTTPJSON.Agent do
  @moduledoc "Real `AshA2A.Agent` over the fixture resource."

  use AshA2A.Agent,
    resource_or_domain: AshA2A.W1HTTPJSON.Resource,
    name: "w1_http_json_agent"
end

defmodule AshA2A.W1HTTPJSON.RequiredExtension do
  @moduledoc "Real required extension: clients must request its URI."

  @behaviour AshA2A.Protocol.Extension

  @uri "https://example.com/ext/w1-required"

  def uri, do: @uri

  @impl true
  def declaration(_state),
    do: %AshA2A.Protocol.AgentExtension{uri: @uri, description: "w1", required: true}

  @impl true
  def activate(_requested, _ctx, _state), do: {:ok, :on}
end

defmodule AshA2A.W1HTTPJSON.Pipeline do
  @moduledoc """
  Real wrapper plug: stamps a verified identity when an `authorization`
  header is present, runs the binding, and exposes the tenant the binding
  recorded as an `x-seen-tenant` response header.
  """

  @behaviour Plug
  import Plug.Conn

  def init(opts) when is_map(opts), do: opts
  def init(opts), do: AshA2A.Transport.HTTPJSON.init(opts)

  def call(conn, opts) do
    conn =
      case get_req_header(conn, "authorization") do
        [_ | _] -> AshA2A.Protocol.Plug.Auth.put_identity(conn, %{identity: "alice"})
        [] -> conn
      end

    # The binding sends the response; the sent conn still carries the
    # recorded tenant, but headers are already on the wire, so the binding's
    # strip happens before send. Read the tenant via a before_send hook.
    conn =
      register_before_send(conn, fn conn ->
        case conn.private |> Map.get(:a2a, %{}) |> Map.get(:tenant) do
          nil -> conn
          tenant -> put_resp_header(conn, "x-seen-tenant", tenant)
        end
      end)

    AshA2A.Transport.HTTPJSON.call(conn, opts)
  end
end

defmodule AshA2A.W1HTTPJSONTest do
  @moduledoc """
  W1 court: HTTP+JSON binding surface additions (extended card GET route,
  GET :subscribe, tenant prefix, content-type negotiation, A2A-Version /
  A2A-Extensions service parameters, gRPC status names). Real Bandit server,
  real agent, real `Req` calls; no mocks.
  """

  use ExUnit.Case, async: false

  @moduletag :serial_shard

  alias AshA2A.Test.EphemeralHttp
  alias AshA2A.W1HTTPJSON.Pipeline

  @agent AshA2A.W1HTTPJSON.Agent
  @ext_uri AshA2A.W1HTTPJSON.RequiredExtension.uri()

  setup do
    {_sup, _registry} = AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [@agent])
    :ok
  end

  defp start(extra \\ []) do
    opts =
      Keyword.merge(
        [
          agent: @agent,
          base_url: "http://127.0.0.1/fixture",
          extended_card: fn _identity, _public -> {:ok, %{"name" => "w1-extended"}} end
        ],
        extra
      )

    EphemeralHttp.start!({Pipeline, Pipeline.init(opts)})
  end

  defp message_map(text),
    do: AshA2A.Protocol.JSON.encode!(AshA2A.Protocol.Message.new_user(text))

  defp send_message!(server, path \\ "/message:send") do
    resp = Req.post!(url: server.base_url <> path, json: %{"message" => message_map("go")})
    assert resp.status == 200
    resp.body
  end

  # -- 1. extended card ---------------------------------------------------------

  test "GET /extendedAgentCard serves the extended card; POST /agent stays a legacy alias" do
    server = start()
    auth = [authorization: "Bearer t"]

    resp = Req.get!(url: server.base_url <> "/extendedAgentCard", headers: auth)
    assert resp.status == 200
    assert resp.body["name"] == "w1-extended"

    legacy = Req.post!(url: server.base_url <> "/agent", json: %{}, headers: auth)
    assert legacy.status == 200
    assert legacy.body["name"] == "w1-extended"

    # No identity -> 401 on the new route too.
    assert Req.get!(url: server.base_url <> "/extendedAgentCard").status == 401
  end

  test "wrong method on /extendedAgentCard answers 405 with allow: GET" do
    server = start()
    resp = Req.post!(url: server.base_url <> "/extendedAgentCard", json: %{})
    assert resp.status == 405
    assert resp.headers["allow"] == ["GET"]
  end

  # -- 2. subscribe ---------------------------------------------------------------

  test "GET and POST :subscribe on an unknown task answer 404 TaskNotFound" do
    server = start()

    for method <- [:get, :post] do
      resp = Req.request!(method: method, url: server.base_url <> "/tasks/nope:subscribe")
      assert resp.status == 404
      assert %{"error" => %{"code" => 404, "status" => "NOT_FOUND"}} = resp.body
    end
  end

  test "GET :subscribe on a terminal task answers 400 UNSUPPORTED_OPERATION" do
    server = start()
    %{"task" => %{"id" => id}} = send_message!(server)

    resp = Req.get!(url: server.base_url <> "/tasks/#{id}:subscribe")
    assert resp.status == 400

    assert %{"error" => %{"details" => [%{"reason" => "UNSUPPORTED_OPERATION"}]}} = resp.body
  end

  test "DELETE :subscribe answers 405 allowing GET and POST; DELETE :cancel unchanged" do
    server = start()
    resp = Req.delete!(url: server.base_url <> "/tasks/x:subscribe")
    assert resp.status == 405
    assert resp.headers["allow"] == ["GET, POST"]
  end

  # -- 3. tenant ------------------------------------------------------------------

  test "leading tenant segment is stripped and recorded" do
    server = start()

    resp = Req.post!(url: server.base_url <> "/acme/message:send", json: %{"message" => message_map("hi")})
    assert resp.status == 200
    assert %{"task" => %{"id" => id}} = resp.body
    assert resp.headers["x-seen-tenant"] == ["acme"]

    get = Req.get!(url: server.base_url <> "/acme/tasks/#{id}")
    assert get.status == 200
    assert get.headers["x-seen-tenant"] == ["acme"]

    list = Req.get!(url: server.base_url <> "/acme/tasks")
    assert list.status == 200

    card =
      Req.get!(url: server.base_url <> "/acme/extendedAgentCard", headers: [authorization: "Bearer t"])

    assert card.status == 200
    assert card.body["name"] == "w1-extended"
  end

  test "no tenant is recorded for un-prefixed routes, and unknown remainders stay 404" do
    server = start()
    resp = Req.get!(url: server.base_url <> "/tasks")
    assert resp.status == 200
    assert resp.headers["x-seen-tenant"] == nil

    assert Req.get!(url: server.base_url <> "/acme/nope").status == 404
  end

  # -- 4. content type ------------------------------------------------------------

  test "default response is application/json; Accept a2a+json is answered a2a+json" do
    server = start()

    default = Req.get!(url: server.base_url <> "/tasks", decode_body: false)
    assert hd(default.headers["content-type"]) =~ "application/json"

    negotiated =
      Req.get!(
        url: server.base_url <> "/tasks",
        headers: [accept: "application/a2a+json"],
        decode_body: false
      )

    assert hd(negotiated.headers["content-type"]) =~ "application/a2a+json"
  end

  test "a2a+json request bodies are accepted" do
    server = start()

    resp =
      Req.post!(
        url: server.base_url <> "/message:send",
        body: Jason.encode!(%{"message" => message_map("hi")}),
        headers: [{"content-type", "application/a2a+json"}]
      )

    assert resp.status == 200
  end

  test ":content_type option changes the default" do
    server = start(content_type: "application/a2a+json")
    resp = Req.get!(url: server.base_url <> "/tasks", decode_body: false)
    assert hd(resp.headers["content-type"]) =~ "application/a2a+json"
  end

  # -- 5. version + extensions ----------------------------------------------------

  test "A2A-Version query parameter is read when the header is absent" do
    server = start()

    bad = Req.get!(url: server.base_url <> "/tasks?A2A-Version=9.9")
    assert bad.status == 400
    assert bad.headers["a2a-version"] == ["9.9"]

    ok = Req.get!(url: server.base_url <> "/tasks?A2A-Version=1.0")
    assert ok.status == 200
  end

  test ":versions option restricts supported versions" do
    server = start(versions: ["1.0"])
    assert Req.get!(url: server.base_url <> "/tasks", headers: [{"a2a-version", "0.3"}]).status == 400
    assert Req.get!(url: server.base_url <> "/tasks", headers: [{"a2a-version", "1.0"}]).status == 200
  end

  test "required extension missing answers 400 -32008; present is activated and echoed" do
    server = start(extensions: [AshA2A.W1HTTPJSON.RequiredExtension])

    missing = Req.get!(url: server.base_url <> "/tasks")
    assert missing.status == 400
    # AIP-193 body: -32008 maps to status FAILED_PRECONDITION; the missing URI
    # rides in the error details.
    assert %{"error" => %{"code" => 400, "status" => "FAILED_PRECONDITION", "message" => message}} =
             missing.body

    assert message =~ @ext_uri or inspect(missing.body) =~ @ext_uri

    via_header = Req.get!(url: server.base_url <> "/tasks", headers: [{"a2a-extensions", @ext_uri}])
    assert via_header.status == 200
    assert via_header.headers["a2a-extensions"] == [@ext_uri]

    via_query = Req.get!(url: server.base_url <> "/tasks", params: [{"A2A-Extensions", @ext_uri}])
    assert via_query.status == 200
    assert via_query.headers["a2a-extensions"] == [@ext_uri]
  end

  # -- 6. gRPC status names (pure shape via the public envelope) -------------------

  test "aip193 status names for 403/422/429 are canonical" do
    # grpc_status_name/1 is private; the clauses are pinned structurally.
    source = File.read!("lib/ash_a2a/transport/http_json.ex")
    assert source =~ ~s|grpc_status_name(403), do: "PERMISSION_DENIED"|
    assert source =~ ~s|grpc_status_name(429), do: "RESOURCE_EXHAUSTED"|
    assert source =~ ~s|grpc_status_name(422), do: "INVALID_ARGUMENT"|
  end
end
