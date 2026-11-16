# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
# SPDX-License-Identifier: MIT
#
# ============================================================================== 
# Consolidated Test Suite: A2A Transport & Protocol (Worker 20 Part 2)
# Target File: test/ash_a2a/a2a_transport/transport_protocol_consolidated_test.exs
# Total Source Files Consolidated: 15
# Source Files Inventory:
#   - test/ash_a2a/a2a_transport/at5_hardening_test.exs
#   - test/ash_a2a/a2a_transport/extended_card_test.exs
#   - test/ash_a2a/a2a_transport/ownership_test.exs
#   - test/ash_a2a/a2a_transport/push_notification_test.exs
#   - test/ash_a2a/a2a_transport/resubscribe_test.exs
#   - test/ash_a2a/a2a_transport/spec_mapping_doc_test.exs
#   - test/ash_a2a/a2a_transport/webhook_policy_test.exs
#   - test/ash_a2a/egress/endpoint_policy_test.exs
#   - test/ash_a2a/protocol/list_tasks_owner_scope_test.exs
#   - test/ash_a2a/protocol/orphan_sweep_unsupported_test.exs
#   - test/ash_a2a/protocol/plug/security_validators_test.exs
#   - test/ash_a2a/protocol/stream_ordering_test.exs
#   - test/ash_a2a/supply_chain/release_path_test.exs
#   - test/ash_a2a/supply_chain/supply_chain_policy_test.exs
#   - test/ash_a2a/transport/transport_court_test.exs
# ==============================================================================


# ==============================================================================
# SECTION 1 of 15: test/ash_a2a/a2a_transport/at5_hardening_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.A2ATransport.At5HardeningTest.ReplyAgent do
  @moduledoc false
  use AshA2A.Protocol.Agent, name: "at5-reply", description: "replies ok"

  @impl true
  def handle_message(_message, _context), do: {:reply, [AshA2A.Protocol.Part.Text.new("ok")]}
end

defmodule AshA2A.A2ATransport.At5HardeningTest.CrashAgent do
  @moduledoc false
  # Real agent whose handler genuinely crashes — the crash surfaces on the
  # wire only through the transport's error shaping, never verbatim.
  use AshA2A.Protocol.Agent, name: "at5-crash", description: "crashes"

  @impl true
  def handle_message(_message, _context),
    do: raise(RuntimeError, "pg secret connection refused 10.0.0.9")
end

defmodule AshA2A.A2ATransport.At5HardeningTest do
  @moduledoc """
  Adversarial hardening court for lane AT5 over the real HTTP surface:

    1. `params.metadata` cannot clobber the verified `"a2a.auth"` identity
       (auth downgrade / authorizer spoofing via the JSON-RPC metadata merge).
    2. Handler crashes answer -32603 with an opaque `ref` — the exception
       text never reaches the wire (SEC-08).
    3. The push sender refuses non-HTTP(S) webhook URLs and credential
       values carrying control characters (header injection) typed, before
       any connection is opened.
  """

  use ExUnit.Case, async: true

  alias AshA2A.A2ATransport.At5HardeningTest.{CrashAgent, ReplyAgent}
  alias AshA2A.Protocol.Plug, as: VendoredPlug
  alias AshA2A.Protocol.PushNotificationSender.HTTP, as: PushHTTP

  @schemes %{"bearer" => %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "bearer"}}

  def verify("bearer", token, _conn), do: {:ok, %{sub: token}}

  setup do
    uniq = System.unique_integer([:positive])
    reply_agent = :"at5_reply_#{uniq}"
    crash_agent = :"at5_crash_#{uniq}"
    start_supervised!({ReplyAgent, name: reply_agent})
    start_supervised!({CrashAgent, name: crash_agent})

    %{
      reply_agent: reply_agent,
      crash_agent: crash_agent,
      auth: AshA2A.Protocol.Plug.Auth.init(schemes: @schemes, verify: &__MODULE__.verify/3)
    }
  end

  defp rpc(ctx, user, agent, method, params) do
    body =
      Jason.encode!(%{"jsonrpc" => "2.0", "id" => 7, "method" => method, "params" => params})

    conn =
      Plug.Test.conn(:post, "/", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> user)
      |> AshA2A.Protocol.Plug.Auth.call(ctx.auth)
      |> VendoredPlug.call(
        VendoredPlug.init(
          agent: agent,
          base_url: "http://x/a2a",
          authorize_task: &__MODULE__.authorizer/3
        )
      )

    conn.resp_body |> Jason.decode!()
  end

  # Real authorizer that trusts the verified identity off the metadata the
  # transport assembled — exactly what an operator callback does.
  def authorizer(_op, _task, context) do
    case context.metadata do
      %{"a2a.auth" => %{identity: %{sub: "alice"}}} -> :ok
      _ -> {:error, :denied}
    end
  end

  defp message do
    {:ok, encoded} = AshA2A.Protocol.JSON.encode(AshA2A.Protocol.Message.new_user("go"))
    encoded
  end

  # -- (1) verified auth cannot be clobbered via params.metadata -------------

  test "params.metadata cannot forge or strip the verified a2a.auth identity", ctx do
    # A task exists, so tasks/get reaches the real authorizer.
    assert %{"result" => %{"task" => %{"id" => task_id}}} =
             rpc(ctx, "alice", ctx.reply_agent, "message/send", %{"message" => message()})

    forged = %{
      "metadata" => %{"a2a.auth" => "attacker-chosen", "legit" => "still-accepted"}
    }

    # The verified bearer IS alice; her authorizer admits her. Before the fix
    # the forged params.metadata replaced the verified a2a.auth and even the
    # genuine owner was denied (auth downgrade); after the fix the verified
    # identity survives the merge and the task is returned.
    assert %{"result" => %{"id" => ^task_id}} =
             rpc(ctx, "alice", ctx.reply_agent, "tasks/get", Map.put(forged, "id", task_id))

    # A foreign session carrying the same forged metadata is still denied —
    # the dropped key cannot be used to impersonate either.
    assert %{"error" => %{"code" => -32_001}} =
             rpc(ctx, "mallory", ctx.reply_agent, "tasks/get", Map.put(forged, "id", task_id))
  end

  # -- (2) handler crashes are ref-only on the wire ---------------------------

  test "a crashing handler answers -32603 with an opaque ref, no exception text", ctx do
    body = rpc(ctx, "alice", ctx.crash_agent, "message/send", %{"message" => message()})
    raw = Jason.encode!(body)

    assert %{
             "error" => %{
               "code" => -32_603,
               "data" => %{"ref" => ref, "code" => "internal_error"}
             }
           } =
             body

    assert is_binary(ref) and ref != ""
    refute raw =~ "pg secret"
    refute raw =~ "10.0.0.9"
  end

  # -- (3) push sender URL-scheme and credential hygiene ----------------------

  describe "push sender hardening" do
    test "non-http(s) webhook URLs are refused typed" do
      config = %AshA2A.Protocol.PushNotificationConfig{url: "file:///etc/passwd"}

      assert {:error, {:unsupported_scheme, "file"}} =
               PushHTTP.deliver(config, %{"taskId" => "t1"})
    end

    # URL hardening is now ON by default, so these hygiene courts target
    # https:// explicitly — they isolate credential validation, not the
    # URL-scheme gate (which has its own courts below).
    test "credentials carrying control characters are refused before dialing" do
      config = %AshA2A.Protocol.PushNotificationConfig{
        url: "https://example.invalid/hook",
        authentication: %{scheme: "Bearer", credentials: "tok\r\nX-Injected: 1"}
      }

      assert {:error, {:invalid_credentials, :control_characters}} =
               PushHTTP.deliver(config, %{"taskId" => "t1"})
    end

    test "bearer token carrying CRLF is refused before dialing" do
      config = %AshA2A.Protocol.PushNotificationConfig{
        url: "https://example.invalid/hook",
        token: "tok\nX-Injected: 1"
      }

      assert {:error, {:invalid_credentials, :control_characters}} =
               PushHTTP.deliver(config, %{"taskId" => "t1"})
    end

    # -- SSRF hardening is the default; opting out is loud ----------------------

    test "insecure http:// webhook URLs are refused by default" do
      config = %AshA2A.Protocol.PushNotificationConfig{url: "http://example.invalid/hook"}

      assert {:error, {:insecure_url, "http://example.invalid/hook"}} =
               PushHTTP.deliver(config, %{"taskId" => "t1"})
    end

    test "private/loopback webhook hosts are refused by default" do
      for url <- [
            "https://localhost:4000/hook",
            "https://127.0.0.1:4000/hook",
            "https://10.1.2.3:4000/hook",
            "https://192.168.1.5:4000/hook",
            "https://172.16.0.9:4000/hook"
          ] do
        config = %AshA2A.Protocol.PushNotificationConfig{url: url}

        assert {:error, {:private_host, _}} = PushHTTP.deliver(config, %{"taskId" => "t1"})
      end
    end

    test "explicit dev opt-out admits a localhost receiver (which then really dials)" do
      config = %AshA2A.Protocol.PushNotificationConfig{url: "http://127.0.0.1:1/hook"}

      opts = [require_https: false, block_private_ips: false, attempts: 1, timeout: 250]

      # The opt-out means the URL gate passes; the dial to the closed port
      # fails with a connection error — proving validation admitted it.
      assert {:error, reason} = PushHTTP.deliver(config, %{"taskId" => "t1"}, opts)
      refute match?({:insecure_url, _}, reason)
      refute match?({:private_host, _}, reason)
    end
  end
end


# ==============================================================================
# SECTION 2 of 15: test/ash_a2a/a2a_transport/extended_card_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.A2ATransport.ExtendedCardTest do
  @moduledoc """
  `agent/getAuthenticatedExtendedCard` through the real
  `AshA2A.A2ATransport.Plug` fronting a real `AshA2A.Agent` GenServer. The
  identity is placed on the conn with `AshA2A.Protocol.Plug.Auth.put_identity/2` -- the
  exact slot the real `AshA2A.Protocol.Plug.Auth` writes after verifying a credential.
  No mocks.
  """
  use ExUnit.Case, async: true

  alias AshA2A.A2ATransport.Plug, as: TransportPlug
  alias AshA2A.Test.PlugFixture.GreeterAgent

  setup do
    name = :"ext_card_agent_#{System.unique_integer([:positive])}"
    {:ok, pid} = GreeterAgent.start_link(name: name)
    on_exit(fn -> AshA2A.TestSupport.SafeStop.stop(pid) end)
    %{agent: name}
  end

  def add_admin_skill(identity, card) do
    skill = %{
      "id" => "admin",
      "name" => "Admin",
      "description" => "for #{identity.sub}",
      "tags" => []
    }

    {:ok, Map.update!(card, "skills", &(&1 ++ [skill]))}
  end

  defp rpc(opts, method, identity \\ nil) do
    body = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 7, "method" => method, "params" => %{}})

    conn =
      :post
      |> Plug.Test.conn("/", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")

    conn = if identity, do: AshA2A.Protocol.Plug.Auth.put_identity(conn, identity), else: conn
    conn = TransportPlug.call(conn, opts)
    {conn.status, Jason.decode!(conn.resp_body)}
  end

  defp opts(agent, extra),
    do: TransportPlug.init([agent: agent, base_url: "http://x/a2a"] ++ extra)

  defp rpc_conn(opts, method, identity) do
    body = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 7, "method" => method, "params" => %{}})

    conn =
      :post
      |> Plug.Test.conn("/", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")

    conn = if identity, do: AshA2A.Protocol.Plug.Auth.put_identity(conn, identity), else: conn
    TransportPlug.call(conn, opts)
  end

  # -- Cache semantics: the public card is shareable, the extended card is not -

  test "public card is served cacheable; authenticated extended card is private, no-store", %{
    agent: agent
  } do
    o = opts(agent, extended_card: &__MODULE__.add_admin_skill/2)

    public =
      :get
      |> Plug.Test.conn("/.well-known/agent-card.json")
      |> TransportPlug.call(o)

    assert {200, %{"result" => _card}} =
             rpc_conn(o, "agent/getAuthenticatedExtendedCard", %{sub: "u1"})
             |> then(&{&1.status, Jason.decode!(&1.resp_body)})

    assert get_cache_control(public) == "public, max-age=300"

    extended =
      rpc_conn(o, "agent/getAuthenticatedExtendedCard", %{sub: "u1"})
      |> get_cache_control()

    assert extended == "private, no-store"
  end

  defp get_cache_control(conn) do
    conn |> Plug.Conn.get_resp_header("cache-control") |> List.first()
  end

  test "no provider configured is -32007 (not configured), not -32004", %{agent: agent} do
    assert {200, %{"error" => %{"code" => -32_007}}} =
             rpc(opts(agent, []), "agent/getAuthenticatedExtendedCard", %{sub: "u1"})
  end

  test "unauthenticated caller is HTTP 401", %{agent: agent} do
    o = opts(agent, extended_card: &__MODULE__.add_admin_skill/2)

    assert {401, %{"error" => %{"code" => -32_600}}} =
             rpc(o, "agent/getAuthenticatedExtendedCard")
  end

  test "authenticated caller receives the provider's extended card", %{agent: agent} do
    o = opts(agent, extended_card: {__MODULE__, :add_admin_skill, []})

    assert {200, %{"result" => card}} = rpc(o, "GetExtendedAgentCard", %{sub: "u1"})
    ids = Enum.map(card["skills"], & &1["id"])
    assert "admin" in ids
    assert List.last(card["skills"])["description"] == "for u1"
    # v1.0 wire shape: the serving URL and protocol version ride inside
    # `supportedInterfaces` (protocolVersion 1.0, the Version single source of
    # truth); the card carries no top-level `url` or `protocolVersion`.
    assert [%{"protocolVersion" => "1.1", "url" => url} | _] = card["supportedInterfaces"]
    assert is_binary(url)
    refute Map.has_key?(card, "url")
    refute Map.has_key?(card, "protocolVersion")
  end

  test "a provider error or crash never falls back to the public card", %{agent: agent} do
    failing = opts(agent, extended_card: fn _, _ -> {:error, :denied} end)
    crashing = opts(agent, extended_card: fn _, _ -> raise "boom" end)

    assert {200, %{"error" => %{"code" => -32_007}}} =
             rpc(failing, "agent/getAuthenticatedExtendedCard", %{sub: "u1"})

    assert {200, %{"error" => %{"code" => -32_007}}} =
             rpc(crashing, "agent/getAuthenticatedExtendedCard", %{sub: "u1"})
  end

  test "the public card advertises extendedAgentCard only with a provider", %{agent: agent} do
    card = fn o ->
      :get
      |> Plug.Test.conn("/.well-known/agent-card.json")
      |> TransportPlug.call(o)
      |> Map.fetch!(:resp_body)
      |> Jason.decode!()
    end

    assert card.(opts(agent, extended_card: &__MODULE__.add_admin_skill/2))["capabilities"][
             "extendedAgentCard"
           ] ==
             true

    refute card.(opts(agent, []))["capabilities"]["extendedAgentCard"]
  end

  test "an invalid provider is rejected at init", %{agent: agent} do
    assert_raise ArgumentError, fn -> opts(agent, extended_card: :nope) end
  end
end


# ==============================================================================
# SECTION 3 of 15: test/ash_a2a/a2a_transport/ownership_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.A2ATransport.OwnershipTest.ReplyAgent do
  @moduledoc false
  # Real AshA2A.Protocol.Agent GenServer that completes every message synchronously.
  use AshA2A.Protocol.Agent, name: "owner-reply", description: "replies ok"

  @impl AshA2A.Protocol.Agent
  def handle_message(_message, _context), do: {:reply, [AshA2A.Protocol.Part.Text.new("ok")]}
end

defmodule AshA2A.A2ATransport.OwnershipTest.Receiver do
  @moduledoc false
  # Real webhook receiver forwarding each request body to the test process.
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, %{test: test}) do
    {:ok, body, conn} = read_body(conn)
    send(test, {:webhook, body})
    send_resp(conn, 200, "")
  end
end

defmodule AshA2A.A2ATransport.OwnershipTest do
  @moduledoc """
  Owner scope and credential hygiene of `AshA2A.A2ATransport.Plug`
  (adversarial court for CONF-02/CONF-04, overlapping SEC-01).

  Callers authenticate through the real `AshA2A.Protocol.Plug.Auth` (bearer scheme, a
  real `verify/3` callback) in front of the real transport plug; tasks live
  in a real `AshA2A.Protocol.Agent` GenServer; webhook deliveries hit a real Bandit
  receiver on loopback. The verified identity deliberately carries a raw
  credential (`token`) so any echo of `"a2a.auth"` is observable on the
  wire. No mocks.
  """
  use ExUnit.Case, async: true

  alias AshA2A.A2ATransport.{PushDelivery, TaskEvents, WebhookPolicy}
  alias AshA2A.A2ATransport.OwnershipTest.{Receiver, ReplyAgent}
  alias AshA2A.A2ATransport.Plug, as: TransportPlug
  alias AshA2A.Test.EphemeralHttp

  @schemes %{"bearer" => %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "bearer"}}

  # Real verify callback: the bearer token names the user; the identity
  # carries the raw credential, as real JWT/OIDC identities often do.
  def verify("bearer", token, _conn),
    do: {:ok, %{sub: token, token: "raw-credential-of-" <> token}}

  setup do
    uniq = System.unique_integer([:positive])
    agent = :"owner_reply_#{uniq}"
    transport = :"a2a_transport_owner_#{uniq}"
    start_supervised!({ReplyAgent, name: agent})

    start_supervised!(
      {AshA2A.A2ATransport,
       name: transport, push: [allow_http: true, allow_cidrs: ["127.0.0.1/32"], max_attempts: 1]}
    )

    hook = EphemeralHttp.start!({Receiver, %{test: self()}})

    %{
      transport: transport,
      hook: hook.base_url <> "/hook",
      auth: AshA2A.Protocol.Plug.Auth.init(schemes: @schemes, verify: &__MODULE__.verify/3),
      plug:
        TransportPlug.init(
          agent: agent,
          base_url: "http://x/a2a",
          transport: transport,
          push_notifications: true,
          heartbeat_ms: 50,
          max_idle_ms: 200
        )
    }
  end

  defp call(ctx, user, method, params) do
    body =
      Jason.encode!(%{"jsonrpc" => "2.0", "id" => 7, "method" => method, "params" => params})

    conn =
      Plug.Test.conn(:post, "/", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> user)
      |> AshA2A.Protocol.Plug.Auth.call(ctx.auth)

    refute conn.halted
    TransportPlug.call(conn, ctx.plug)
  end

  defp rpc(ctx, user, method, params),
    do: call(ctx, user, method, params).resp_body |> Jason.decode!()

  defp message(extra \\ %{}) do
    {:ok, encoded} = AshA2A.Protocol.JSON.encode(AshA2A.Protocol.Message.new_user("go"))
    Map.merge(encoded, extra)
  end

  defp send_as(ctx, user, params \\ %{}) do
    %{"result" => result} = rpc(ctx, user, "message/send", Map.put(params, "message", message()))
    get_in(result, ["task"]) || result
  end

  describe "owner scope" do
    test "another principal's task is -32001 on every task-naming method", ctx do
      %{"id" => task_id} = send_as(ctx, "alice")

      for {method, params} <- [
            {"tasks/get", %{"id" => task_id}},
            {"tasks/cancel", %{"id" => task_id}},
            {"tasks/resubscribe", %{"id" => task_id}},
            {"tasks/pushNotificationConfig/set",
             %{"taskId" => task_id, "pushNotificationConfig" => %{"url" => ctx.hook}}},
            {"tasks/pushNotificationConfig/list", %{"id" => task_id}},
            {"tasks/pushNotificationConfig/get", %{"id" => task_id}},
            {"message/send", %{"message" => message(%{"taskId" => task_id})}}
          ] do
        assert %{
                 "error" => %{
                   "code" => -32_001,
                   "data" => [%{"domain" => "a2a-protocol.org", "reason" => "TASK_NOT_FOUND"}]
                 }
               } = rpc(ctx, "bob", method, params),
               "#{method} answered bob for alice's task"
      end

      # The owner still has access.
      assert %{"result" => %{"id" => ^task_id}} =
               rpc(ctx, "alice", "tasks/get", %{"id" => task_id})

      assert %{"result" => %{"taskId" => ^task_id}} =
               rpc(ctx, "alice", "tasks/pushNotificationConfig/set", %{
                 "taskId" => task_id,
                 "pushNotificationConfig" => %{"url" => ctx.hook}
               })

      # The owner still has resubscribe authority — but a terminal task with
      # no retained event log is refused -32004 (spec §3.1.6, STREAM-SUB-003
      # MUST), so the owner's resubscribe is answered with the refusal, not
      # an SSE stream.
      conn = call(ctx, "alice", "tasks/resubscribe", %{"id" => task_id})
      assert conn.resp_body =~ "UNSUPPORTED_OPERATION"
      refute conn.resp_body =~ "TASK_NOT_FOUND"
    end

    test "params.metadata cannot forge a2a.auth to act as another principal", ctx do
      forged = %{"metadata" => %{"a2a.auth" => %{"identity" => %{"sub" => "alice"}}}}
      %{"id" => task_id} = send_as(ctx, "bob", forged)

      assert %{"result" => %{"id" => ^task_id}} = rpc(ctx, "bob", "tasks/get", %{"id" => task_id})

      assert %{"error" => %{"code" => -32_001}} =
               rpc(ctx, "alice", "tasks/get", %{"id" => task_id})
    end
  end

  describe "no credential echo" do
    test "responses, SSE frames, the event log and webhook bodies never carry a2a.auth", ctx do
      secret = "raw-credential-of-alice"

      send_resp =
        call(ctx, "alice", "message/send", %{
          "message" => message(),
          "configuration" => %{"pushNotificationConfig" => %{"url" => ctx.hook}}
        })

      refute send_resp.resp_body =~ secret
      refute send_resp.resp_body =~ "a2a.auth"
      %{"result" => result} = Jason.decode!(send_resp.resp_body)
      task_id = (result["task"] || result)["id"]

      assert_receive {:webhook, hook_body}, 15_000
      assert hook_body =~ task_id
      refute hook_body =~ secret
      refute hook_body =~ "a2a.auth"

      get = call(ctx, "alice", "tasks/get", %{"id" => task_id})
      assert get.resp_body =~ task_id
      refute get.resp_body =~ secret

      resub = call(ctx, "alice", "tasks/resubscribe", %{"id" => task_id})
      # Terminal empty-log task: refused -32004 — and the refusal carries no
      # credential echo either.
      refute resub.resp_body =~ task_id
      refute resub.resp_body =~ secret

      refute inspect(TaskEvents.backlog(ctx.transport, task_id)) =~ secret
    end
  end

  describe "delivery isolation" do
    test "webhook deliveries have their own capacity; exhausting it never blocks pumps" do
      transport = :"a2a_transport_iso_#{System.unique_integer([:positive])}"
      start_supervised!({AshA2A.A2ATransport, name: transport, max_deliveries: 0})

      config = %{
        id: "c1",
        task_id: "t1",
        url: "https://example.com/hook",
        token: nil,
        authentication: nil
      }

      assert {:error, :max_children} = PushDelivery.start(transport, config, %{}, 1, [])

      assert [%{attempt: 0, outcome: {:dropped, :max_deliveries}}] =
               TaskEvents.attempts(transport, "t1")

      # The pump supervisor is untouched by delivery exhaustion.
      assert {:ok, _} =
               Task.Supervisor.start_child(AshA2A.A2ATransport.task_sup_name(transport), fn ->
                 :ok
               end)
    end
  end

  describe "IPv6 prefixes that embed an IPv4 target" do
    test "IPv4-compatible, NAT64 local-use, Teredo and 6to4 are refused" do
      for ip <- [
            "[::7f00:1]",
            "[::a9fe:a9fe]",
            "[64:ff9b:1::a00:1]",
            "[2001:0:4136:e378:8000:63bf:3fff:fdd2]",
            "[2002:a00:1::1]"
          ] do
        assert {:error, :refused_webhook_private_address, _} =
                 WebhookPolicy.admit("https://#{ip}/hook"),
               "#{ip} was admitted"
      end

      # A global unicast IPv6 address is still admitted.
      assert {:ok, _} = WebhookPolicy.admit("https://[2606:4700:4700::1111]/hook")
    end
  end
end


# ==============================================================================
# SECTION 4 of 15: test/ash_a2a/a2a_transport/push_notification_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.A2ATransport.PushNotificationTest.Receiver do
  @moduledoc false
  # Real webhook receiver: forwards every request (method, headers, body) to
  # the pid in opts and answers with the configured status.
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, %{test: test} = opts) do
    {:ok, body, conn} = read_body(conn)
    send(test, {:webhook, conn.method, conn.req_headers, body})
    status = if is_function(opts[:status], 0), do: opts.status.(), else: 200
    send_resp(conn, status, "")
  end
end

defmodule AshA2A.A2ATransport.PushNotificationTest.ReplyAgent do
  @moduledoc false
  # Real AshA2A.Protocol.Agent GenServer that completes every message synchronously.
  use AshA2A.Protocol.Agent, name: "push-reply", description: "replies ok"

  @impl AshA2A.Protocol.Agent
  def handle_message(_message, _context), do: {:reply, [AshA2A.Protocol.Part.Text.new("ok")]}
end

defmodule AshA2A.A2ATransport.PushNotificationTest do
  @moduledoc """
  `tasks/pushNotificationConfig/*` and webhook delivery over the real
  `AshA2A.A2ATransport.Plug`, a real `AshA2A.A2ATransport` tree, a real
  `AshA2A.Agent` GenServer, and a real Bandit webhook receiver on loopback
  (admitted only through an explicit `allow_cidrs: ["127.0.0.1/32"]` +
  `allow_http: true` policy). No mocks.
  """
  use ExUnit.Case, async: true

  alias AshA2A.A2ATransport.{PushDelivery, TaskEvents}
  alias AshA2A.A2ATransport.Plug, as: TransportPlug
  alias AshA2A.A2ATransport.PushNotificationTest.Receiver
  alias AshA2A.Test.EphemeralHttp
  alias AshA2A.A2ATransport.PushNotificationTest.ReplyAgent

  @secret "test-signing-secret"

  setup do
    uniq = System.unique_integer([:positive])
    agent = :"push_reply_#{uniq}"
    transport = :"a2a_transport_push_#{uniq}"
    start_supervised!({ReplyAgent, name: agent})

    start_supervised!(
      {AshA2A.A2ATransport,
       name: transport,
       push: [
         allow_http: true,
         allow_cidrs: ["127.0.0.1/32"],
         signing_secret: @secret,
         max_attempts: 3,
         base_backoff_ms: 10
       ]}
    )

    hook = EphemeralHttp.start!({Receiver, %{test: self()}})

    %{
      agent: agent,
      transport: transport,
      hook: hook.base_url <> "/hook",
      on:
        TransportPlug.init(
          agent: agent,
          base_url: "http://x/a2a",
          transport: transport,
          push_notifications: true
        ),
      off: TransportPlug.init(agent: agent, base_url: "http://x/a2a", transport: transport)
    }
  end

  defp rpc(opts, method, params) do
    body = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params})

    :post
    |> Plug.Test.conn("/", body)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> TransportPlug.call(opts)
    |> Map.fetch!(:resp_body)
    |> Jason.decode!()
  end

  defp message do
    {:ok, encoded} = AshA2A.Protocol.JSON.encode(AshA2A.Protocol.Message.new_user("hello"))
    encoded
  end

  defp new_task(opts) do
    %{"result" => %{"task" => %{"id" => id}}} =
      rpc(opts, "message/send", %{"message" => message()})

    id
  end

  test "push is disabled by default: every push method is -32003", %{off: off} do
    for method <- ~w(set get list delete) do
      # Valid params (envelope validation requires pushNotificationConfig.url):
      # proves the -32003 is the disabled-by-default refusal, not a params error.
      assert %{
               "error" => %{
                 "code" => -32_003,
                 "data" => [
                   %{
                     "domain" => "a2a-protocol.org",
                     "reason" => "PUSH_NOTIFICATION_NOT_SUPPORTED"
                   }
                 ]
               }
             } =
               rpc(off, "tasks/pushNotificationConfig/" <> method, %{
                 "taskId" => "t",
                 "id" => "t",
                 "pushNotificationConfig" => %{"url" => "https://example.com/hook"}
               })
    end
  end

  test "disabled push refuses an inline push config instead of ignoring it", %{
    off: off,
    hook: hook
  } do
    params = %{
      "message" => message(),
      "configuration" => %{"pushNotificationConfig" => %{"url" => hook}}
    }

    assert %{
             "error" => %{
               "code" => -32_003,
               "data" => [
                 %{"domain" => "a2a-protocol.org", "reason" => "PUSH_NOTIFICATION_NOT_SUPPORTED"}
               ]
             }
           } = rpc(off, "message/send", params)
  end

  test "set -> get -> list -> delete round-trip", %{on: on, hook: hook} do
    task_id = new_task(on)

    set =
      rpc(on, "tasks/pushNotificationConfig/set", %{
        "taskId" => task_id,
        "pushNotificationConfig" => %{
          "id" => "cfg-1",
          "url" => hook,
          "token" => "tok",
          "authentication" => %{"schemes" => ["Bearer"], "credentials" => "s3cret"}
        }
      })

    expected = %{
      "taskId" => task_id,
      "pushNotificationConfig" => %{
        "id" => "cfg-1",
        "url" => hook,
        "token" => "tok",
        "authentication" => %{"schemes" => ["Bearer"]}
      }
    }

    assert set["result"] == expected

    assert rpc(on, "tasks/pushNotificationConfig/get", %{
             "id" => task_id,
             "pushNotificationConfigId" => "cfg-1"
           })[
             "result"
           ] == expected

    assert rpc(on, "ListTaskPushNotificationConfigs", %{"id" => task_id})["result"] == [expected]

    assert %{"result" => nil} =
             rpc(on, "tasks/pushNotificationConfig/delete", %{
               "id" => task_id,
               "pushNotificationConfigId" => "cfg-1"
             })

    assert rpc(on, "tasks/pushNotificationConfig/list", %{"id" => task_id})["result"] == []

    # Idempotent delete per TCK PUSH-DEL-002: re-deleting an already-deleted
    # config answers success, not an error.
    assert %{"result" => nil} =
             rpc(on, "tasks/pushNotificationConfig/delete", %{
               "id" => task_id,
               "pushNotificationConfigId" => "cfg-1"
             })
  end

  test "set on an unknown task is -32001", %{on: on, hook: hook} do
    assert %{"error" => %{"code" => -32_001}} =
             rpc(on, "tasks/pushNotificationConfig/set", %{
               "taskId" => "no-such-task",
               "pushNotificationConfig" => %{"url" => hook}
             })
  end

  test "SSRF: private, loopback, metadata and non-https URLs are refused at set", %{on: on} do
    task_id = new_task(on)

    for {url, code} <- [
          {"http://10.0.0.5/hook", "refused_webhook_private_address"},
          {"http://169.254.169.254/latest/meta-data", "refused_webhook_private_address"},
          {"http://127.0.0.2:9/hook", "refused_webhook_private_address"},
          {"http://[::1]/hook", "refused_webhook_private_address"},
          {"http://localhost:1/hook", "refused_webhook_private_address"},
          {"ftp://example.com/hook", "refused_webhook_scheme"},
          {"http://user:pw@127.0.0.1/hook", "refused_webhook_malformed"}
        ] do
      resp =
        rpc(on, "tasks/pushNotificationConfig/set", %{
          "taskId" => task_id,
          "pushNotificationConfig" => %{"url" => url}
        })

      # v1.0 ErrorInfo envelope: the typed refusal code rides in the ErrorInfo
      # metadata detail.
      assert %{"error" => %{"code" => -32_602, "data" => [info]}} = resp, url

      assert %{
               "@type" => "type.googleapis.com/google.rpc.ErrorInfo",
               "domain" => "a2a-protocol.org",
               "reason" => "INVALID_PARAMS",
               "metadata" => %{"detail" => detail}
             } = info

      assert detail =~ code, url
    end
  end

  test "inline config on message/send delivers a signed, token-bearing Task to the webhook",
       %{on: on, hook: hook, transport: transport} do
    params = %{
      "message" => message(),
      "configuration" => %{"pushNotificationConfig" => %{"url" => hook, "token" => "tok-1"}}
    }

    %{"result" => %{"task" => %{"id" => task_id}}} = rpc(on, "message/send", params)

    assert_receive {:webhook, "POST", headers, body}, 5_000
    headers = Map.new(headers)
    assert headers["x-a2a-notification-token"] == "tok-1"
    assert headers["content-type"] == "application/json"

    assert :ok =
             PushDelivery.verify_signature(
               @secret,
               headers["x-a2a-timestamp"],
               headers["x-a2a-signature"],
               body
             )

    assert {:error, :bad_signature} =
             PushDelivery.verify_signature(
               @secret,
               headers["x-a2a-timestamp"],
               headers["x-a2a-signature"],
               body <> " "
             )

    # v1.0 StreamResponse payload: the webhook carries the same wrapped shape
    # the streaming transport emits (here the terminal task snapshot), finality
    # via the terminal TASK_STATE_* — no "final" boolean anywhere.
    assert %{
             "task" => %{
               "id" => ^task_id,
               "status" => %{"state" => "TASK_STATE_COMPLETED"}
             }
           } = Jason.decode!(body)

    refute body =~ ~s("final")

    assert [%{attempt: 1, outcome: {:ok, 200}}] = wait_attempts(transport, task_id, 1)
  end

  test "a failing webhook is retried with backoff until it succeeds", %{
    on: on,
    transport: transport
  } do
    # A dedicated receiver that answers 503 to its first request only.
    counter = :counters.new(1, [])
    test_pid = self()

    flaky =
      EphemeralHttp.start!(
        {Receiver,
         %{
           test: test_pid,
           status: fn ->
             :counters.add(counter, 1, 1)
             if :counters.get(counter, 1) == 1, do: 503, else: 200
           end
         }}
      )

    params = %{
      "message" => message(),
      "configuration" => %{"pushNotificationConfig" => %{"url" => flaky.base_url <> "/hook"}}
    }

    %{"result" => %{"task" => %{"id" => task_id}}} = rpc(on, "message/send", params)
    assert_receive {:webhook, "POST", _, _}, 5_000
    assert_receive {:webhook, "POST", _, _}, 5_000

    assert [%{attempt: 1, outcome: {:http_error, 503}}, %{attempt: 2, outcome: {:ok, 200}}] =
             wait_attempts(transport, task_id, 2)
  end

  test "delivery re-admits the URL: a config whose target became unadmitted is refused, not retried",
       %{transport: transport} do
    # Store a config directly (bypassing set-time admission) to witness the
    # delivery-time gate on its own.
    config = %{
      id: "c",
      task_id: "t-direct",
      url: "http://10.1.2.3/hook",
      token: nil,
      authentication: nil
    }

    {:ok, _} =
      AshA2A.A2ATransport.PushConfigStore.put(
        AshA2A.A2ATransport.push_store_name(transport),
        config
      )

    TaskEvents.publish(transport, "t-direct", "status-update", %{"state" => "x"}, false)

    assert [%{attempt: 1, outcome: {:refused, :refused_webhook_private_address, _}}] =
             wait_attempts(transport, "t-direct", 1)
  end

  test "the public card advertises pushNotifications only when enabled", %{on: on, off: off} do
    card = fn opts ->
      :get
      |> Plug.Test.conn("/.well-known/agent-card.json")
      |> TransportPlug.call(opts)
      |> Map.fetch!(:resp_body)
      |> Jason.decode!()
    end

    assert card.(on)["capabilities"]["pushNotifications"] == true
    refute card.(off)["capabilities"]["pushNotifications"]
  end

  defp wait_attempts(transport, task_id, n, tries \\ 100) do
    attempts = TaskEvents.attempts(transport, task_id)

    cond do
      length(attempts) >= n ->
        attempts

      tries == 0 ->
        flunk("expected #{n} attempts, got #{inspect(attempts)}")

      true ->
        Process.sleep(20)
        wait_attempts(transport, task_id, n, tries - 1)
    end
  end
end


# ==============================================================================
# SECTION 5 of 15: test/ash_a2a/a2a_transport/resubscribe_test.exs
# ==============================================================================

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
    for {:artifact, %{"artifact" => %{"parts" => [%{"text" => t}]}}} <-
          Enum.map(results, &unwrap/1),
        do: t
  end

  # Finality rides on the terminal status state — StatusUpdate events carry no
  # "final" boolean on the wire.
  @terminal_states [
    "TASK_STATE_COMPLETED",
    "TASK_STATE_FAILED",
    "TASK_STATE_CANCELED",
    "TASK_STATE_REJECTED",
    "TASK_STATE_AUTH_REQUIRED"
  ]

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


# ==============================================================================
# SECTION 6 of 15: test/ash_a2a/a2a_transport/spec_mapping_doc_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.A2ATransport.SpecMappingDocTest.DocAgent do
  @moduledoc false
  # Real AshA2A.Protocol.Agent: replies, or streams when the text is "stream".
  use AshA2A.Protocol.Agent, name: "doc-agent", description: "spec mapping fixture"

  @impl AshA2A.Protocol.Agent
  def handle_message(message, _context) do
    case AshA2A.Protocol.Message.text(message) do
      "stream" -> {:stream, [AshA2A.Protocol.Part.Text.new("s1")]}
      _ -> {:reply, [AshA2A.Protocol.Part.Text.new("ok")]}
    end
  end
end

defmodule AshA2A.A2ATransport.SpecMappingDocTest do
  @moduledoc """
  Drift court for `docs/reference/a2a-spec-version-mapping.md`: every method
  row is driven through the real vendored `AshA2A.Protocol.Plug` and the real
  `AshA2A.A2ATransport.Plug` (real agent GenServer, real transport tree,
  real `Plug.Test` conns), and the observed outcome must equal the doc cell.
  The alias surface is read from the dependency's own source so a new
  upstream method fails here until it is documented and routed.
  """
  use ExUnit.Case, async: true

  alias AshA2A.A2ATransport.Plug, as: TransportPlug
  alias AshA2A.A2ATransport.SpecMappingDocTest.DocAgent

  @doc_path "docs/reference/a2a-spec-version-mapping.md"

  setup do
    uniq = System.unique_integer([:positive])
    agent = :"doc_agent_#{uniq}"
    transport = :"a2a_transport_doc_#{uniq}"
    start_supervised!({DocAgent, name: agent})
    start_supervised!({AshA2A.A2ATransport, name: transport})

    vendored = AshA2A.Protocol.Plug.init(agent: agent, base_url: "http://x/a2a")

    ours =
      TransportPlug.init(
        agent: agent,
        base_url: "http://x/a2a",
        transport: transport,
        push_notifications: true,
        extended_card: fn _identity, card -> {:ok, card} end,
        max_idle_ms: 200,
        heartbeat_ms: 100
      )

    %{vendored: {AshA2A.Protocol.Plug, vendored}, ours: {TransportPlug, ours}}
  end

  defp doc_rows do
    @doc_path
    |> File.read!()
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^\| (\w+) \| `([^`]+)` \| ([^|]+?) \| ([^|]+?) \|$/, line) do
        [_, alias_name, method, vendored, ours] -> [{alias_name, method, vendored, ours}]
        nil -> []
      end
    end)
  end

  defp dep_aliases do
    # Source of truth is now the ported in-repo JSON-RPC dispatcher
    # (lib/ash_a2a/protocol/jsonrpc.ex) — the hex `:a2a` package was removed.
    src = File.read!("lib/ash_a2a/protocol/jsonrpc.ex")
    [_, block] = Regex.run(~r/@method_aliases %\{(.*?)\n  \}/s, src)

    ~r/"(\w+)" => "([^"]+)"/
    |> Regex.scan(block)
    |> Map.new(fn [_, k, v] -> {k, v} end)
  end

  defp rpc({mod, opts}, method, params) do
    body = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params})

    conn =
      :post
      |> Plug.Test.conn("/", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> AshA2A.Protocol.Plug.Auth.put_identity(%{sub: "doc-test"})
      |> mod.call(opts)

    ct = conn |> Plug.Conn.get_resp_header("content-type") |> List.first("")

    cond do
      ct =~ "text/event-stream" -> "sse"
      true -> outcome(Jason.decode!(conn.resp_body))
    end
  end

  defp outcome(%{"error" => %{"code" => code}}), do: "error #{code}"
  defp outcome(%{"result" => _}), do: "result"

  defp msg(text) do
    {:ok, encoded} = AshA2A.Protocol.JSON.encode(AshA2A.Protocol.Message.new_user(text))
    encoded
  end

  defp params_for(method, task_id) do
    push = %{"id" => "cfg", "url" => "https://93.184.215.14/hook"}

    case method do
      "message/send" ->
        %{"message" => msg("hi")}

      "message/stream" ->
        %{"message" => msg("stream")}

      "tasks/list" ->
        %{}

      "tasks/pushNotificationConfig/set" ->
        %{"taskId" => task_id, "pushNotificationConfig" => push}

      "tasks/pushNotificationConfig/" <> _ ->
        %{"id" => task_id, "pushNotificationConfigId" => "cfg"}

      _ ->
        %{"id" => task_id}
    end
  end

  defp new_task({_, _} = plug) do
    {mod, opts} = plug

    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "message/send",
        "params" => %{"message" => msg("x")}
      })

    :post
    |> Plug.Test.conn("/", body)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> mod.call(opts)
    |> Map.fetch!(:resp_body)
    |> Jason.decode!()
    |> get_in(["result", "task", "id"])
  end

  test "the doc's alias table equals AshA2A.Protocol.JSONRPC's dispatch surface and the plug's routing table" do
    rows = doc_rows()
    documented = Map.new(rows, fn {a, m, _, _} -> {a, m} end)

    assert documented == dep_aliases()
    assert TransportPlug.method_aliases() == dep_aliases()
  end

  test "every documented outcome is the observed outcome on both plugs", ctx do
    for {label, column} <- [vendored: 2, ours: 3] do
      plug = Map.fetch!(ctx, label)
      task_id = new_task(plug)

      # Seed a config first so get/list/delete observe an existing config.
      if label == :ours,
        do:
          rpc(
            plug,
            "tasks/pushNotificationConfig/set",
            params_for("tasks/pushNotificationConfig/set", task_id)
          )

      for {alias_name, method, _, _} = row <- doc_rows() do
        expected = row |> elem(column) |> String.trim()
        observed = rpc(plug, method, params_for(method, task_id))

        assert observed == expected,
               "#{label} #{method}: doc says #{expected}, observed #{observed}"

        if method != "tasks/pushNotificationConfig/delete" do
          # The PascalCase alias behaves identically to the canonical name.
          assert rpc(plug, alias_name, params_for(method, task_id)) == observed,
                 "#{label} #{alias_name}"
        end
      end
    end
  end

  test "the Version line tracks mix.exs and profile constants match the code" do
    doc = File.read!(@doc_path)
    assert doc =~ "Version: v#{Mix.Project.config()[:version]}\n"
    assert doc =~ "`#{AshA2A.Semantic.Extension.profile_id()}`"
    assert doc =~ "`#{AshA2A.Semantic.Extension.profile_uri()}`"
    assert doc =~ "`#{AshA2A.SA2A.Conformance.profile()}`"
  end
end


# ==============================================================================
# SECTION 7 of 15: test/ash_a2a/a2a_transport/webhook_policy_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.A2ATransport.WebhookPolicyTest do
  @moduledoc """
  SSRF admission for push webhook URLs. IP-literal hosts and `localhost`
  exercise the real `:inet` resolver. One test injects a fixed resolver
  function: real DNS answers for a public name are nondeterministic and
  network-dependent, and the property under test (a name whose *any* answer
  is private is refused) needs a pinned multi-address answer.
  """
  use ExUnit.Case, async: true

  alias AshA2A.A2ATransport.WebhookPolicy

  test "public https IP literal is admitted with its address" do
    assert {:ok, %{addresses: [{93, 184, 215, 14}]}} =
             WebhookPolicy.admit("https://93.184.215.14/hook")
  end

  test "http is refused unless allow_http" do
    assert {:error, :refused_webhook_scheme, _} = WebhookPolicy.admit("http://93.184.215.14/hook")
    assert {:ok, _} = WebhookPolicy.admit("http://93.184.215.14/hook", allow_http: true)
  end

  for ip <-
        ~w(127.0.0.1 10.9.9.9 172.16.0.1 172.31.255.255 192.168.1.1 169.254.169.254 100.64.0.1 0.0.0.0 224.0.0.1 255.255.255.255) do
    test "IPv4 #{ip} is refused" do
      assert {:error, :refused_webhook_private_address, _} =
               WebhookPolicy.admit("https://#{unquote(ip)}/")
    end
  end

  for ip <- ~w(::1 :: fe80::1 fd00::1 ::ffff:127.0.0.1 ::ffff:10.0.0.1 ff02::1) do
    test "IPv6 #{ip} is refused" do
      assert {:error, :refused_webhook_private_address, _} =
               WebhookPolicy.admit("https://[#{unquote(ip)}]/")
    end
  end

  test "172.32.0.1 (outside 172.16/12) is public" do
    assert {:ok, _} = WebhookPolicy.admit("https://172.32.0.1/")
  end

  test "localhost resolves (real resolver) to loopback and is refused" do
    assert {:error, :refused_webhook_private_address, _} =
             WebhookPolicy.admit("https://localhost/")
  end

  test "allow_cidrs admits exactly the listed range" do
    assert {:ok, _} =
             WebhookPolicy.admit("http://127.0.0.1:4000/",
               allow_http: true,
               allow_cidrs: ["127.0.0.1/32"]
             )

    assert {:error, :refused_webhook_private_address, _} =
             WebhookPolicy.admit("http://127.0.0.2:4000/",
               allow_http: true,
               allow_cidrs: ["127.0.0.1/32"]
             )
  end

  test "a name with any private answer is refused (pinned resolver)" do
    resolver = fn
      ~c"mixed.example", :inet -> {:ok, [{93, 184, 215, 14}, {10, 0, 0, 1}]}
      _, _ -> {:error, :nxdomain}
    end

    assert {:error, :refused_webhook_private_address, detail} =
             WebhookPolicy.admit("https://mixed.example/", resolver: resolver)

    assert detail =~ "10.0.0.1"
  end

  test "unresolvable, userinfo, hostless and non-string URLs are refused" do
    resolver = fn _, _ -> {:error, :nxdomain} end

    assert {:error, :refused_webhook_unresolvable, _} =
             WebhookPolicy.admit("https://nope.invalid/", resolver: resolver)

    assert {:error, :refused_webhook_malformed, _} =
             WebhookPolicy.admit("https://u:p@93.184.215.14/")

    assert {:error, :refused_webhook_malformed, _} = WebhookPolicy.admit("https:///path")
    assert {:error, :refused_webhook_malformed, _} = WebhookPolicy.admit(nil)

    assert {:error, :refused_webhook_malformed, _} =
             WebhookPolicy.admit("https://1.1.1.1/", allow_cidrs: ["bogus"])
  end

  test "every returned refusal code is classified (S42)" do
    classified = WebhookPolicy.__sa2a_refusal_codes__()

    for code <-
          ~w(refused_webhook_malformed refused_webhook_scheme refused_webhook_unresolvable refused_webhook_private_address)a do
      assert Map.has_key?(classified, code)
    end
  end
end


# ==============================================================================
# SECTION 8 of 15: test/ash_a2a/egress/endpoint_policy_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Egress.EndpointPolicyTest do
  use ExUnit.Case, async: true
  alias AshA2A.Egress.EndpointPolicy

  test "admits a public literal over https and pins request to the IP with original host" do
    assert {:ok, admitted} = EndpointPolicy.admit("https://93.184.216.34:8443/base")
    opts = EndpointPolicy.request_options(admitted, "/ocel/events")
    assert opts[:url] == "https://93.184.216.34:8443/base/ocel/events"
    assert opts[:redirect] == false
    assert {"host", "93.184.216.34:8443"} in opts[:headers]
  end

  test "resolved hostnames are pinned to the admitted address, hostname kept for TLS" do
    resolver = fn
      _h, :inet -> {:ok, [{93, 184, 216, 34}]}
      _h, :inet6 -> {:error, :nxdomain}
    end

    assert {:ok, admitted} =
             EndpointPolicy.admit("https://collector.example/x", resolver: resolver)

    opts = EndpointPolicy.request_options(admitted, "/ocel/events")
    assert opts[:url] =~ "https://93.184.216.34/x/ocel/events"
    assert opts[:connect_options][:hostname] == "collector.example"
  end

  test "refuses when any resolved address is private (DNS rebinding mix)" do
    resolver = fn
      _h, :inet -> {:ok, [{93, 184, 216, 34}, {10, 0, 0, 5}]}
      _h, _ -> {:error, :nxdomain}
    end

    assert {:error, :refused_webhook_private_address, _} =
             EndpointPolicy.admit("https://mixed.example", resolver: resolver)
  end

  test "refuses non-string, userinfo, and http" do
    assert {:error, :refused_webhook_malformed, _} = EndpointPolicy.admit(nil)

    assert {:error, :refused_webhook_malformed, _} =
             EndpointPolicy.admit("https://u:p@93.184.216.34")

    assert {:error, :refused_webhook_scheme, _} = EndpointPolicy.admit("http://93.184.216.34")
  end
end

defmodule AshA2A.Egress.EndpointPolicyUserinfoTest do
  use ExUnit.Case, async: true
  alias AshA2A.Egress.EndpointPolicy

  test "userinfo is refused by default and, when allowed, moves to a Basic header off the URL" do
    assert {:error, :refused_webhook_malformed, _} =
             EndpointPolicy.admit("https://u:p@93.184.216.34")

    assert {:ok, a} = EndpointPolicy.admit("https://u:p@93.184.216.34", allow_userinfo: true)
    opts = EndpointPolicy.request_options(a, "/x")
    refute opts[:url] =~ "u:p"
    assert {"authorization", "Basic " <> Base.encode64("u:p")} in opts[:headers]
  end
end


# ==============================================================================
# SECTION 9 of 15: test/ash_a2a/protocol/list_tasks_owner_scope_test.exs
# ==============================================================================

defmodule AshA2A.Protocol.ListTasksOwnerScopeTest do
  use ExUnit.Case, async: true

  alias AshA2A.Protocol.Agent.State
  alias AshA2A.Protocol.Task
  alias AshA2A.Transport.Runtime

  defp task(id, owner) do
    %Task{
      id: id,
      context_id: "ctx-#{id}",
      status: %{state: :submitted},
      metadata: %{"ash_a2a.owner" => owner}
    }
  end

  defp state do
    tasks = %{"t-alice" => task("t-alice", "alice"), "t-bob" => task("t-bob", "bob")}
    %State{tasks: tasks}
  end

  defp ids({:ok, result}) do
    result |> Map.fetch!(:tasks) |> Enum.map(& &1.id) |> Enum.sort()
  end

  test "a principal lists only its own tasks" do
    assert ids(Runtime.list_tasks_for(state(), "alice", %{})) == ["t-alice"]
    assert ids(Runtime.list_tasks_for(state(), "bob", %{})) == ["t-bob"]
  end

  test "an unknown principal sees nothing" do
    assert ids(Runtime.list_tasks_for(state(), "mallory", %{})) == []
  end

  test "anonymous never lists" do
    assert ids(Runtime.list_tasks_for(state(), :anonymous, %{})) == []
  end
end


# ==============================================================================
# SECTION 10 of 15: test/ash_a2a/protocol/orphan_sweep_unsupported_test.exs
# ==============================================================================

defmodule AshA2A.Protocol.OrphanSweepUnsupportedTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  defmodule NoListStore do
    def get(_ref, _id), do: {:error, :not_found}
    def put(_ref, _task), do: :ok
  end

  test "a store without list_all/2 is a loud typed error with telemetry" do
    id = {:orphan_sweep_unsupported, make_ref()}

    :telemetry.attach(
      id,
      [:ash_a2a, :task, :orphan_sweep_unsupported],
      fn _e, m, meta, pid -> send(pid, {:unsupported, m, meta}) end,
      self()
    )

    on_exit(fn -> :telemetry.detach(id) end)

    log =
      capture_log([level: :error], fn ->
        assert {:error, {:unsupported, :list_all}} =
                 AshA2A.Protocol.Task.OrphanSweep.sweep({NoListStore, nil})
      end)

    assert log =~ "does not export list_all/2"
    assert_receive {:unsupported, %{count: 1}, %{store: NoListStore}}
  end
end


# ==============================================================================
# SECTION 11 of 15: test/ash_a2a/protocol/plug/security_validators_test.exs
# ==============================================================================

defmodule AshA2A.Protocol.Plug.SecurityValidatorsTest do
  @moduledoc """
  Courts for the full A2A v1 security-scheme validator surface
  (`AshA2A.Protocol.Plug.SecurityValidators`).

  Per-scheme: a valid credential passes; expired / bad-issuer / bad-audience /
  scope-missing / bad-signature credentials are refused with the exact typed
  error code. API-key location enforcement is exercised end-to-end through a
  real `AshA2A.Protocol.Plug.Auth` pipeline (real `Plug.Test` conn). The OIDC
  and introspection courts run against REAL local HTTP servers (Bandit), not
  stubs.
  """

  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias AshA2A.Protocol.Plug.Auth
  alias AshA2A.Protocol.Plug.SecurityValidators
  alias AshA2A.Protocol.SecurityScheme

  @now System.system_time(:second)

  # -- JWT helpers --------------------------------------------------------------

  defp b64(bin), do: Base.url_encode64(bin, padding: false)

  defp hs256_token(claims, secret, header \\ %{"alg" => "HS256", "typ" => "JWT"}) do
    signing_input =
      Enum.map_join([header, claims], ".", fn part ->
        part |> Jason.encode!() |> b64()
      end)

    sig = :crypto.mac(:hmac, :sha256, secret, signing_input)
    signing_input <> "." <> b64(sig)
  end

  defp claims(overrides \\ %{}) do
    Map.merge(
      %{
        "sub" => "user-1",
        "iss" => "https://auth.example.com",
        "aud" => "a2a-api",
        "exp" => @now + 600,
        "scope" => "a2a:read a2a:write"
      },
      overrides
    )
  end

  defp rsa_keypair do
    :public_key.generate_key({:rsa, 2048, 65_537})
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp jwk_from_key(key, kid) do
    {:RSAPrivateKey, _, n, e, _, _, _, _, _, _, _} = key

    %{
      "kty" => "RSA",
      "kid" => kid,
      "n" => b64(:binary.encode_unsigned(n)),
      "e" => b64(:binary.encode_unsigned(e)),
      "alg" => "RS256",
      "use" => "sig"
    }
  end

  defp rs256_token(claims, key, kid, header_overrides \\ %{}) do
    header = Map.merge(%{"alg" => "RS256", "typ" => "JWT", "kid" => kid}, header_overrides)

    signing_input =
      Enum.map_join([header, claims], ".", fn part ->
        part |> Jason.encode!() |> b64()
      end)

    sig = :public_key.sign(:crypto.hash(:sha256, signing_input), :sha256, key)
    signing_input <> "." <> b64(sig)
  end

  # -- HS256 bearer -------------------------------------------------------------

  describe "validate_bearer/2 (HTTPAuth bearer, HS256)" do
    test "valid token passes with claims intact" do
      token = hs256_token(claims(), "s3cret")

      assert {:ok, result} =
               SecurityValidators.validate_bearer(token,
                 secret: "s3cret",
                 issuer: "https://auth.example.com",
                 audience: "a2a-api"
               )

      assert result["sub"] == "user-1"
      assert result[:scheme_kind] == :bearer
    end

    test "expired token refused" do
      token = hs256_token(claims(%{"exp" => @now - 3600}), "s3cret")

      assert {:error, %{code: :token_expired}} =
               SecurityValidators.validate_bearer(token, secret: "s3cret")
    end

    test "bad issuer refused" do
      token = hs256_token(claims(%{"iss" => "https://evil.example.com"}), "s3cret")

      assert {:error, %{code: :invalid_issuer, detail: %{expected: "https://auth.example.com"}}} =
               SecurityValidators.validate_bearer(token,
                 secret: "s3cret",
                 issuer: "https://auth.example.com"
               )
    end

    test "bad audience refused" do
      token = hs256_token(claims(%{"aud" => "other-api"}), "s3cret")

      assert {:error, %{code: :invalid_audience}} =
               SecurityValidators.validate_bearer(token, secret: "s3cret", audience: "a2a-api")
    end

    test "audience list containing expected passes" do
      token = hs256_token(claims(%{"aud" => ["other-api", "a2a-api"]}), "s3cret")

      assert {:ok, _} =
               SecurityValidators.validate_bearer(token, secret: "s3cret", audience: "a2a-api")
    end

    test "missing scope refused" do
      token = hs256_token(claims(%{"scope" => "a2a:read"}), "s3cret")

      assert {:error, %{code: :insufficient_scope, detail: ["a2a:write"]}} =
               SecurityValidators.validate_bearer(token,
                 secret: "s3cret",
                 required_scopes: ["a2a:read", "a2a:write"]
               )
    end

    test "scp claim honored as scope source" do
      token = hs256_token(claims(%{"scope" => nil, "scp" => "a2a:read a2a:write"}), "s3cret")

      assert {:ok, _} =
               SecurityValidators.validate_bearer(token,
                 secret: "s3cret",
                 required_scopes: ["a2a:write"]
               )
    end

    test "bad signature refused" do
      token = hs256_token(claims(), "wrong-secret")

      assert {:error, %{code: :bad_signature}} =
               SecurityValidators.validate_bearer(token, secret: "s3cret")
    end

    test "malformed token refused" do
      assert {:error, %{code: :malformed_token}} =
               SecurityValidators.validate_bearer("not-a-jwt", secret: "s3cret")

      assert {:error, %{code: :invalid_token}} =
               SecurityValidators.validate_bearer(42, secret: "s3cret")
    end

    test "unsupported algorithm refused (alg none)" do
      header = Jason.encode!(%{"alg" => "none"})
      payload = Jason.encode!(claims())

      signing_input = b64(header) <> "." <> b64(payload)

      assert {:error, %{code: :unsupported_algorithm}} =
               SecurityValidators.validate_bearer(signing_input <> ".", secret: "s3cret")
    end

    test "required claims enforced" do
      token = hs256_token(%{"iss" => "https://auth.example.com"}, "s3cret")

      assert {:error, %{code: :missing_claim, detail: ["sub"]}} =
               SecurityValidators.validate_bearer(token,
                 secret: "s3cret",
                 required_claims: ["sub"]
               )
    end
  end

  # -- API key ---------------------------------------------------------------------

  describe "validate_api_key/2" do
    test "matching key passes" do
      assert {:ok, %{scheme_kind: :key}} =
               SecurityValidators.validate_api_key("k-123", keys: ["k-123", "k-456"])
    end

    test "wrong key refused with typed error" do
      assert {:error, %{code: :invalid_api_key}} =
               SecurityValidators.validate_api_key("nope", keys: ["k-123"])
    end

    test "empty key set refuses everything (fail-closed)" do
      assert {:error, %{code: :invalid_api_key}} =
               SecurityValidators.validate_api_key("anything", keys: [])
    end
  end

  # -- OAuth2 ------------------------------------------------------------------------

  describe "validate_oauth2/2 (JWT path)" do
    test "delegates to bearer verification with scopes" do
      token = hs256_token(claims(%{"scope" => "a2a:read"}), "s3cret")

      assert {:error, %{code: :insufficient_scope}} =
               SecurityValidators.validate_oauth2(token,
                 secret: "s3cret",
                 required_scopes: ["a2a:write"]
               )

      token2 = hs256_token(claims(), "s3cret")

      assert {:ok, %{scheme_kind: :oauth2}} =
               SecurityValidators.validate_oauth2(token2, secret: "s3cret")
    end
  end

  describe "validate_oauth2/2 (RFC 7662 introspection)" do
    setup do
      port = free_port()

      start_supervised({Bandit, plug: {__MODULE__.IntrospectionServer, []}, port: port})

      {:ok, introspection_url: "http://127.0.0.1:#{port}/introspect"}
    end

    test "active token with required scopes passes", %{introspection_url: url} do
      assert {:ok, claims} =
               SecurityValidators.validate_oauth2("tok-active",
                 introspection_url: url,
                 required_scopes: ["a2a:read"]
               )

      assert claims["sub"] == "user-1"
      assert claims[:scheme_kind] == :oauth2
    end

    test "inactive token refused" do
      port = free_port()

      start_supervised(
        {Bandit, plug: {__MODULE__.IntrospectionServer, inactive: true}, port: port}
      )

      assert {:error, %{code: :token_inactive}} =
               SecurityValidators.validate_oauth2("tok-dead",
                 introspection_url: "http://127.0.0.1:#{port}/introspect"
               )
    end

    test "expired introspected token refused", %{introspection_url: url} do
      assert {:error, %{code: :token_expired}} =
               SecurityValidators.validate_oauth2("tok-expired", introspection_url: url)
    end

    test "missing scope refused", %{introspection_url: url} do
      assert {:error, %{code: :insufficient_scope, detail: ["a2a:admin"]}} =
               SecurityValidators.validate_oauth2("tok-active",
                 introspection_url: url,
                 required_scopes: ["a2a:admin"]
               )
    end
  end

  # -- OpenID Connect ----------------------------------------------------------------

  describe "validate_oidc/2 (discovery + JWKS + RS256)" do
    setup do
      key = rsa_keypair()
      kid = "test-key-1"
      port = free_port()

      start_supervised(
        {Bandit, plug: {__MODULE__.DiscoveryServer, [key: key, kid: kid, port: port]}, port: port}
      )

      {:ok,
       discovery: "http://127.0.0.1:#{port}/.well-known/openid-configuration",
       key: key,
       kid: kid,
       jwk: jwk_from_key(key, kid)}
    end

    test "valid RS256 token via discovery passes", %{discovery: discovery, key: key, kid: kid} do
      token = rs256_token(claims(), key, kid)

      assert {:ok, result} =
               SecurityValidators.validate_oidc(token,
                 discovery: discovery,
                 issuer: "https://auth.example.com",
                 audience: "a2a-api"
               )

      assert result["sub"] == "user-1"
    end

    test "bad signature refused", %{discovery: discovery, kid: kid} do
      other_key = rsa_keypair()
      token = rs256_token(claims(), other_key, kid)

      assert {:error, %{code: :bad_signature}} =
               SecurityValidators.validate_oidc(token, discovery: discovery)
    end

    test "unknown kid refused", %{discovery: discovery, key: key} do
      token = rs256_token(claims(), key, "unknown-kid")

      assert {:error, %{code: :unknown_kid}} =
               SecurityValidators.validate_oidc(token, discovery: discovery)
    end

    test "expired token refused", %{discovery: discovery, key: key, kid: kid} do
      token = rs256_token(claims(%{"exp" => @now - 100}), key, kid)

      assert {:error, %{code: :token_expired}} =
               SecurityValidators.validate_oidc(token, discovery: discovery)
    end

    test "pre-loaded :jwks skips discovery", %{key: key, kid: kid, jwk: jwk} do
      token = rs256_token(claims(), key, kid)

      assert {:ok, _} = SecurityValidators.validate_oidc(token, jwks: %{"keys" => [jwk]})
    end

    test "discovery endpoint failure is a typed error" do
      # Nothing listening on this port (Bandit not started for 1).
      assert {:error, %{code: :discovery_error}} =
               SecurityValidators.validate_oidc("t",
                 discovery: "http://127.0.0.1:1/.well-known/openid-configuration"
               )
    end
  end

  # -- verifier/1 (Auth plug callback factory) -----------------------------------------

  describe "verifier/1" do
    test "unconfigured scheme refused fail-closed" do
      vf = SecurityValidators.verifier(%{"configured" => [secret: "s"]})

      assert {:error, %{code: :unconfigured_scheme}} = vf.("other", "token", nil)
    end

    test "kind dispatch per scheme name" do
      vf =
        SecurityValidators.verifier(%{
          "key" => [kind: :key, keys: ["k-1"]],
          "bearer" => [secret: "s"]
        })

      assert {:ok, _} = vf.("key", "k-1", nil)
      assert {:error, %{code: :invalid_api_key}} = vf.("key", "k-2", nil)
      assert {:error, %{code: :malformed_token}} = vf.("bearer", "garbage", nil)
    end
  end

  # -- End-to-end through AshA2A.Protocol.Plug.Auth ---------------------------------------

  describe "API-key location enforcement through Plug.Auth" do
    @schemes %{
      "key" => %SecurityScheme.APIKey{in: "header", name: "x-api-key"},
      "bearer" => %SecurityScheme.HTTPAuth{scheme: "bearer"}
    }

    defp auth_opts do
      Auth.init(
        schemes: @schemes,
        verify:
          SecurityValidators.verifier(%{
            "key" => [kind: :key, keys: ["k-123"]],
            "bearer" => [secret: "s3cret", issuer: "https://auth.example.com"]
          })
      )
    end

    test "api key in the declared header passes and stores identity" do
      conn =
        conn(:post, "/a2a", %{})
        |> put_req_header("x-api-key", "k-123")
        |> Auth.call(auth_opts())

      refute conn.halted
      assert %{scheme: "key"} = Auth.get_identity(conn)
    end

    test "api key supplied at the wrong location is 401, not a pass" do
      conn =
        conn(:post, "/a2a?key=k-123", %{})
        |> Auth.call(auth_opts())

      assert conn.status == 401
      assert conn.halted
      assert Jason.decode!(conn.resp_body) == %{"error" => "Unauthorized"}
    end

    test "wrong api key value is 401" do
      conn =
        conn(:post, "/a2a", %{})
        |> put_req_header("x-api-key", "wrong")
        |> Auth.call(auth_opts())

      assert conn.status == 401
      assert Jason.decode!(conn.resp_body) == %{"error" => "Unauthorized"}
    end

    test "valid bearer JWT passes through the same pipeline" do
      token = hs256_token(claims(%{"scope" => nil}), "s3cret")

      conn =
        conn(:post, "/a2a", %{})
        |> put_req_header("authorization", "Bearer #{token}")
        |> Auth.call(auth_opts())

      refute conn.halted
      assert %{scheme: "bearer", identity: identity} = Auth.get_identity(conn)
      assert identity["sub"] == "user-1"
    end

    test "expired bearer JWT is 401" do
      token = hs256_token(claims(%{"exp" => @now - 3600}), "s3cret")

      conn =
        conn(:post, "/a2a", %{})
        |> put_req_header("authorization", "Bearer #{token}")
        |> Auth.call(auth_opts())

      assert conn.status == 401
    end
  end

  # -- Real test servers (Chicago: no stubs) ----------------------------------------------

  defmodule IntrospectionServer do
    @behaviour Plug

    import Plug.Conn

    def init(opts), do: Map.new(opts)

    def call(conn, opts) do
      case {conn.path_info, conn.method} do
        {["introspect"], "POST"} ->
          {:ok, body, conn} = read_body(conn)
          %{"token" => token} = URI.decode_query(body)

          active = not Map.get(opts, :inactive, false)

          resp =
            if token == "tok-expired" do
              %{
                "active" => true,
                "sub" => "user-1",
                "scope" => "a2a:read a2a:write",
                "exp" => System.system_time(:second) - 100
              }
            else
              %{
                "active" => active,
                "sub" => "user-1",
                "scope" => "a2a:read a2a:write",
                "exp" => System.system_time(:second) + 600
              }
            end

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(resp))

        _ ->
          send_resp(conn, 404, "not found")
      end
    end
  end

  defmodule DiscoveryServer do
    @behaviour Plug

    import Plug.Conn

    def init(opts), do: Map.new(opts)

    def call(conn, opts) do
      case conn.path_info do
        [".well-known", "openid-configuration"] ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(
            200,
            Jason.encode!(%{
              "issuer" => "https://auth.example.com",
              "jwks_uri" => "http://127.0.0.1:#{opts.port}/jwks"
            })
          )

        ["jwks"] ->
          kid = opts.kid

          {:RSAPrivateKey, _, n, e, _, _, _, _, _, _, _} = opts.key

          jwk = %{
            "kty" => "RSA",
            "kid" => kid,
            "n" => Base.url_encode64(:binary.encode_unsigned(n), padding: false),
            "e" => Base.url_encode64(:binary.encode_unsigned(e), padding: false),
            "alg" => "RS256",
            "use" => "sig"
          }

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(%{"keys" => [jwk]}))

        _ ->
          send_resp(conn, 404, "not found")
      end
    end
  end
end


# ==============================================================================
# SECTION 12 of 15: test/ash_a2a/protocol/stream_ordering_test.exs
# ==============================================================================

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

  @terminal_states [
    "TASK_STATE_COMPLETED",
    "TASK_STATE_FAILED",
    "TASK_STATE_CANCELED",
    "TASK_STATE_REJECTED",
    "TASK_STATE_AUTH_REQUIRED"
  ]

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


# ==============================================================================
# SECTION 13 of 15: test/ash_a2a/supply_chain/release_path_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SupplyChain.ReleasePathTest do
  @moduledoc """
  Release-path court: one publisher, no scheduled publisher, EKV_BUILD wherever
  `mix` runs, authority admitted first, and version coherence across mix.exs and
  the one admitted restatement site (`docs/reference/a2a-spec-version-mapping.md`),
  refusing any second restatement (v26.10.2 EL1). Reads the real workflow files
  with the real `YamlElixir` parser; the version comparison is a pure function
  that is also exercised on a deliberately mismatched pair (red-first: the
  detector must report the mismatch).
  """

  use ExUnit.Case, async: true

  @root File.cwd!()
  @workflows Path.wildcard(Path.join(@root, ".github/workflows/*.yml"))

  defp yaml!(path), do: YamlElixir.read_from_file!(path)

  defp steps(wf), do: for({_j, job} <- wf["jobs"] || %{}, step <- job["steps"] || [], do: step)

  defp run_lines(wf) do
    wf
    |> steps()
    |> Enum.flat_map(&String.split(&1["run"] || "", "\n"))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&String.starts_with?(&1, "#"))
  end

  defp publishes?(wf), do: Enum.any?(run_lines(wf), &(&1 =~ ~r/\bmix hex\.publish\b/))

  @doc false
  def version_findings(mix_version, docs) when is_binary(mix_version) and is_map(docs) do
    for {name, text} <- docs,
        found = doc_version(text),
        found != mix_version,
        do: {name, found, mix_version}
  end

  defp doc_version(text) do
    case Regex.run(~r/Version:\s*v?(\d+\.\d+\.\d+)/, text) do
      [_, v] -> v
      nil -> "MISSING"
    end
  end

  defp mix_version do
    [_, v] = Regex.run(~r/^\s*@version\s+"([^"]+)"/m, File.read!(Path.join(@root, "mix.exs")))
    v
  end

  test "exactly one workflow can run `mix hex.publish`, and it is release.yml" do
    publishers = for p <- @workflows, publishes?(yaml!(p)), do: Path.basename(p)
    assert publishers == ["release.yml"]
  end

  # `on:` may be a bare string (`on: push`) — Access would crash on a binary.
  defp trigger(wf, key) do
    case Map.get(wf, "on") do
      m when is_map(m) -> Map.get(m, key)
      _ -> nil
    end
  end

  test "no workflow with a schedule trigger publishes, and release.yml has none" do
    scheduled =
      for p <- @workflows, wf = yaml!(p), trigger(wf, "schedule"), do: {p, wf}

    assert scheduled != [], "anti-vacuity: flake-hunt/conformance are scheduled"
    assert Enum.all?(scheduled, fn {_p, wf} -> not publishes?(wf) end)

    release = yaml!(Path.join(@root, ".github/workflows/release.yml"))
    refute trigger(release, "schedule")
    refute get_in(release, ["on", "push", "branches"])
    refute File.exists?(Path.join(@root, ".github/workflows/release-v26.9.29.yml"))
  end

  test "every workflow that runs mix sets EKV_BUILD" do
    offenders =
      for p <- @workflows,
          wf = yaml!(p),
          Enum.any?(run_lines(wf), &(&1 =~ ~r/(^|\s)mix\s/)),
          not ekv_build_set?(wf),
          do: Path.basename(p)

    assert offenders == []
  end

  # EKV_BUILD is lawful at workflow, job, or step level.
  defp ekv_build_set?(wf) do
    workflow_level = get_in(wf, ["env", "EKV_BUILD"]) == "1"

    job_level =
      wf
      |> Map.get("jobs", %{})
      |> Map.values()
      |> Enum.any?(fn job ->
        get_in(job, ["env", "EKV_BUILD"]) == "1" or
          Enum.any?(job["steps"] || [], fn step ->
            get_in(step, ["env", "EKV_BUILD"]) == "1"
          end)
      end)

    workflow_level or job_level
  end

  test "release.yml's first step admits HEX_API_KEY presence before any build work" do
    release = yaml!(Path.join(@root, ".github/workflows/release.yml"))
    [first | _] = steps(release)
    refute first["uses"], "first step must be the authority check, not a checkout"
    assert first["env"]["HEX_API_KEY"] =~ "secrets.HEX_API_KEY"
    assert first["run"] =~ "BLOCKED(authority:HEX_API_KEY)"
  end

  test "release.yml has a non-publishing dry run that verifies attestations and attests crate SBOMs" do
    release = yaml!(Path.join(@root, ".github/workflows/release.yml"))
    assert Map.has_key?(release["on"], "workflow_dispatch")

    publish = Enum.find(steps(release), &(&1["name"] == "Publish to Hex"))
    assert publish["if"] =~ "github.event_name == 'push'"

    text = Enum.join(run_lines(release), "\n")
    assert text =~ ~s(gh attestation verify "ash_a2a-$VERSION.tar")

    sboms =
      for s <- steps(release),
          String.starts_with?(s["uses"] || "", "actions/attest-sbom@"),
          do: get_in(s, ["with", "sbom-path"])

    assert Enum.any?(sboms, &(&1 =~ "hddl_cli-"))
    assert Enum.any?(sboms, &(&1 =~ "graphlaw_host-"))
  end

  test "supporting supply-chain files exist (dependabot, CODEOWNERS, scorecard)" do
    dep = yaml!(Path.join(@root, ".github/dependabot.yml"))
    ecosystems = for u <- dep["updates"], do: {u["package-ecosystem"], u["directory"]}

    for e <- [
          {"mix", "/"},
          {"cargo", "/native/hddl_cli"},
          {"cargo", "/native/graphlaw_host"},
          {"github-actions", "/"}
        ],
        do: assert(e in ecosystems)

    assert File.exists?(Path.join(@root, ".github/CODEOWNERS"))
    score = yaml!(Path.join(@root, ".github/workflows/scorecard.yml"))

    assert Enum.any?(
             steps(score),
             &String.starts_with?(&1["uses"] || "", "ossf/scorecard-action@")
           )
  end

  describe "version coherence" do
    test "the comparison detects a mismatched pair (red-first)" do
      docs = %{
        "a" => "Version: v26.9.27\n",
        "b" => "no version line",
        "c" => "Version: v26.9.28."
      }

      assert Enum.sort(version_findings("26.9.28", docs)) ==
               [{"a", "26.9.27", "26.9.28"}, {"b", "MISSING", "26.9.28"}]

      assert version_findings("26.9.28", %{"c" => "Version: v26.9.28."}) == []
    end

    test "mix.exs and the one admitted restatement site (spec-version mapping) agree" do
      docs = %{
        "docs/reference/a2a-spec-version-mapping.md" =>
          File.read!(Path.join(@root, "docs/reference/a2a-spec-version-mapping.md"))
      }

      assert version_findings(mix_version(), docs) == []
    end

    test "no other doc restates the package version (EL1: one admitted site)" do
      guarded =
        [
          "README.md",
          "CHANGELOG.md",
          "docs/reference",
          "docs/how-to",
          "docs/tutorials",
          "docs/explanation"
        ]
        |> Enum.flat_map(fn path ->
          full = Path.join(@root, path)

          if File.dir?(full) do
            Path.wildcard(Path.join(full, "**/*.md"))
          else
            [full]
          end
        end)
        |> List.delete(Path.join(@root, "docs/reference/a2a-spec-version-mapping.md"))
        # graphlaw-v26.10.28-compat.md restates the ENGINE version (not the
        # package version) — coordinator-sanctioned admitted site.
        |> List.delete(Path.join(@root, "docs/reference/graphlaw-v26.10.28-compat.md"))

      restatements =
        for path <- guarded,
            Regex.match?(~r/Version:\s*v?\d+\.\d+\.\d+/, File.read!(path)),
            do: Path.relative_to(path, @root)

      assert restatements == [],
             "docs outside mix.exs restate the package version; the one admitted " <>
               "site is docs/reference/a2a-spec-version-mapping.md — remove the " <>
               "restatements instead of syncing them: #{inspect(restatements)}"
    end
  end
end


# ==============================================================================
# SECTION 14 of 15: test/ash_a2a/supply_chain/supply_chain_policy_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SupplyChain.SupplyChainPolicyTest do
  @moduledoc """
  Supply-chain policy court over this repository's REAL build/release inputs
  (`.github/workflows/*.yml`, `.github/cargo-deny.toml`, `mix.exs`,
  `.gitignore`, `native/*/Cargo.toml`, `.tool-versions`). Chicago style:
  every assertion reads the actual file (workflows parsed with the real
  `YamlElixir` parser, ignore rules resolved by the real `git check-ignore`,
  the package closure exercised through the real
  `AshA2A.Chicago.Release.CompositionLock.build!/1`) -- nothing is faked.

  Each test is a guard for one audit finding (SC-02, SC-03, SC-06, SC-08,
  SC-09, SC-10, SC-12, TQ-09, TQ-10): removing the guarded line from the
  real file makes the corresponding test fail.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Chicago.Release.CompositionLock

  @root File.cwd!()
  @workflows Path.wildcard(Path.join(@root, ".github/workflows/*.yml"))
  # Local composite actions hold CI steps too; the guards that scan steps must
  # not go blind when a step moves into one.
  @composites Path.wildcard(Path.join(@root, ".github/actions/*/action.yml"))
  @ci_files @workflows ++ @composites
  @sha_pin ~r/^[^@\s]+@[0-9a-f]{40}$/

  defp read!(rel), do: File.read!(Path.join(@root, rel))
  defp yaml!(path), do: YamlElixir.read_from_file!(path)

  defp steps(%{"runs" => %{"steps" => steps}}) when is_list(steps), do: steps

  defp steps(workflow) do
    for {_job, job} <- workflow["jobs"] || %{}, step <- job["steps"] || [], do: step
  end

  defp run_text(workflow), do: workflow |> steps() |> Enum.map_join("\n", &(&1["run"] || ""))

  test "the workflow set is non-empty (anti-vacuity for the per-workflow guards)" do
    assert length(@workflows) >= 5
  end

  describe "SC-06 action pinning and release authority" do
    test "every third-party action is pinned to a full 40-hex commit SHA" do
      unpinned =
        for path <- @ci_files,
            step <- steps(yaml!(path)),
            uses = step["uses"],
            is_binary(uses),
            not String.starts_with?(uses, "./"),
            not Regex.match?(@sha_pin, uses),
            do: {Path.basename(path), uses}

      assert unpinned == []
    end

    test "every workflow declares read-only workflow-scope permissions" do
      # A missing `permissions:` key inherits the repository default token
      # scope (possibly write-all), so absence is an offence, not a pass.
      offenders =
        for path <- @workflows,
            # A generator, not `perms = ...`: in `for`, a match on a nil value
            # is a falsy filter and would silently drop the offender.
            perms <- [yaml!(path)["permissions"]],
            not (is_map(perms) and perms != %{} and
                   Enum.all?(Map.values(perms), &(&1 in ["read", "none"]))),
            do: {Path.basename(path), perms}

      assert offenders == []
    end

    test "checkouts never persist the job token into .git/config" do
      offenders =
        for path <- @workflows,
            step <- steps(yaml!(path)),
            String.starts_with?(step["uses"] || "", "actions/checkout@"),
            get_in(step, ["with", "persist-credentials"]) != false,
            do: Path.basename(path)

      assert offenders == []
    end

    test "the Hex release is tag-triggered, environment-protected and fails closed without HEX_API_KEY" do
      release = yaml!(Path.join(@root, ".github/workflows/release.yml"))
      # YamlElixir decodes the `on:` key as the string "on".
      assert get_in(release, ["on", "push", "tags"]) == ["v*"]
      refute get_in(release, ["on", "push", "branches"])

      job = release["jobs"]["release"]
      assert job["environment"] == "hex-release"
      assert job["permissions"]["contents"] == "write"
      assert job["permissions"]["id-token"] == "write"

      text = run_text(release)
      assert text =~ "BLOCKED(authority:HEX_API_KEY)"
      assert text =~ ~s(test "$tag" = "$version")
      refute File.exists?(Path.join(@root, ".github/workflows/release-v26.9.25.yml"))
    end

    test "SC-07: release produces CycloneDX SBOMs and provenance/SBOM attestations" do
      release = yaml!(Path.join(@root, ".github/workflows/release.yml"))
      uses = release |> steps() |> Enum.map(&(&1["uses"] || ""))
      assert Enum.any?(uses, &String.starts_with?(&1, "actions/attest-build-provenance@"))
      assert Enum.any?(uses, &String.starts_with?(&1, "actions/attest-sbom@"))

      text = run_text(release)
      assert text =~ "mix_sbom\" cyclonedx --only prod"
      assert text =~ "cargo +1.97.1 cyclonedx"
      assert text =~ "gh release upload"

      # The published registry artifact must be the attested one: Hex's outer
      # checksum is compared with the sha256 of the attested tarball.
      verify = Enum.find(steps(release), &(&1["name"] == "Verify Hex consequence"))
      assert verify["run"] =~ ~s(sha256sum "ash_a2a-$VERSION.tar")
      assert verify["run"] =~ ~s([ "$remote_sum" = "$local_sum" ])
      assert verify["run"] =~ "REFUSED(release:hex checksum"
    end

    test "SC-12: release proves the consumer prod closure compiles before publishing" do
      release = yaml!(Path.join(@root, ".github/workflows/release.yml"))

      prod_step =
        Enum.find(steps(release), &(get_in(&1, ["env", "MIX_ENV"]) == "prod"))

      assert prod_step, "no MIX_ENV=prod verification step"
      assert prod_step["run"] =~ "mix deps.get --only prod"
      assert prod_step["run"] =~ "mix compile --warnings-as-errors"
    end
  end

  describe "SC-02 advisory and lock-drift gates" do
    test "CI refuses lock drift, Hex advisories and Rust advisories for both crates" do
      text = run_text(yaml!(Path.join(@root, ".github/workflows/ci.yml")))
      assert text =~ "mix deps.get --check-locked"
      assert text =~ "mix hex.audit"

      for crate <- ~w(hddl_cli graphlaw_host) do
        assert text =~
                 "cargo deny --manifest-path native/#{crate}/Cargo.toml " <>
                   "--config .github/cargo-deny.toml --locked " <>
                   "check advisories bans licenses sources"
      end
    end

    test "the release refuses lock drift and advisories before building" do
      text = run_text(yaml!(Path.join(@root, ".github/workflows/release.yml")))
      assert text =~ "mix deps.get --check-locked"
      assert text =~ "mix hex.audit"
    end

    test "cargo-deny policy denies yanked crates and unknown git/registry sources" do
      deny = read!(".github/cargo-deny.toml")
      assert deny =~ ~s(yanked = "deny")
      assert deny =~ ~s(unknown-git = "deny")
      assert deny =~ ~s(unknown-registry = "deny")
      assert deny =~ ~s(allow-git = ["https://github.com/seanchatmangpt/ferroplan.git"])
    end
  end

  describe "SC-08 native crate identity" do
    test "every cargo build in every workflow uses the pinned toolchain and --locked" do
      offenders =
        for path <- @ci_files,
            line <- String.split(run_text(yaml!(path)), "\n"),
            line =~ ~r/\bcargo\b.*\bbuild\b/,
            not (line =~ "cargo +1.97.1" and line =~ "--locked"),
            do: {Path.basename(path), String.trim(line)}

      assert offenders == []
    end

    test "native crates pin every dependency exactly, are unpublishable and carry a toolchain pin" do
      for crate <- ~w(hddl_cli graphlaw_host) do
        manifest = read!("native/#{crate}/Cargo.toml")
        [_, deps] = String.split(manifest, "[dependencies]", parts: 2)

        for line <- String.split(deps, "\n", trim: true),
            not String.starts_with?(String.trim(line), "#") do
          assert line =~ ~r/(=\s*"=\d|version\s*=\s*"=\d)/,
                 "#{crate}: dependency not exactly pinned: #{line}"
        end

        assert manifest =~ "publish = false"
        assert read!("native/#{crate}/rust-toolchain.toml") =~ ~s(channel = "1.97.1")
      end
    end
  end

  describe "SC-09 one BEAM toolchain identity" do
    test "every setup-beam step reads .tool-versions strictly (no inline versions)" do
      beam_steps =
        for path <- @ci_files,
            step <- steps(yaml!(path)),
            String.starts_with?(step["uses"] || "", "erlef/setup-beam@"),
            do: {Path.basename(path), step["with"]}

      assert beam_steps != []

      for {file, with} <- beam_steps do
        assert with["version-file"] == ".tool-versions", file
        assert with["version-type"] == "strict", file
        refute Map.has_key?(with, "otp-version"), file
        refute Map.has_key?(with, "elixir-version"), file
      end
    end
  end

  describe "SC-03 deliberate ekv source build" do
    test "every workflow that runs mix sets EKV_BUILD=1 and refuses lock drift" do
      mix_workflows =
        for path <- @workflows,
            wf = yaml!(path),
            text = run_text(wf),
            text =~ ~r/(^|\s)mix\s/m,
            do: {Path.basename(path), wf, text}

      # Anti-vacuity: the release, CI and court workflows all run mix.
      assert length(mix_workflows) >= 8

      for {file, wf, text} <- mix_workflows do
        assert get_in(wf, ["env", "EKV_BUILD"]) == "1", file

        for line <- String.split(text, "\n"), line =~ ~r/\bmix deps\.get\b/ do
          assert line =~ "--check-locked", "#{file}: unlocked deps.get: #{String.trim(line)}"
        end
      end
    end
  end

  describe "SC-10 package closure" do
    test "the Hex package ships the native sources lib/ reads, never build output" do
      files = Mix.Project.config()[:package][:files]

      for crate <- ~w(hddl_cli graphlaw_host), f <- ~w(Cargo.toml Cargo.lock src) do
        path = "native/#{crate}/#{f}"
        assert path in files, "package omits #{path}"
        assert File.exists?(Path.join(@root, path)), "#{path} missing on disk"
      end

      refute Enum.any?(files, &String.contains?(&1, "target"))
    end

    @tag :tmp_dir
    test "CompositionLock resolves every native pin from a package-shaped tree", %{tmp_dir: dir} do
      files = Mix.Project.config()[:package][:files]

      for rel <- files, String.starts_with?(rel, "native/") do
        src = Path.join(@root, rel)
        dst = Path.join(dir, rel)
        File.mkdir_p!(Path.dirname(dst))
        File.cp_r!(src, dst)
      end

      # No mix.lock in the tree: Hex tarballs do not carry it, and the native
      # pins must resolve without it.
      lock = CompositionLock.build!(repo: dir)

      assert lock.native_pins == %{
               "ferroplan" => "e90928d7b0687a959831553c4eacca3d75ca6c88",
               "ferroplan-hddl" => "e90928d7b0687a959831553c4eacca3d75ca6c88"
             }
    end
  end

  describe "SC-12 lane build roots are ignored" do
    test "git ignores per-lane build roots" do
      {out, 0} =
        System.cmd("git", ["check-ignore", "-v", "_build-lane7/x", "_build-merge/y"], cd: @root)

      assert out =~ "_build-lane7/x"
      assert out =~ "_build-merge/y"
    end
  end

  describe "TQ-09/TQ-10 test-quality gates" do
    test "coverage is measured with a non-zero threshold and CI runs it" do
      threshold = get_in(Mix.Project.config(), [:test_coverage, :summary, :threshold])
      assert is_integer(threshold) and threshold > 0

      lines =
        Path.join(@root, ".github/workflows/ci.yml")
        |> yaml!()
        |> run_text()
        |> String.split("\n")

      # Any `mix test[.alias]` run under --cover counts: the suite is split into
      # lanes (fast / serial_solo / serial_shard) that together are `test.all`.
      cover_runs = Enum.filter(lines, &(&1 =~ ~r/mix test(\.\w+)*\b.*--cover\b/))
      assert cover_runs != [], "CI does not run the suite under --cover"

      # `--export-coverage` makes Mix write .coverdata and skip the threshold
      # (witnessed exit 0 at 33% under a 99% floor), so a gated run must not
      # carry it unless a later `mix test.coverage` evaluates the export.
      for line <- cover_runs, line =~ "--export-coverage" do
        assert Enum.any?(lines, &(&1 =~ ~r/^\s*mix test\.coverage\b/)),
               "coverage threshold is never evaluated: #{line}"
      end
    end

    @tag :tmp_dir
    test "the coverage threshold is enforced by a real mix run (exit 3 below the floor)",
         %{tmp_dir: dir} do
      # Real collaborator: a throwaway Mix project run through the same
      # `mix test --cover` invocation CI uses, with this repo's threshold
      # config shape, and one uncovered function to push coverage below it.
      File.write!(Path.join(dir, "mix.exs"), """
      defmodule CovProbe.MixProject do
        use Mix.Project
        def project,
          do: [app: :cov_probe, version: "0.1.0", test_coverage: [summary: [threshold: 99]]]
      end
      """)

      File.mkdir_p!(Path.join(dir, "lib"))
      File.mkdir_p!(Path.join(dir, "test"))

      File.write!(Path.join(dir, "lib/cov_probe.ex"), """
      defmodule CovProbe do
        def a, do: 1
        def b(x), do: x * 2 + 1
      end
      """)

      File.write!(Path.join(dir, "test/test_helper.exs"), "ExUnit.start()\n")

      File.write!(Path.join(dir, "test/cov_probe_test.exs"), """
      defmodule CovProbeTest do
        use ExUnit.Case
        test "a", do: assert(CovProbe.a() == 1)
      end
      """)

      env = [{"MIX_ENV", "test"}, {"MIX_BUILD_ROOT", Path.join(dir, "_build")}]

      {out, gated} =
        System.cmd("mix", ["test", "--cover"], cd: dir, env: env, stderr_to_stdout: true)

      assert gated == 3, out

      {_, exported} =
        System.cmd("mix", ["test", "--cover", "--export-coverage", "all"],
          cd: dir,
          env: env,
          stderr_to_stdout: true
        )

      assert exported == 0, "Mix now gates exports; revisit the CI coverage step"
    end

    test "a scheduled flake hunt runs a seed matrix and repeat-until-failure" do
      wf = yaml!(Path.join(@root, ".github/workflows/flake-hunt.yml"))
      assert [%{"cron" => _}] = get_in(wf, ["on", "schedule"])
      assert get_in(wf, ["jobs", "seeds", "strategy", "matrix", "seed"]) |> length() >= 5

      text = run_text(wf)
      assert text =~ ~s(--seed "$SEED")
      assert text =~ "--repeat-until-failure 50"
    end
  end
end


# ==============================================================================
# SECTION 15 of 15: test/ash_a2a/transport/transport_court_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.TransportCourt.Probe do
  @moduledoc false
  use Ash.Resource,
    domain: AshA2A.TransportCourt.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  actions do
    action :whoami, :map do
      run(fn _input, context ->
        subject =
          case context.actor do
            %{sub: sub} -> sub
            other when is_binary(other) -> other
            _ -> nil
          end

        {:ok, %{"subject" => subject}}
      end)
    end

    action :pair, :map do
      argument(:left, :string, allow_nil?: false)
      argument(:right, :string, allow_nil?: false)

      run(fn input, context ->
        {:ok,
         %{
           "left" => input.arguments.left,
           "right" => input.arguments.right,
           "subject" => context.actor && context.actor[:sub]
         }}
      end)
    end

    action :slow, :map do
      argument(:ms, :integer, allow_nil?: false)

      run(fn input, _context ->
        # SLEEP-CLASS: SIMULATED-SLOW-HANDLER (fixture models a slow collaborator)
        Process.sleep(input.arguments.ms)
        {:ok, %{"slept" => input.arguments.ms}}
      end)
    end

    action :ctx, :map do
      run(fn _input, context ->
        source = context.source_context || %{}
        client = Map.get(source, :a2a_client_context, %{})

        {:ok,
         %{
           "top_level_is_admin" => Map.get(source, "is_admin"),
           "client_is_admin" => Map.get(client, "is_admin")
         }}
      end)
    end
  end

  a2a do
    skill(:whoami, :whoami, consequence: :observe)
    skill(:pair, :pair, consequence: :observe)
    skill(:slow, :slow, consequence: :observe)
    skill(:ctx, :ctx, consequence: :observe)
  end
end

defmodule AshA2A.TransportCourt.Domain do
  @moduledoc false
  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.TransportCourt.Probe)
  end
end

defmodule AshA2A.TransportCourt.Agent do
  @moduledoc false
  use AshA2A.Agent,
    resource_or_domain: AshA2A.TransportCourt.Probe,
    name: "transport_court_agent",
    require_authenticated_caller: true
end

defmodule AshA2A.TransportCourt.RefuseCancelAgent do
  @moduledoc false
  # The default interrupts an in-flight worker on tasks/cancel; this agent opts
  # into the documented `cancel_in_flight: :refuse` (`:not_cancelable`) behavior.
  use AshA2A.Agent,
    resource_or_domain: AshA2A.TransportCourt.Probe,
    name: "transport_court_refuse_cancel_agent",
    require_authenticated_caller: true,
    execution: [cancel_in_flight: :refuse]
end

defmodule AshA2A.TransportCourt.InlineAgent do
  @moduledoc false
  use AshA2A.Agent,
    resource_or_domain: AshA2A.TransportCourt.Probe,
    name: "transport_court_inline_agent",
    require_authenticated_caller: true,
    execution: [mode: :inline]
end

defmodule AshA2A.TransportCourt.BusyAgent do
  @moduledoc false
  use AshA2A.Agent,
    resource_or_domain: AshA2A.TransportCourt.Probe,
    name: "transport_court_busy_agent",
    require_authenticated_caller: true,
    execution: [max_in_flight: 1]
end

defmodule AshA2A.TransportCourt.RateAgent do
  @moduledoc false
  use AshA2A.Agent,
    resource_or_domain: AshA2A.TransportCourt.Probe,
    name: "transport_court_rate_agent",
    require_authenticated_caller: true,
    execution: [rate_limit: {1, 60_000}]
end

defmodule AshA2A.TransportCourt.PublicAgent do
  @moduledoc false
  use AshA2A.Agent,
    resource_or_domain: AshA2A.TransportCourt.Probe,
    name: "transport_court_public_agent",
    require_authenticated_caller: true,
    public_skills: [:whoami]
end

defmodule AshA2A.TransportCourt.CrashAgent do
  @moduledoc false
  use AshA2A.Agent,
    resource_or_domain: AshA2A.TransportCourt.Probe,
    name: "transport_court_crash_agent",
    require_authenticated_caller: false

  # A handler bug: raises for "raise", kills its own process for "kill".
  @impl AshA2A.Protocol.Agent
  def handle_message(%AshA2A.Protocol.Message{} = message, context) do
    case AshA2A.Protocol.Message.text(message) do
      "raise" -> raise "SELECT secret_column FROM credentials -- internal detail"
      "kill" -> Process.exit(self(), :kill)
      _ -> super(message, context)
    end
  end
end

defmodule AshA2A.TransportCourt.MessageAgent do
  @moduledoc false
  use AshA2A.Agent,
    resource_or_domain: AshA2A.TransportCourt.Probe,
    name: "transport_court_message_agent",
    require_authenticated_caller: true

  # Thin TCK-SUT-style wrapper: skill metadata "dm" replies out-of-band
  # (`{:message, parts}` — a bare Message, no task); "file-artifact" replies
  # with a typed file part. Everything else falls through to the real
  # AshA2A dispatch.
  @impl AshA2A.Protocol.Agent
  def handle_message(%AshA2A.Protocol.Message{} = message, context) do
    case message.metadata["skill"] do
      "dm" ->
        {:message, [AshA2A.Protocol.Part.Text.new("Direct message response")]}

      "file-artifact" ->
        file =
          AshA2A.Protocol.FileContent.from_bytes("tck",
            name: "output.txt",
            mime_type: "text/plain"
          )

        {:reply, [AshA2A.Protocol.Part.File.new(file)]}

      _ ->
        super(message, context)
    end
  end
end

defmodule AshA2A.TransportCourt.Pipeline do
  @moduledoc false
  @behaviour Plug

  @schemes %{"bearer_auth" => %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "bearer"}}

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    {auth?, opts} = Keyword.pop(opts, :auth?, true)

    conn =
      if auth?,
        do:
          AshA2A.Protocol.Plug.Auth.call(
            conn,
            AshA2A.Protocol.Plug.Auth.init(schemes: @schemes, verify: &verify/3)
          ),
        else: conn

    if conn.halted,
      do: conn,
      else: AshA2A.Transport.Plug.call(conn, AshA2A.Transport.Plug.init(opts))
  end

  # Identities deliberately carry a raw token and a volatile claim: neither
  # may ever surface on the wire or in the owner key.
  def verify("bearer_auth", "tok-alice", _conn),
    do: {:ok, %{sub: "alice", token: "tok-alice-SECRET", exp: 1}}

  def verify("bearer_auth", "tok-bob", _conn),
    do: {:ok, %{sub: "bob", token: "tok-bob-SECRET", exp: 2}}

  def verify(_scheme, _credential, _conn), do: {:error, "invalid token"}
end

defmodule AshA2A.TransportCourtTest do
  @moduledoc """
  Chicago court for the transport lane (SEC-01/02/03/05/08/11, TQ-05,
  CONF-06/09): real `AshA2A.Agent` GenServers, real `AshA2A.Protocol.Plug.Auth` +
  `AshA2A.Transport.Plug` behind a real Bandit listener on an ephemeral
  port, real HTTP via Req. No mocks.
  """
  use ExUnit.Case, async: false

  alias AshA2A.TransportCourt

  @error_info_type "type.googleapis.com/google.rpc.ErrorInfo"
  @a2a_domain "a2a-protocol.org"

  # v1.0 registry ErrorInfo shapes (AshA2A.Protocol.JSONRPC.Error): -32001 is
  # TASK_NOT_FOUND (also the owner-scope answer: a foreign task is
  # indistinguishable from a missing one), -32002 is TASK_NOT_CANCELABLE.
  defp task_not_found_info,
    do: %{"@type" => @error_info_type, "domain" => @a2a_domain, "reason" => "TASK_NOT_FOUND"}

  defp task_not_cancelable_info,
    do: %{"@type" => @error_info_type, "domain" => @a2a_domain, "reason" => "TASK_NOT_CANCELABLE"}

  defp start_http!(agent, extra \\ []) do
    name = :"#{inspect(agent)}_#{System.unique_integer([:positive])}"
    pid = start_supervised!({agent, name: name}, id: name)

    plug_opts = [agent: name, base_url: "http://127.0.0.1/a2a"] ++ extra

    server =
      start_supervised!(
        {Bandit,
         plug: {TransportCourt.Pipeline, plug_opts},
         port: 0,
         ip: {127, 0, 0, 1},
         startup_log: false},
        id: {:bandit, name}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    %{agent: pid, name: name, url: "http://127.0.0.1:#{port}"}
  end

  defp rpc(url, method, params, token) do
    headers = if token, do: [{"authorization", "Bearer " <> token}], else: []

    Req.post!(url,
      json: %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params},
      headers: headers,
      retry: false,
      receive_timeout: 15_000,
      decode_body: false
    )
  end

  defp rpc_json(url, method, params, token) do
    url |> rpc(method, params, token) |> Map.fetch!(:body) |> Jason.decode!()
  end

  defp message(skill, data, extra_metadata \\ %{}) do
    msg = %{
      AshA2A.Protocol.Message.new_user([AshA2A.Protocol.Part.Data.new(data)])
      | metadata: Map.put(extra_metadata, "skill", skill)
    }

    {:ok, json} = AshA2A.Protocol.JSON.encode(msg)
    json
  end

  defp send_msg(url, skill, data, token, extra \\ %{}) do
    rpc_json(url, "message/send", %{"message" => message(skill, data, extra)}, token)
  end

  defp artifact_data(%{"result" => %{"task" => task}}), do: artifact_data(task)

  defp artifact_data(%{"artifacts" => [%{"parts" => [%{"data" => data} | _]} | _]}), do: data

  describe "SEC-01 task ownership over real HTTP with two real bearer principals" do
    setup do
      start_http!(TransportCourt.Agent)
    end

    test "B cannot continue, read, cancel or list A's input_required task; A can", %{url: url} do
      a = send_msg(url, "pair", %{"left" => "L"}, "tok-alice")
      assert %{"result" => %{"task" => %{"id" => task_id, "status" => %{"state" => state}}}} = a
      assert state == "TASK_STATE_INPUT_REQUIRED"

      # A paused (non-terminal) task still holds the verified auth in memory;
      # it must never be echoed onto the wire.
      refute Jason.encode!(a) =~ "SECRET"

      # B continues A's task: refused, indistinguishable from unknown id.
      cont = %{
        AshA2A.Protocol.Message.new_user([AshA2A.Protocol.Part.Data.new(%{"right" => "R"})])
        | task_id: task_id
      }

      {:ok, cont} = AshA2A.Protocol.JSON.encode(%{cont | metadata: %{"skill" => "pair"}})
      b = rpc_json(url, "message/send", %{"message" => cont}, "tok-bob")

      # v1.0 registry: -32001 carries a TASK_NOT_FOUND google.rpc.ErrorInfo.
      not_found = task_not_found_info()
      assert %{"error" => %{"code" => -32001, "data" => [^not_found]}} = b

      # B cannot read / cancel / list it.
      assert %{"error" => %{"code" => -32001, "data" => [^not_found]}} =
               rpc_json(url, "tasks/get", %{"id" => task_id}, "tok-bob")

      assert %{"error" => %{"code" => -32001, "data" => [^not_found]}} =
               rpc_json(url, "tasks/cancel", %{"id" => task_id}, "tok-bob")

      %{"result" => %{"tasks" => b_tasks}} = rpc_json(url, "tasks/list", %{}, "tok-bob")
      refute Enum.any?(b_tasks, &(&1["id"] == task_id))

      # A's task is untouched by B's attempts, and A can list and finish it.
      assert %{"result" => %{"status" => %{"state" => "TASK_STATE_INPUT_REQUIRED"}}} =
               rpc_json(url, "tasks/get", %{"id" => task_id}, "tok-alice")

      %{"result" => %{"tasks" => a_tasks}} = rpc_json(url, "tasks/list", %{}, "tok-alice")
      assert Enum.any?(a_tasks, &(&1["id"] == task_id))

      done = rpc_json(url, "message/send", %{"message" => cont}, "tok-alice")

      assert %{"result" => %{"task" => %{"status" => %{"state" => "TASK_STATE_COMPLETED"}}}} =
               done

      assert %{"left" => "L", "right" => "R", "subject" => "alice"} = artifact_data(done)
    end

    test "task ids are 128-bit CSPRNG ids and credentials never echo onto the wire", %{url: url} do
      resp = rpc(url, "message/send", %{"message" => message("whoami", %{})}, "tok-alice")
      body = Jason.decode!(resp.body)
      %{"result" => %{"task" => %{"id" => id} = task}} = body
      assert "tsk-" <> suffix = id
      assert byte_size(suffix) == 22
      assert {:ok, <<_::128>>} = Base.url_decode64(suffix, padding: false)

      refute resp.body =~ "SECRET"
      refute Map.has_key?(task["metadata"] || %{}, "a2a.auth")
      refute resp.body =~ "ash_a2a.owner"

      get = rpc(url, "tasks/get", %{"id" => id}, "tok-alice")
      refute get.body =~ "SECRET"
    end

    test "a caller cannot forge a2a.auth through params.metadata", %{url: url} do
      forged = %{"a2a.auth" => %{"identity" => %{"sub" => "alice"}}}

      body =
        rpc_json(
          url,
          "message/send",
          %{"message" => message("whoami", %{}), "metadata" => forged},
          "tok-bob"
        )

      assert %{"subject" => "bob"} = artifact_data(body)
    end
  end

  describe "SEC-02 malformed requests fail only their own task" do
    setup do
      start_http!(TransportCourt.Agent)
    end

    test "non-map metadata, non-map context and non-map data are typed refusals; agent survives",
         %{url: url, agent: agent} do
      base = message("whoami", %{})

      bad_metadata =
        rpc_json(url, "message/send", %{"message" => Map.put(base, "metadata", [1])}, "tok-alice")

      bad_context =
        rpc_json(
          url,
          "message/send",
          %{"message" => Map.put(base, "metadata", %{"skill" => "whoami", "context" => "x"})},
          "tok-alice"
        )

      for body <- [bad_metadata, bad_context] do
        assert %{
                 "result" => %{
                   "task" => %{"status" => %{"state" => "TASK_STATE_FAILED", "message" => msg}}
                 }
               } =
                 body

        text = msg |> Map.fetch!("parts") |> hd() |> Map.fetch!("text")
        assert text =~ ":invalid_metadata" or text =~ ":invalid_context"
      end

      assert Process.alive?(agent)
      assert %{"subject" => "alice"} = artifact_data(send_msg(url, "whoami", %{}, "tok-alice"))
    end

    test "oversized client context is refused with a typed bound", %{url: url} do
      big = %{"blob" => String.duplicate("x", 20_000)}
      body = send_msg(url, "whoami", %{}, "tok-alice", %{"context" => big})

      assert %{
               "result" => %{
                 "task" => %{"status" => %{"state" => "TASK_STATE_FAILED", "message" => msg}}
               }
             } =
               body

      assert msg |> Map.fetch!("parts") |> hd() |> Map.fetch!("text") =~ ":context_too_large"
    end

    test "non-map Data part data is refused before dispatch" do
      message = %AshA2A.Protocol.Message{
        role: :user,
        parts: [%AshA2A.Protocol.Part.Data{data: "x"}],
        metadata: %{"skill" => "whoami"}
      }

      assert {:error, %{code: :invalid_input}} =
               AshA2A.Agent.__dispatch__(TransportCourt.Probe, message, %{}, [])
    end

    test "an exception inside dispatch becomes a typed internal_error with a ref" do
      message = %{AshA2A.Protocol.Message.new_user("hi") | metadata: %{"skill" => "whoami"}}

      assert {:error, %{code: :internal_error, ref: ref}} =
               AshA2A.Agent.__dispatch__(:not_an_ash_module, message, %{}, [])

      assert is_binary(ref) and byte_size(ref) == 16
    end
  end

  describe "SEC-02/SEC-08 handler crashes are isolated and redacted" do
    setup do
      start_http!(TransportCourt.CrashAgent)
    end

    test "a raising handler fails its task without leaking detail; a killed worker fails its task",
         %{url: url, agent: agent} do
      raise_msg = AshA2A.Protocol.JSON.encode!(AshA2A.Protocol.Message.new_user("raise"))
      resp = rpc(url, "message/send", %{"message" => raise_msg}, "tok-alice")
      body = Jason.decode!(resp.body)
      assert %{"result" => %{"task" => %{"status" => %{"state" => "TASK_STATE_FAILED"}}}} = body
      refute resp.body =~ "secret_column"
      assert resp.body =~ "internal_error"

      kill_msg = AshA2A.Protocol.JSON.encode!(AshA2A.Protocol.Message.new_user("kill"))
      body = rpc_json(url, "message/send", %{"message" => kill_msg}, "tok-alice")
      assert %{"result" => %{"task" => %{"status" => %{"state" => "TASK_STATE_FAILED"}}}} = body

      assert Process.alive?(agent)
    end
  end

  describe "SEC-03 execution leaves the agent mailbox free" do
    test "a slow action does not block other callers (async) but does in inline mode" do
      async = start_http!(TransportCourt.Agent)
      inline = start_http!(TransportCourt.InlineAgent)

      for {ctx, blocked?} <- [{async, false}, {inline, true}] do
        slow = Task.async(fn -> send_msg(ctx.url, "slow", %{"ms" => 1500}, "tok-alice") end)
        # SLEEP-CLASS: REAL-INTERVAL (audited AshA2A.TestSupport.Eventually.pause)
        AshA2A.TestSupport.Eventually.pause(200)
        {micros, body} = :timer.tc(fn -> send_msg(ctx.url, "whoami", %{}, "tok-bob") end)
        assert %{"subject" => "bob"} = artifact_data(body)
        assert %{"slept" => 1500} = artifact_data(Task.await(slow, 10_000))

        if blocked?,
          do: assert(micros > 1_000_000, "inline mode should serialize (#{micros}us)"),
          else: assert(micros < 1_000_000, "async mode blocked for #{micros}us")
      end
    end

    test "global in-flight cap refuses with -32000 server busy" do
      ctx = start_http!(TransportCourt.BusyAgent)
      slow = Task.async(fn -> send_msg(ctx.url, "slow", %{"ms" => 1000}, "tok-alice") end)
      # SLEEP-CLASS: POLL-STEP (audited AshA2A.TestSupport.Eventually.pause)
      AshA2A.TestSupport.Eventually.pause(200)

      assert %{"error" => %{"code" => -32000, "data" => %{"reason" => "server_busy"}}} =
               send_msg(ctx.url, "whoami", %{}, "tok-bob")

      Task.await(slow, 10_000)
      assert %{"subject" => "bob"} = artifact_data(send_msg(ctx.url, "whoami", %{}, "tok-bob"))
    end

    test "per-principal token bucket refuses the principal over its rate, not others" do
      ctx = start_http!(TransportCourt.RateAgent)

      assert %{"subject" => "alice"} =
               artifact_data(send_msg(ctx.url, "whoami", %{}, "tok-alice"))

      assert %{"error" => %{"code" => -32000, "data" => %{"reason" => "rate_limited"}}} =
               send_msg(ctx.url, "whoami", %{}, "tok-alice")

      assert %{"subject" => "bob"} = artifact_data(send_msg(ctx.url, "whoami", %{}, "tok-bob"))
    end
  end

  describe "SEC-05 unauthenticated callers fail closed" do
    test "no verified identity is refused :unauthenticated unless the skill is public" do
      closed = start_http!(TransportCourt.Agent, auth?: false)
      body = send_msg(closed.url, "whoami", %{}, nil)

      assert %{
               "result" => %{
                 "task" => %{"status" => %{"state" => "TASK_STATE_FAILED", "message" => msg}}
               }
             } =
               body

      assert msg |> Map.fetch!("parts") |> hd() |> Map.fetch!("text") =~ ":unauthenticated"

      open = start_http!(TransportCourt.PublicAgent, auth?: false)
      assert %{"subject" => nil} = artifact_data(send_msg(open.url, "whoami", %{}, nil))

      body = send_msg(open.url, "ctx", %{}, nil)
      assert %{"result" => %{"task" => %{"status" => %{"state" => "TASK_STATE_FAILED"}}}} = body
    end
  end

  describe "SEC-11 client context is namespaced, never top-level" do
    setup do
      start_http!(TransportCourt.Agent)
    end

    test "metadata.context lands under :a2a_client_context only", %{url: url} do
      body = send_msg(url, "ctx", %{}, "tok-alice", %{"context" => %{"is_admin" => true}})
      assert %{"top_level_is_admin" => nil, "client_is_admin" => true} = artifact_data(body)
    end
  end

  describe "TQ-05 message/stream works for a non-streaming Ash skill" do
    setup do
      start_http!(TransportCourt.Agent)
    end

    test "answers text/event-stream with snapshot, artifact and final completed status", %{
      url: url
    } do
      resp = rpc(url, "message/stream", %{"message" => message("whoami", %{})}, "tok-alice")
      assert [ct | _] = Req.Response.get_header(resp, "content-type")
      assert ct =~ "text/event-stream"

      events =
        resp.body
        |> String.split("\n\n", trim: true)
        |> Enum.map(fn "data: " <> json -> json |> Jason.decode!() |> Map.fetch!("result") end)

      # v1.0 StreamResponse frames: the JSON-RPC result is discriminated by the
      # wrapper key -- {"task" => ...}, {"artifactUpdate" => ...},
      # {"statusUpdate" => ...} -- with no "kind" discriminator and no "final"
      # boolean anywhere on the wire (finality is the terminal status state).
      assert [%{"task" => %{"id" => _, "status" => _}} | _] = events
      assert Enum.any?(events, &match?(%{"artifactUpdate" => %{"artifact" => _}}, &1))

      assert %{"statusUpdate" => %{"status" => %{"state" => "TASK_STATE_COMPLETED"}}} =
               List.last(events)

      refute resp.body =~ ~s("kind")
      refute resp.body =~ ~s("final")

      refute resp.body =~ "SECRET"
    end
  end

  describe "CONF-06/CONF-09 truthful agent card" do
    test "capabilities advertise streaming and the SA2A extension at capabilities.extensions" do
      plain = start_http!(TransportCourt.Agent)
      card = Req.get!(plain.url <> "/.well-known/agent-card.json", retry: false).body
      assert %{"streaming" => true, "pushNotifications" => false} = card["capabilities"]
      refute Map.has_key?(card["capabilities"], "extensions")

      semantic =
        start_http!(TransportCourt.Agent,
          agent_card_opts: AshA2A.Semantic.Extension.advertise(url: "http://127.0.0.1/a2a")
        )

      card = Req.get!(semantic.url <> "/.well-known/agent-card.json", retry: false).body
      uri = AshA2A.Semantic.Extension.profile_uri()
      assert [%{"uri" => ^uri, "required" => false}] = card["capabilities"]["extensions"]

      refute Enum.any?(
               card["supportedInterfaces"],
               &(&1["protocolBinding"] == AshA2A.Semantic.Extension.profile_id())
             )
    end

    test "AgentCardBuilder struct capabilities agree with the wire" do
      card = AshA2A.Info.agent_card(TransportCourt.Probe)
      assert card.capabilities.streaming == true
      assert card.capabilities.push_notifications == false
    end
  end

  describe "SEC-08 wire-safe errors" do
    test "internal errors carry a ref, never the exception detail (by default)" do
      error =
        AshA2A.Transport.SafeError.internal(:internal_error, %RuntimeError{message: "pg secret"})

      assert %{code: :internal_error, ref: ref} = error
      assert is_binary(ref)
      refute Map.has_key?(error, :detail)
    end

    test "redact drops detail-bearing keys and non-atom tuple members" do
      assert AshA2A.Transport.SafeError.redact(%{code: :boom, detail: "SELECT 1"}) == %{
               code: :boom
             }

      assert AshA2A.Transport.SafeError.redact({:action_resolution, "pg: relation x"}) ==
               {:action_resolution, :redacted}
    end
  end

  describe "adversarial court: cancel, anonymous listing, redaction, issuers" do
    test "tasks/cancel on a running handler is refused (cancel_in_flight: :refuse); the task completes truthfully" do
      ctx = start_http!(TransportCourt.RefuseCancelAgent)
      slow = Task.async(fn -> send_msg(ctx.url, "slow", %{"ms" => 1200}, "tok-alice") end)

      task_id =
        Enum.find_value(1..50, fn _ ->
          # SLEEP-CLASS: REAL-INTERVAL (audited AshA2A.TestSupport.Eventually.pause)
          AshA2A.TestSupport.Eventually.pause(20)

          case rpc_json(ctx.url, "tasks/list", %{}, "tok-alice") do
            %{"result" => %{"tasks" => [%{"id" => id} | _]}} -> id
            _ -> nil
          end
        end)

      assert is_binary(task_id)

      not_cancelable = task_not_cancelable_info()

      assert %{"error" => %{"code" => -32002, "data" => [^not_cancelable]}} =
               rpc_json(ctx.url, "tasks/cancel", %{"id" => task_id}, "tok-alice")

      done = Task.await(slow, 10_000)

      assert %{"result" => %{"task" => %{"status" => %{"state" => "TASK_STATE_COMPLETED"}}}} =
               done

      assert %{"slept" => 1200} = artifact_data(done)

      assert %{"result" => %{"status" => %{"state" => "TASK_STATE_COMPLETED"}}} =
               rpc_json(ctx.url, "tasks/get", %{"id" => task_id}, "tok-alice")
    end

    test "an anonymous caller cannot enumerate other anonymous callers' tasks" do
      ctx = start_http!(TransportCourt.CrashAgent, auth?: false)
      first = send_msg(ctx.url, "whoami", %{}, nil)
      assert %{"result" => %{"task" => %{"id" => task_id}}} = first

      assert %{"result" => %{"tasks" => []}} = rpc_json(ctx.url, "tasks/list", %{}, nil)

      # The unguessable id it was handed still addresses the task.
      assert %{"result" => %{"id" => ^task_id}} =
               rpc_json(ctx.url, "tasks/get", %{"id" => task_id}, nil)
    end

    test "command-bus refusal shapes never carry reason/receipt/nested structs onto the wire" do
      lost = %{
        code: :dispatch_lost,
        detail: "dispatch process died without replying; outcome unknown",
        reason: "{%RuntimeError{message: \"SELECT password FROM users\"}, []}"
      }

      assert AshA2A.Transport.SafeError.redact(lost) == %{code: :dispatch_lost}

      refused = %{code: :actuation_store_unavailable, receipt: %URI{userinfo: "u:secret"}}
      assert AshA2A.Transport.SafeError.redact(refused) == %{code: :actuation_store_unavailable}

      nested = %{code: :x, errors: [%{detail: "sql"}, {:y, "pg: z"}, self()]}

      assert AshA2A.Transport.SafeError.redact(nested) ==
               %{code: :x, errors: [%{}, {:y, :redacted}, :redacted]}
    end

    test "the same subject from two issuers is two principals" do
      a = AshA2A.Transport.Principal.key(%{sub: "alice", iss: "https://idp-a"})
      b = AshA2A.Transport.Principal.key(%{sub: "alice", iss: "https://idp-b"})
      refute a == b
    end
  end

  # ===========================================================================
  # TCK-driven transport pins (wrap-up of the Z19 TCK fixes over
  # `AshA2A.Transport.Plug`): the A2A-Version gate (TCK VER-SERVER-002),
  # `tasks/resubscribe` not-found (TCK STREAM-SUB-004), and agent-card
  # caching headers (TCK CARD-CACHE-001). Real HTTP through the real
  # `AshA2A.Transport.Plug`, real agent GenServers, zero mocks.
  # ===========================================================================
  describe "TCK-driven transport pins: version gate, resubscribe not-found, card caching headers" do
    @describetag :serial
    setup do
      start_http!(TransportCourt.Agent)
    end

    @tag :serial
    test "(VER-SERVER-002) A2A-Version 9.9 is refused -32009 VERSION_NOT_SUPPORTED",
         %{url: url} do
      resp =
        Req.post!(url,
          json: %{
            "jsonrpc" => "2.0",
            "id" => 1,
            "method" => "message/send",
            "params" => %{"message" => message("whoami", %{})}
          },
          headers: [{"authorization", "Bearer tok-alice"}, {"a2a-version", "9.9"}],
          retry: false,
          receive_timeout: 15_000,
          decode_body: false
        )

      assert resp.status == 200

      assert %{
               "error" => %{
                 "code" => -32_009,
                 "message" => "Version not supported",
                 "data" => [
                   %{
                     "@type" => @error_info_type,
                     "domain" => @a2a_domain,
                     "reason" => "VERSION_NOT_SUPPORTED",
                     "metadata" => %{"detail" => "9.9"}
                   }
                 ]
               }
             } = Jason.decode!(resp.body)

      # Fixed (coordinator): the rejection path now echoes the rejected
      # version in the `a2a-version` response header too (spec §3.6.2).
      assert Req.Response.get_header(resp, "a2a-version") == ["9.9"]
    end

    @tag :serial
    test "(VER-SERVER-002) an absent A2A-Version header is tolerated at the default and echoes 0.3",
         %{url: url} do
      resp = rpc(url, "message/send", %{"message" => message("whoami", %{})}, "tok-alice")

      assert %{"result" => %{"task" => %{"id" => _, "status" => _}}} =
               Jason.decode!(resp.body)

      assert Enum.join(Req.Response.get_header(resp, "a2a-version"), "") == "0.3"
    end

    @tag :serial
    test "(STREAM-SUB-004) tasks/resubscribe: unknown task is -32001",
         %{url: url} do
      unknown = task_not_found_info()

      assert %{"error" => %{"code" => -32_001, "data" => [^unknown]}} =
               rpc_json(url, "tasks/resubscribe", %{"id" => "tsk-unknown"}, "tok-alice")

      # Owned-task resubscribe now streams (snapshot, lastSeenGeneration); covered by
      # test/generation_gating_courts_test.exs.
    end

    @tag :serial
    test "(CARD-CACHE-001) the agent card serves Cache-Control max-age=60, ETag and Last-Modified",
         %{url: url} do
      resp = Req.get!(url <> "/.well-known/agent-card.json", retry: false)

      assert resp.status == 200
      assert Enum.join(Req.Response.get_header(resp, "cache-control"), "") == "max-age=60"

      assert [etag] = Req.Response.get_header(resp, "etag")
      assert String.starts_with?(etag, "\"") and String.ends_with?(etag, "\"")

      assert [_last_modified] = Req.Response.get_header(resp, "last-modified")
    end
  end

  # ===========================================================================
  # TCK-driven transport pins (lane G-F wrap-up of the Z19 TCK follow-up):
  # A2A v1.0 SendMessageResponse is a Task/Message oneof — a `{:message,
  # parts}` handler reply answers message/send with a bare Message (TCK
  # DM-MSG-001), and artifact parts carry the flat v1.0 part shapes (TCK
  # DM-ART-001). Real HTTP through the real `AshA2A.Transport.Plug`, real
  # agent GenServers, zero mocks.
  # ===========================================================================
  describe "TCK-driven transport pins: direct Message reply and typed artifact parts" do
    @describetag :serial
    setup do
      start_http!(TransportCourt.MessageAgent)
    end

    @tag :serial
    test "(DM-MSG-001) a `{:message, parts}` handler reply is a bare Message result, not a task",
         %{url: url} do
      assert %{
               "result" => %{
                 "message" => %{
                   "role" => "ROLE_AGENT",
                   "messageId" => message_id,
                   "parts" => [%{"text" => "Direct message response"}]
                 }
               }
             } = send_msg(url, "dm", %{}, "tok-alice")

      assert is_binary(message_id) and message_id != ""
      refute match?(%{"result" => %{"task" => _}}, send_msg(url, "dm", %{}, "tok-alice"))
    end

    @tag :serial
    test "(DM-ART-001) file artifact parts carry the flat v1.0 file shape (raw/filename/mediaType)",
         %{url: url} do
      assert %{
               "result" => %{
                 "task" => %{
                   "artifacts" => [
                     %{
                       "artifactId" => artifact_id,
                       "parts" => [
                         %{"raw" => raw, "filename" => "output.txt", "mediaType" => "text/plain"}
                       ]
                     }
                   ]
                 }
               }
             } = send_msg(url, "file-artifact", %{}, "tok-alice")

      assert is_binary(artifact_id) and artifact_id != ""
      assert is_binary(raw)
    end

    @tag :serial
    test "(DM-MSG-001) the direct-message task is finalized completed server-side, never stranded working",
         %{url: url} do
      # The transport runtime persists the turn's task before the handler
      # runs; after a `{:message, parts}` reply it must be terminal, and the
      # wire answer is still the bare Message.
      assert %{"result" => %{"message" => %{}}} = send_msg(url, "dm", %{}, "tok-alice")

      tasks =
        url
        |> rpc_json("tasks/list", %{}, "tok-alice")
        |> then(fn %{"result" => %{"tasks" => tasks}} -> tasks end)

      assert tasks != []

      assert Enum.all?(tasks, fn task ->
               task["status"]["state"] in ["TASK_STATE_COMPLETED", "TASK_STATE_INPUT_REQUIRED"]
             end)
    end
  end

  doctest AshA2A.Transport.Principal
  doctest AshA2A.Transport.SafeError

  describe "principal keys" do
    test "keyed by subject claim, stable across token refresh, never containing credentials" do
      a1 = AshA2A.Transport.Principal.key(%{sub: "alice", token: "t1", exp: 1})
      a2 = AshA2A.Transport.Principal.key(%{sub: "alice", token: "t2", exp: 2})
      assert a1 == a2
      refute a1 =~ "t1"
      assert "h:" <> _ = AshA2A.Transport.Principal.key(%{token: "only-a-token"})
      refute AshA2A.Transport.Principal.key(%{token: "only-a-token"}) =~ "only-a-token"
    end
  end
end
