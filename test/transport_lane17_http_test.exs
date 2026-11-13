# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.TransportLane17.Resource do
  @moduledoc false
  use Ash.Resource,
    domain: AshA2A.TransportLane17.Domain,
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

defmodule AshA2A.TransportLane17.Domain do
  @moduledoc false
  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.TransportLane17.Resource)
  end
end

defmodule AshA2A.TransportLane17.EchoAgent do
  @moduledoc false
  use AshA2A.Agent,
    resource_or_domain: AshA2A.TransportLane17.Resource,
    name: "transport_lane17_echo_agent"
end

defmodule AshA2A.TransportLane17.HTTPTest do
  @moduledoc """
  Lane 17 courts over real `Plug.Test` conns, a real supervised
  `use AshA2A.Agent` GenServer over a real ETS Ash resource and (where push
  is exercised) a real `AshA2A.A2ATransport` tree. No mocks.
  """

  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias AshA2A.A2ATransport
  alias AshA2A.Transport.{HTTPJSON, Principal}
  alias AshA2A.TransportLane17.EchoAgent

  @moduletag :serial_shard

  # A hand-written resolver (a real function, the documented `:resolver`
  # seam of WebhookPolicy): every host resolves to a public address so
  # admission does not depend on live DNS.
  def public_resolver(_host, _family), do: {:ok, [{93, 184, 216, 34}]}

  setup do
    {_sup, _registry} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [EchoAgent])

    :ok
  end

  defp message_map(text),
    do: AshA2A.Protocol.JSON.encode!(AshA2A.Protocol.Message.new_user(text))

  defp rest(opts, method, path, body \\ nil, auth \\ nil) do
    conn =
      case body do
        nil -> conn(method, path)
        b when is_binary(b) -> conn(method, path, b)
        b -> conn(method, path, Jason.encode!(b))
      end

    conn = put_req_header(conn, "content-type", "application/json")
    conn = if auth, do: put_private(conn, :a2a, %{auth: auth}), else: conn
    HTTPJSON.call(conn, opts)
  end

  defp bind_opts(extra \\ []),
    do: HTTPJSON.init([agent: EchoAgent, base_url: "http://127.0.0.1/x"] ++ extra)

  describe "Principal (finding 3)" do
    test "a raw bearer-string identity is never embedded in the owner key" do
      bearer = "eyJhbGciOi.RAW-SECRET-BEARER.sig"
      key = Principal.key(bearer)
      assert "id:" <> digest = key
      refute key =~ "RAW-SECRET"
      assert byte_size(digest) == 16
      assert key == Principal.key(bearer)
      refute key == Principal.key(bearer <> "x")
    end

    test "claim values cannot forge a second claim (delimiter escaping)" do
      forged = Principal.key(%{sub: "u|iss:evil"})
      honest = Principal.key(%{sub: "u", iss: "evil"})
      refute forged == honest
      assert honest == "sub:u|iss:evil"
      assert forged == "sub:u%7Ciss:evil"
    end

    test "the wire (string-keyed) identity resolves to the same principal as the atom shape" do
      atom = Principal.from_metadata(%{"a2a.auth" => %{identity: %{sub: "u1"}}})
      wire = Principal.from_metadata(%{"a2a.auth" => %{"identity" => %{"sub" => "u1"}}})
      assert atom == wire
      assert atom == "sub:u1"
      assert Principal.from_metadata(%{"a2a.auth" => "forged-string"}) == :anonymous
    end
  end

  describe "HTTPJSON error surface (finding 4)" do
    test "unknown path is a JSON AIP-193 404, not text/plain" do
      conn = rest(bind_opts(), :get, "/nope")
      assert conn.status == 404
      assert ["application/json" <> _] = get_resp_header(conn, "content-type")

      assert %{"error" => %{"code" => 404, "status" => "NOT_FOUND"}} =
               Jason.decode!(conn.resp_body)
    end

    test "wrong method is a JSON 405 with an allow header" do
      conn = rest(bind_opts(), :get, "/message:send")
      assert conn.status == 405
      assert get_resp_header(conn, "allow") == ["POST"]
      assert %{"error" => %{"code" => 405}} = Jason.decode!(conn.resp_body)
    end

    test "an over-cap body is 413, not 400" do
      opts = bind_opts(max_body_bytes: 64)
      big = Jason.encode!(%{"message" => message_map(String.duplicate("x", 500))})
      conn = rest(opts, :post, "/message:send", big)
      assert conn.status == 413
      assert %{"error" => %{"code" => 413}} = Jason.decode!(conn.resp_body)
    end

    test "a non-map configuration is refused 400 before any agent call" do
      conn =
        rest(bind_opts(), :post, "/message:send", %{
          "message" => message_map("hi"),
          "configuration" => "not-a-map"
        })

      assert conn.status == 400
      assert %{"error" => %{"status" => "INVALID_ARGUMENT"}} = Jason.decode!(conn.resp_body)
    end

    test "a missing message is validated by the shared Request.validate_params" do
      conn = rest(bind_opts(), :post, "/message:send", %{"nope" => 1})
      assert conn.status == 400
    end

    test "inline pushNotificationConfig is refused -32003 when push is disabled" do
      conn =
        rest(bind_opts(), :post, "/message:send", %{
          "message" => message_map("hi"),
          "configuration" => %{"pushNotificationConfig" => %{"url" => "https://hook.example/x"}}
        })

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["message"] =~ "Push"
    end

    test "message:stream's final status is the task's real state" do
      conn = rest(bind_opts(), :post, "/message:stream", %{"message" => message_map("go")})
      assert conn.status == 200

      frames =
        conn.resp_body
        |> String.split("\n\n", trim: true)
        |> Enum.map(fn "data: " <> json -> Jason.decode!(json) end)

      assert %{"task" => %{"id" => id, "status" => %{"state" => task_state}}} = hd(frames)

      final = Enum.find(frames, &Map.has_key?(&1, "statusUpdate"))
      assert %{"statusUpdate" => %{"taskId" => ^id, "status" => status}} = final

      real = rest(bind_opts(), :get, "/tasks/#{id}")
      assert real.status == 200
      real_state = Jason.decode!(real.resp_body)["status"]["state"]
      assert status["state"] == real_state
      assert is_binary(task_state)
    end

    test "POST /agent answers private,no-store and the card advertises extendedAgentCard" do
      provider = fn _identity, public -> {:ok, Map.put(public, "extra", "yes")} end
      opts = bind_opts(extended_card: provider)

      conn = rest(opts, :post, "/agent", "{}", %{identity: %{sub: "u1"}})
      assert conn.status == 200
      assert get_resp_header(conn, "cache-control") == ["private, no-store"]
      assert %{"extra" => "yes"} = Jason.decode!(conn.resp_body)

      card = rest(opts, :get, "/.well-known/agent-card.json")
      assert get_in(Jason.decode!(card.resp_body), ["capabilities", "extendedAgentCard"]) == true

      plain = rest(bind_opts(), :get, "/.well-known/agent-card.json")
      refute get_in(Jason.decode!(plain.resp_body), ["capabilities", "extendedAgentCard"]) == true
    end
  end

  describe "HTTPJSON push (finding 4)" do
    setup do
      transport = :"lane17_push_#{System.unique_integer([:positive])}"

      start_supervised!(
        {A2ATransport,
         name: transport, push: [resolver: &__MODULE__.public_resolver/2, signing_secret: "s"]}
      )

      %{opts: bind_opts(transport: transport, push_notifications: true), transport: transport}
    end

    defp create_task(opts) do
      conn = rest(opts, :post, "/message:send", %{"message" => message_map("hi")})
      assert conn.status == 200
      Jason.decode!(conn.resp_body)["task"]["id"]
    end

    test "list is {configs, nextPageToken}; delete returns {}; send publishes via TaskEvents",
         %{opts: opts, transport: transport} do
      id = create_task(opts)

      # message:send published the task into the shared event log
      assert [_ | _] = A2ATransport.TaskEvents.backlog(transport, id)

      created =
        rest(opts, :post, "/tasks/#{id}/pushNotificationConfigs", %{
          "url" => "https://hook.example/cb"
        })

      assert created.status == 200
      assert %{"id" => config_id, "taskId" => ^id} = Jason.decode!(created.resp_body)

      listed = rest(opts, :get, "/tasks/#{id}/pushNotificationConfigs")
      assert %{"configs" => [%{"taskId" => ^id}], "nextPageToken" => ""} = Jason.decode!(listed.resp_body)

      deleted = rest(opts, :delete, "/tasks/#{id}/pushNotificationConfigs/#{config_id}")
      assert deleted.status == 200
      assert Jason.decode!(deleted.resp_body) == %{}
    end

    test "inline pushNotificationConfig on message:send is attached to the created task",
         %{opts: opts, transport: transport} do
      conn =
        rest(opts, :post, "/message:send", %{
          "message" => message_map("hi"),
          "configuration" => %{"pushNotificationConfig" => %{"url" => "https://hook.example/inline"}}
        })

      assert conn.status == 200
      id = Jason.decode!(conn.resp_body)["task"]["id"]

      store = A2ATransport.push_store_name(transport)
      assert [%{url: "https://hook.example/inline"}] = A2ATransport.PushConfigStore.list(store, id)
    end

    test "the card advertises pushNotifications truthfully", %{opts: opts} do
      on = rest(opts, :get, "/.well-known/agent-card.json")
      assert get_in(Jason.decode!(on.resp_body), ["capabilities", "pushNotifications"]) == true

      off = rest(bind_opts(), :get, "/.well-known/agent-card.json")
      assert get_in(Jason.decode!(off.resp_body), ["capabilities", "pushNotifications"]) == false
    end
  end
end
