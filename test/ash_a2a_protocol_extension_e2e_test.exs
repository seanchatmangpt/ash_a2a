defmodule AshA2A.ProtocolExtensionE2ETest do
  @moduledoc """
  Real, end-to-end extension-negotiation test for lane V19 (A2A v1.0 extension
  negotiation): fronts a real, running `AshA2A.Agent`-generated
  `AshA2A.Protocol.Agent` GenServer (`AshA2A.Test.PlugFixture.GreeterAgent`)
  with a real `AshA2A.Protocol.Plug` configured with
  `extensions: [AshA2A.Protocol.Extension.Timestamp]`, and drives real
  `Plug.Test` conns through the whole negotiation pipeline:

    1. the served AgentCard advertises the Timestamp declaration in
       `capabilities.extensions` (`uri`, `required: false`, description),
    2. a `message/send` carrying the `A2A-Extensions` request header with the
       Timestamp URI gets the extension activated — the `A2A-Extensions`
       response header echoes the URI and the returned task's `metadata` is
       stamped under the extension's URI with `received_at`/`completed_at`,
    3. a request WITHOUT the header on this `required: false` extension
       succeeds unactivated (no stamp, no response header),
    4. an unknown extension URI in the header is TOLERATED (the plug only
       activates extensions it has configured and only refuses missing
       *required* declarations) — this pins the real, current behavior,
    5. a `required: true` extension missing from the header is refused with
       `ExtensionSupportRequiredError` (-32008) before dispatch, and
       activates when the header carries its URI.

  No `Mock`/`mox`/`patch`/`monkeypatch` anywhere: the agent is a real
  GenServer, the plug is the real unmodified `AshA2A.Protocol.Plug`, and the
  conns are real `Plug.Test` conns.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Protocol.Extension.Timestamp
  alias AshA2A.Test.PlugFixture.GreeterAgent

  @ts_uri Timestamp.uri()

  setup do
    # Real per-test process name so parallel `async: true` runs never collide
    # on a globally-registered GenServer name.
    agent_name = :"ext_e2e_agent_#{System.unique_integer([:positive])}"
    {:ok, pid} = GreeterAgent.start_link(name: agent_name)

    on_exit(fn ->
      try do
        if Process.alive?(pid), do: GenServer.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end)

    plug_opts =
      AshA2A.Protocol.Plug.init(
        agent: agent_name,
        base_url: "http://localhost:4000/a2a",
        extensions: [Timestamp]
      )

    %{agent: agent_name, plug_opts: plug_opts}
  end

  defp rpc(plug_opts, method, params, req_headers) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => System.unique_integer([:positive]),
        "method" => method,
        "params" => params
      })

    :post
    |> Plug.Test.conn("/", body)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.merge_req_headers(req_headers)
    |> AshA2A.Protocol.Plug.call(plug_opts)
  end

  defp message do
    {:ok, encoded} = AshA2A.Protocol.JSON.encode(AshA2A.Protocol.Message.new_user("hello"))
    encoded
  end

  defp send_task(plug_opts, req_headers \\ []) do
    resp = rpc(plug_opts, "message/send", %{"message" => message()}, req_headers)
    assert resp.status == 200
    {resp, Jason.decode!(resp.resp_body)}
  end

  # -- Agent card advertisement -----------------------------------------------

  test "served agent card advertises the Timestamp declaration in capabilities.extensions", %{
    plug_opts: plug_opts
  } do
    conn =
      Plug.Test.conn(:get, "/.well-known/agent-card.json")
      |> AshA2A.Protocol.Plug.call(plug_opts)

    assert conn.status == 200
    card = Jason.decode!(conn.resp_body)

    assert %{
             "capabilities" => %{
               "extensions" => [
                 %{
                   "uri" => @ts_uri,
                   "required" => false,
                   "description" => "Stamps requests and responses with wall-clock milliseconds."
                 }
               ]
             }
           } = card
  end

  # -- Activation over the real plug -------------------------------------------

  test "A2A-Extensions header activates the Timestamp extension end to end", %{
    plug_opts: plug_opts
  } do
    ts_uri = @ts_uri
    {conn, body} = send_task(plug_opts, [{"a2a-extensions", ts_uri}])

    # The activation is echoed in the A2A-Extensions response header ...
    assert Plug.Conn.get_resp_header(conn, "a2a-extensions") == [@ts_uri]

    # ... and the returned task is stamped under the extension's URI with the
    # real wall-clock milliseconds captured by activate/3 + handle_response/3.
    assert %{"result" => %{"task" => %{"metadata" => %{^ts_uri => stamp}}}} = body
    assert is_integer(stamp["received_at"])
    assert is_integer(stamp["completed_at"])
    assert stamp["completed_at"] >= stamp["received_at"]
  end

  test "request without the header succeeds unactivated (required: false)", %{
    plug_opts: plug_opts
  } do
    {conn, body} = send_task(plug_opts)

    assert %{"result" => %{"task" => task}} = body
    stamp = get_in(task, ["metadata", @ts_uri])
    refute stamp
    assert Plug.Conn.get_resp_header(conn, "a2a-extensions") == []
  end

  test "unknown extension URI in the header is tolerated, not activated", %{plug_opts: plug_opts} do
    unknown = "https://unknown.example/ext/nope/v1"
    ts_uri = @ts_uri
    {conn, body} = send_task(plug_opts, [{"a2a-extensions", "#{unknown}, #{ts_uri}"}])

    # The plug activates only configured extensions; an unknown URI is not a
    # rejection — the request succeeds and the known extension still runs.
    # Only the actually-activated URI is echoed on the response.
    assert Plug.Conn.get_resp_header(conn, "a2a-extensions") == [@ts_uri]

    assert %{"result" => %{"task" => %{"metadata" => %{^ts_uri => stamp}}}} = body
    assert is_integer(stamp["received_at"])
  end

  # -- Required-extension negotiation ------------------------------------------

  test "required extension missing from the header is refused with -32008 before dispatch", %{
    agent: agent
  } do
    plug_opts =
      AshA2A.Protocol.Plug.init(
        agent: agent,
        base_url: "http://localhost:4000/a2a",
        extensions: [AshA2A.Test.ProtocolExtensionE2EFixture.Passport]
      )

    {_conn, body} = send_task(plug_opts)

    # Real wire shape (lib/ash_a2a/protocol/jsonrpc/error.ex): the -32008
    # message is the fixed "Extension support is required"; the missing URIs
    # ride in the error's `data` (ErrorInfo metadata), so the full encoded
    # body carries the passport URI.
    assert %{"error" => %{"code" => -32008, "message" => "Extension support is required"}} = body
    assert Jason.encode!(body) =~ AshA2A.Test.ProtocolExtensionE2EFixture.Passport.uri()
  end

  test "required extension declared in the header activates", %{agent: agent} do
    plug_opts =
      AshA2A.Protocol.Plug.init(
        agent: agent,
        base_url: "http://localhost:4000/a2a",
        extensions: [AshA2A.Test.ProtocolExtensionE2EFixture.Passport]
      )

    {conn, body} =
      send_task(plug_opts, [
        {"a2a-extensions", AshA2A.Test.ProtocolExtensionE2EFixture.Passport.uri()}
      ])

    assert Plug.Conn.get_resp_header(conn, "a2a-extensions") == [
             AshA2A.Test.ProtocolExtensionE2EFixture.Passport.uri()
           ]

    assert %{"result" => %{"task" => %{"id" => id}}} = body
    assert is_binary(id)
  end

  # -- Required-extension negotiation on EVERY method path (W9) ----------------
  #
  # The three HTTP JSON-RPC plugs all gate on the A2A-Extensions header before
  # touching the agent: the vendored-style AshA2A.Protocol.Plug, the owner-scoped
  # AshA2A.A2ATransport.Plug wrapper, and AshA2A.Transport.Plug (which compiles
  # its extensions at init, like Protocol.Plug, since W9).

  @passport AshA2A.Test.ProtocolExtensionE2EFixture.Passport

  @all_methods [
    "message/send",
    "message/stream",
    "tasks/get",
    "tasks/cancel",
    "tasks/list",
    "tasks/resubscribe",
    "tasks/pushNotificationConfig/set",
    "tasks/pushNotificationConfig/get",
    "tasks/pushNotificationConfig/list",
    "tasks/pushNotificationConfig/delete",
    "agent/getAuthenticatedExtendedCard",
    # v0.3 PascalCase spellings route through the same gate.
    "SendMessage",
    "GetTask",
    "ListTasks",
    "SubscribeToTask",
    "GetExtendedAgentCard",
    "CreateTaskPushNotificationConfig"
  ]

  defp required_plugs(agent) do
    base = [agent: agent, base_url: "http://localhost:4000/a2a", extensions: [@passport]]

    [
      {"Protocol.Plug", AshA2A.Protocol.Plug, AshA2A.Protocol.Plug.init(base)},
      {"A2ATransport.Plug", AshA2A.A2ATransport.Plug,
       AshA2A.A2ATransport.Plug.init(base ++ [push_notifications: true])},
      {"Transport.Plug", AshA2A.Transport.Plug, AshA2A.Transport.Plug.init(base)}
    ]
  end

  defp params_for(method) do
    cond do
      method in ["message/send", "message/stream", "SendMessage"] ->
        %{"message" => message()}

      method in ["tasks/list", "ListTasks", "agent/getAuthenticatedExtendedCard", "GetExtendedAgentCard"] ->
        %{}

      method in ["tasks/pushNotificationConfig/set", "CreateTaskPushNotificationConfig"] ->
        %{
          "taskId" => "t-w9",
          "pushNotificationConfig" => %{"id" => "cfg", "url" => "https://93.184.215.14/hook"}
        }

      String.starts_with?(method, "tasks/pushNotificationConfig/") ->
        %{"id" => "t-w9", "pushNotificationConfigId" => "cfg"}

      true ->
        %{"id" => "t-w9"}
    end
  end

  defp call_plug(mod, opts, method, params, req_headers) do
    body =
      Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params})

    :post
    |> Plug.Test.conn("/", body)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.merge_req_headers(req_headers)
    |> mod.call(opts)
  end

  test "a required extension missing from the header is -32008 on every method of every plug",
       %{agent: agent} do
    for {label, mod, opts} <- required_plugs(agent), method <- @all_methods do
      conn = call_plug(mod, opts, method, params_for(method), [])
      body = Jason.decode!(conn.resp_body)

      assert get_in(body, ["error", "code"]) == -32008,
             "#{label} #{method}: expected -32008, got #{inspect(body)}"

      assert Jason.encode!(body) =~ @passport.uri()
      assert Plug.Conn.get_resp_header(conn, "a2a-extensions") == []
    end
  end

  test "a required extension present in the header is never refused with -32008 on any method",
       %{agent: agent} do
    for {label, mod, opts} <- required_plugs(agent), method <- @all_methods do
      conn = call_plug(mod, opts, method, params_for(method), [{"a2a-extensions", @passport.uri()}])

      body =
        case Plug.Conn.get_resp_header(conn, "content-type") do
          ["text/event-stream" <> _] -> %{}
          _ -> Jason.decode!(conn.resp_body)
        end

      refute get_in(body, ["error", "code"]) == -32008,
             "#{label} #{method}: negotiation refused a request that declared the extension"
    end
  end

  test "Transport.Plug activates, echoes and delivers the extension on message/send", %{agent: agent} do
    opts =
      AshA2A.Transport.Plug.init(
        agent: agent,
        base_url: "http://localhost:4000/a2a",
        extensions: [Timestamp]
      )

    conn =
      call_plug(AshA2A.Transport.Plug, opts, "message/send", %{"message" => message()}, [
        {"a2a-extensions", @ts_uri}
      ])

    assert Plug.Conn.get_resp_header(conn, "a2a-extensions") == [@ts_uri]
    ts_uri = @ts_uri
    assert %{"result" => %{"task" => %{"metadata" => %{^ts_uri => stamp}}}} = Jason.decode!(conn.resp_body)
    assert is_integer(stamp["received_at"])
    assert is_integer(stamp["completed_at"])

    # Advertise side: the compiled extension is declared on the served card.
    card =
      :get
      |> Plug.Test.conn("/.well-known/agent-card.json")
      |> AshA2A.Transport.Plug.call(opts)
      |> Map.fetch!(:resp_body)
      |> Jason.decode!()

    assert [%{"uri" => ^ts_uri}] = card["capabilities"]["extensions"]
  end

  test "repeated extension URIs compile, advertise and activate once", %{agent: agent} do
    plug_opts =
      AshA2A.Protocol.Plug.init(
        agent: agent,
        base_url: "http://localhost:4000/a2a",
        extensions: [Timestamp, {Timestamp, []}, Timestamp]
      )

    assert [{Timestamp, _, _}] = plug_opts.extensions

    card =
      :get
      |> Plug.Test.conn("/.well-known/agent-card.json")
      |> AshA2A.Protocol.Plug.call(plug_opts)
      |> Map.fetch!(:resp_body)
      |> Jason.decode!()

    assert [%{"uri" => @ts_uri}] = card["capabilities"]["extensions"]

    # A header repeating the URI activates it exactly once.
    {conn, _body} =
      send_task(plug_opts, [{"a2a-extensions", "#{@ts_uri}, #{@ts_uri}"}])

    assert Plug.Conn.get_resp_header(conn, "a2a-extensions") == [@ts_uri]
  end
end

# The `required: true` Passport fixture moved to
# test/support/protocol_extension_e2e_fixture.ex (lane F1 fix-forward): as an
# .exs-script-defined module its load state could transiently read `:nofile`
# under the full parallel suite, flaking `Code.ensure_loaded!/1` inside
# `AshA2A.Protocol.Plug.init/1`. The module name and behaviour are unchanged.
