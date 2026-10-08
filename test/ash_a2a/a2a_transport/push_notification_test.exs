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
               "data" => [%{"domain" => "a2a-protocol.org", "reason" => "PUSH_NOTIFICATION_NOT_SUPPORTED"}]
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
