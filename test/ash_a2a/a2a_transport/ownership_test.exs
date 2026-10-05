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

      conn = call(ctx, "alice", "tasks/resubscribe", %{"id" => task_id})
      assert conn.resp_body =~ task_id
      # v1.0 wire shape: finality rides on the terminal status state, not a
      # "final" boolean.
      assert conn.resp_body =~ ~s("state":"TASK_STATE_COMPLETED")
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
      assert resub.resp_body =~ task_id
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
