# NOTE: 20 module(s) removed from this consolidated file because the repaired originals (kept as separate files) define the same modules; see docs/reference/test-consolidation-merge.md.
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





# ==============================================================================
# SECTION 5 of 15: test/ash_a2a/a2a_transport/resubscribe_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT




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



# ==============================================================================
# SECTION 12 of 15: test/ash_a2a/protocol/stream_ordering_test.exs
# ==============================================================================

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT




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












