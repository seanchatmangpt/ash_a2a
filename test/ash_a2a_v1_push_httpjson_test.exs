defmodule AshA2A.Transport.HTTPJSON.PushHTTPJSONTest.Receiver do
  @moduledoc false
  # Real webhook receiver: forwards (method, headers, body) to the test pid and
  # answers 200. The body shape is re-asserted in the test process.
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, %{test: test}) do
    {:ok, body, conn} = read_body(conn)
    send(test, {:webhook, conn.method, conn.req_headers, body})
    send_resp(conn, 200, "")
  end
end

defmodule AshA2A.Transport.HTTPJSON.PushHTTPJSONTest.Probe do
  @moduledoc false
  # Real ETS-backed Ash resource with one real `:read` skill, for the
  # Ash-backed agent the HTTPJSON binding requires.
  use Ash.Resource,
    domain: AshA2A.Transport.HTTPJSON.PushHTTPJSONTest.Domain,
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

defmodule AshA2A.Transport.HTTPJSON.PushHTTPJSONTest.Domain do
  @moduledoc false

  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.Transport.HTTPJSON.PushHTTPJSONTest.Probe)
  end
end

defmodule AshA2A.Transport.HTTPJSON.PushHTTPJSONTest.HttpAgent do
  @moduledoc false
  # Real `AshA2A.Agent` GenServer: the agent kind `AshA2A.Transport.HTTPJSON`
  # requires (it answers `{:ash_a2a_get_task, principal, task_id}`, which the
  # bare `AshA2A.Protocol.Agent` does not implement).
  use AshA2A.Agent,
    resource_or_domain: AshA2A.Transport.HTTPJSON.PushHTTPJSONTest.Probe,
    name: "push_httpjson_http_agent"
end

defmodule AshA2A.Transport.HTTPJSON.PushHTTPJSONTest.ReplyAgent do
  @moduledoc false
  # Real AshA2A.Protocol.Agent GenServer that completes every message
  # synchronously (zero mocks).
  use AshA2A.Protocol.Agent, name: "push-httpjson-reply", description: "replies ok"

  @impl AshA2A.Protocol.Agent
  def handle_message(_message, _context), do: {:reply, [AshA2A.Protocol.Part.Text.new("ok")]}
end

defmodule AshA2A.Transport.HTTPJSON.PushHTTPJSONTest do
  @moduledoc """
  W6 court: `tasks/pushNotificationConfig` set/get/list/delete for the A2A
  v1.0 HTTP+JSON surface.

  ## REST routes are implemented (gap closed)

  `AshA2A.Transport.HTTPJSON` (lib/ash_a2a/transport/http_json.ex) implements
  the v1.0 REST push-notification-config routes:

      POST   /tasks/{id}/pushNotificationConfig          -> set
      GET    /tasks/{id}/pushNotificationConfig          -> list
      GET    /tasks/{id}/pushNotificationConfig/{cid}    -> get
      DELETE /tasks/{id}/pushNotificationConfig/{cid}    -> delete

  Each verb delegates to the very same `AshA2A.A2ATransport.PushConfigRPC`
  handler the `AshA2A.A2ATransport.Plug` JSON-RPC binding dispatches (against
  the named transport's real `PushConfigStore`), so the two bindings answer
  identical error envelopes by construction. These tests pin the REST surface
  positively: CRUD through the real store (write-only credentials never
  echoed), owner-scoped `-32001` -> 404 for unknown/foreign tasks, the typed
  SSRF refusal (`-32602` with the `refused_webhook_*` detail) via
  `AshA2A.A2ATransport.WebhookPolicy`, the `-32003` fail-closed envelope for
  every push verb when `push_notifications` is not enabled (never a 404), the
  405 method-discovery answers with `allow` headers, and one plain-404 control
  for a genuinely unknown path. The JSON-RPC half of the court (the same CRUD
  over the real `AshA2A.A2ATransport.Plug`, plus real signed webhook delivery)
  keeps running below -- no mocks anywhere.
  """

  use ExUnit.Case, async: true

  alias AshA2A.A2ATransport.{PushConfigStore, PushDelivery, TaskEvents}
  alias AshA2A.A2ATransport.Plug, as: TransportPlug
  alias AshA2A.Transport.HTTPJSON
  alias AshA2A.Transport.HTTPJSON.PushHTTPJSONTest.{HttpAgent, Receiver, ReplyAgent}
  alias AshA2A.Test.EphemeralHttp

  @error_info_type "type.googleapis.com/google.rpc.ErrorInfo"
  @secret "w6-push-httpjson-signing-secret"

  setup do
    uniq = System.unique_integer([:positive])
    agent = :"push_httpjson_reply_#{uniq}"
    transport = :"a2a_transport_push_httpjson_#{uniq}"
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

    # A real Ash-backed agent for the REST surface: push CRUD is owner-scoped
    # through the same agent the tasks were created on, so the REST tests
    # create their tasks through the HTTPJSON binding itself.
    rest_agent = :"push_httpjson_rest_agent_#{uniq}"
    start_supervised!({HttpAgent, name: rest_agent}, id: rest_agent)

    %{
      agent: agent,
      transport: transport,
      hook: hook.base_url <> "/hook",
      httpjson: HTTPJSON.init(agent: agent, base_url: "http://127.0.0.1:9/a2a"),
      httpjson_on:
        HTTPJSON.init(
          agent: rest_agent,
          base_url: "http://127.0.0.1:9/a2a",
          transport: transport,
          push_notifications: true
        ),
      httpjson_off: HTTPJSON.init(agent: rest_agent, base_url: "http://127.0.0.1:9/a2a"),
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

  # -- helpers -----------------------------------------------------------------

  defp httpjson_req(method, path, opts, body \\ nil) do
    conn = Plug.Test.conn(method, path, body)

    conn =
      if body,
        do: Plug.Conn.put_req_header(conn, "content-type", "application/json"),
        else: conn

    HTTPJSON.call(conn, opts)
  end

  defp httpjson_json(method, path, opts, body) do
    method
    |> Plug.Test.conn(path, Jason.encode!(body))
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> HTTPJSON.call(opts)
    |> Map.fetch!(:resp_body)
    |> Jason.decode!()
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

  defp wait_attempts(transport, task_id, n, tries \\ 100)

  defp wait_attempts(transport, task_id, n, tries) do
    attempts = TaskEvents.attempts(transport, task_id)

    cond do
      length(attempts) >= n ->
        attempts

      tries == 0 ->
        flunk("expected #{n} delivery attempts, got #{inspect(attempts)}")

      true ->
        Process.sleep(20)
        wait_attempts(transport, task_id, n, tries - 1)
    end
  end

  # -- the REST push-config routes (gap closed) ------------------------------------
  #
  # The four verbs are exercised through the real HTTPJSON binding, the real
  # transport's PushConfigStore, and a task created through the same binding --
  # the full REST pipeline, no mocks.

  defp rest_req(method, path, opts, body \\ nil) do
    conn = Plug.Test.conn(method, path, body && Jason.encode!(body))

    conn =
      if body,
        do: Plug.Conn.put_req_header(conn, "content-type", "application/json"),
        else: conn

    HTTPJSON.call(conn, opts)
  end

  defp rest_json(method, path, opts, body \\ nil) do
    method
    |> rest_req(path, opts, body)
    |> Map.fetch!(:resp_body)
    |> Jason.decode!()
  end

  defp rest_new_task(opts) do
    %{"task" => %{"id" => id}} = rest_json(:post, "/message:send", opts, %{"message" => message()})
    id
  end

  test "REST CRUD: set stores through the real store, get/list return it, credentials write-only", %{
    httpjson_on: rest,
    hook: hook,
    transport: transport
  } do
    task_id = rest_new_task(rest)

    set_body = %{
      "pushNotificationConfig" => %{
        "id" => "cfg-r1",
        "url" => hook,
        "token" => "tok-r1",
        "authentication" => %{"schemes" => ["Bearer"], "credentials" => "s3cret-r1"}
      }
    }

    expected = %{
      "taskId" => task_id,
      "pushNotificationConfig" => %{
        "id" => "cfg-r1",
        "url" => hook,
        "token" => "tok-r1",
        "authentication" => %{"schemes" => ["Bearer"]}
      }
    }

    conn = rest_req(:post, "/tasks/#{task_id}/pushNotificationConfig", rest, set_body)
    assert conn.status == 200
    assert conn |> Map.fetch!(:resp_body) |> Jason.decode!() == expected

    # The write-only credentials really were stored in the real store...
    {:ok, stored} =
      PushConfigStore.get(AshA2A.A2ATransport.push_store_name(transport), task_id, "cfg-r1")

    assert stored.authentication == %{"schemes" => ["Bearer"], "credentials" => "s3cret-r1"}

    # ...but are never echoed back by get or list (same envelope as JSON-RPC).
    assert rest_json(:get, "/tasks/#{task_id}/pushNotificationConfig/cfg-r1", rest) == expected
    assert rest_json(:get, "/tasks/#{task_id}/pushNotificationConfig", rest) == [expected]
  end

  test "REST CRUD: delete removes the config; a missing config answers the pinned -32602 envelope", %{
    httpjson_on: rest,
    hook: hook
  } do
    task_id = rest_new_task(rest)

    rest_req(:post, "/tasks/#{task_id}/pushNotificationConfig", rest, %{
      "pushNotificationConfig" => %{"id" => "cfg-r2", "url" => hook}
    })

    conn = rest_req(:delete, "/tasks/#{task_id}/pushNotificationConfig/cfg-r2", rest)
    assert conn.status == 200
    assert conn.resp_body == "null"

    assert rest_json(:get, "/tasks/#{task_id}/pushNotificationConfig", rest) == []

    # Missing config: the SAME -32602 ErrorInfo envelope the JSON-RPC binding
    # answers (PushConfigRPC's get/delete miss, "data" renamed "details").
    error = rest_json(:get, "/tasks/#{task_id}/pushNotificationConfig/cfg-r2", rest)

    assert %{
             "error" => %{
               "code" => 400,
               "message" => "Invalid parameters",
               "details" => [
                 %{
                   "@type" => @error_info_type,
                   "domain" => "a2a-protocol.org",
                   "reason" => "INVALID_PARAMS",
                   "metadata" => %{"detail" => "push notification config not found"}
                 }
               ]
             }
           } = error

    # Re-delete of the missing config: same envelope.
    assert %{"error" => %{"code" => 400}} =
             rest_json(:delete, "/tasks/#{task_id}/pushNotificationConfig/cfg-r2", rest)
  end

  test "REST CRUD: unknown task is 404 with the -32001 envelope (owner scope, never 403)", %{
    httpjson_on: rest,
    hook: hook
  } do
    conn =
      rest_req(:post, "/tasks/tsk-does-not-exist/pushNotificationConfig", rest, %{
        "pushNotificationConfig" => %{"id" => "cfg-x", "url" => hook}
      })

    assert conn.status == 404

    assert %{
             "error" => %{
               "code" => 404,
               "message" => "Task not found",
               "details" => [
                 %{"@type" => @error_info_type, "domain" => "a2a-protocol.org", "reason" => "TASK_NOT_FOUND"}
               ]
             }
           } = conn.resp_body |> Jason.decode!()
  end

  test "REST SSRF: a non-public webhook URL is refused with the typed detail and nothing is stored", %{
    httpjson_on: rest,
    hook: hook
  } do
    task_id = rest_new_task(rest)

    for {url, code, needle} <- [
          {"http://169.254.169.254/latest/meta-data", "refused_webhook_private_address",
           "169.254.169.254"},
          {"http://127.0.0.2:9/hook", "refused_webhook_private_address", "127.0.0.2"},
          {"ftp://example.com/hook", "refused_webhook_scheme", nil},
          {"http://user:pw@127.0.0.1/hook", "refused_webhook_malformed", nil}
        ] do
      conn =
        rest_req(:post, "/tasks/#{task_id}/pushNotificationConfig", rest, %{
          "pushNotificationConfig" => %{"id" => "cfg-ssrf", "url" => url}
        })

      assert conn.status == 400, url

      assert %{
               "error" => %{
                 "code" => 400,
                 "details" => [
                   %{
                     "@type" => @error_info_type,
                     "domain" => "a2a-protocol.org",
                     "reason" => "INVALID_PARAMS",
                     "metadata" => %{"detail" => detail}
                   }
                 ]
               }
             } = conn.resp_body |> Jason.decode!(), url

      assert detail =~ code, url
      if needle, do: assert(detail =~ needle, url)
    end

    # None of the refused configs were stored.
    assert rest_json(:get, "/tasks/#{task_id}/pushNotificationConfig", rest) == []
  end

  test "REST push disabled: every push route answers the -32003 envelope, never a 404", %{
    httpjson_off: rest
  } do
    for {method, path} <- [
          {:post, "/tasks/tsk-x/pushNotificationConfig"},
          {:get, "/tasks/tsk-x/pushNotificationConfig"},
          {:get, "/tasks/tsk-x/pushNotificationConfig/cfg-1"},
          {:delete, "/tasks/tsk-x/pushNotificationConfig/cfg-1"},
          {:post, "/tasks/tsk-x/pushNotificationConfigs"},
          {:get, "/tasks/tsk-x/pushNotificationConfigs"},
          {:get, "/tasks/tsk-x/pushNotificationConfigs/cfg-1"},
          {:delete, "/tasks/tsk-x/pushNotificationConfigs/cfg-1"}
        ] do
      conn = rest_req(method, path, rest)

      assert conn.status == 400, "#{method} #{path}"

      assert %{
               "error" => %{
                 "code" => 400,
                 "message" => "Push Notification is not supported",
                 "details" => [
                   %{
                     "@type" => @error_info_type,
                     "domain" => "a2a-protocol.org",
                     "reason" => "PUSH_NOTIFICATION_NOT_SUPPORTED"
                   }
                 ]
               }
             } = conn.resp_body |> Jason.decode!(), "#{method} #{path}"
    end
  end

  test "REST push routes answer 405 with an allow header on the wrong method", %{
    httpjson_on: rest,
    hook: hook
  } do
    task_id = rest_new_task(rest)

    conn = rest_req(:put, "/tasks/#{task_id}/pushNotificationConfig", rest)
    assert conn.status == 405
    assert conn |> Plug.Conn.get_resp_header("allow") == ["GET, POST"]

    conn = rest_req(:post, "/tasks/#{task_id}/pushNotificationConfig/cfg-1", rest)
    assert conn.status == 405
    assert conn |> Plug.Conn.get_resp_header("allow") == ["GET, DELETE"]
  end

  test "REST: a genuinely unknown path is still the plain catch-all 404", %{httpjson_off: rest} do
    conn = httpjson_req(:get, "/nothing/here", rest)

    assert conn.status == 404
    assert conn.resp_body == "Not Found"
    assert {:error, _} = Jason.decode(conn.resp_body)
    refute conn |> Plug.Conn.get_resp_header("allow") |> Enum.any?()
  end

  # -- (a) set -> stored, get returns it -----------------------------------------

  test "(a) set stores the config and get returns it (credentials write-only)",
       %{on: on, hook: hook, transport: transport} do
    task_id = new_task(on)

    set =
      rpc(on, "tasks/pushNotificationConfig/set", %{
        "taskId" => task_id,
        "pushNotificationConfig" => %{
          "id" => "cfg-a1",
          "url" => hook,
          "token" => "tok-a1",
          "authentication" => %{"schemes" => ["Bearer"], "credentials" => "s3cret-a1"}
        }
      })

    expected = %{
      "taskId" => task_id,
      "pushNotificationConfig" => %{
        "id" => "cfg-a1",
        "url" => hook,
        "token" => "tok-a1",
        "authentication" => %{"schemes" => ["Bearer"]}
      }
    }

    assert set["result"] == expected

    assert rpc(on, "tasks/pushNotificationConfig/get", %{
             "id" => task_id,
             "pushNotificationConfigId" => "cfg-a1"
           })["result"] == expected

    # The write-only credentials are stored for delivery but never echoed.
    assert is_nil(
             get_in(set, ["result", "pushNotificationConfig", "authentication", "credentials"])
           )

    # The credentials really were stored in the real store.
    {:ok, stored} =
      PushConfigStore.get(AshA2A.A2ATransport.push_store_name(transport), task_id, "cfg-a1")

    assert stored.authentication == %{"schemes" => ["Bearer"], "credentials" => "s3cret-a1"}
  end

  # -- (b) list contains it ---------------------------------------------------------

  test "(b) list contains the stored config", %{on: on, hook: hook} do
    task_id = new_task(on)

    expected = %{
      "taskId" => task_id,
      "pushNotificationConfig" => %{"id" => "cfg-b1", "url" => hook, "token" => "tok-b1"}
    }

    assert %{"result" => ^expected} =
             rpc(on, "tasks/pushNotificationConfig/set", %{
               "taskId" => task_id,
               "pushNotificationConfig" => %{
                 "id" => "cfg-b1",
                 "url" => hook,
                 "token" => "tok-b1"
               }
             })

    assert rpc(on, "tasks/pushNotificationConfig/list", %{"id" => task_id})["result"] == [
             expected
           ]

    # PascalCase v0.3 alias routes identically.
    assert rpc(on, "ListTaskPushNotificationConfigs", %{"id" => task_id})["result"] == [expected]
  end

  # -- (c) delete -> gone, get -> pinned not-found error -----------------------------

  test "(c) delete removes the config; get and re-delete answer the pinned not-found error",
       %{on: on, hook: hook} do
    task_id = new_task(on)

    rpc(on, "tasks/pushNotificationConfig/set", %{
      "taskId" => task_id,
      "pushNotificationConfig" => %{"id" => "cfg-c1", "url" => hook}
    })

    assert %{"result" => nil} =
             rpc(on, "tasks/pushNotificationConfig/delete", %{
               "id" => task_id,
               "pushNotificationConfigId" => "cfg-c1"
             })

    assert rpc(on, "tasks/pushNotificationConfig/list", %{"id" => task_id})["result"] == []

    # Pinned not-found error for a missing config: -32602 with the
    # ErrorInfo metadata detail "push notification config not found"
    # (PushConfigRPC's get/delete miss answer, verbatim).
    not_found = %{
      "code" => -32_602,
      "message" => "Invalid parameters",
      "data" => [
        %{
          "@type" => @error_info_type,
          "domain" => "a2a-protocol.org",
          "reason" => "INVALID_PARAMS",
          "metadata" => %{"detail" => "push notification config not found"}
        }
      ]
    }

    assert %{"error" => get_error} =
             rpc(on, "tasks/pushNotificationConfig/get", %{
               "id" => task_id,
               "pushNotificationConfigId" => "cfg-c1"
             })

    assert get_error == not_found

    assert %{"error" => delete_error} =
             rpc(on, "tasks/pushNotificationConfig/delete", %{
               "id" => task_id,
               "pushNotificationConfigId" => "cfg-c1"
             })

    assert delete_error == not_found
  end

  # -- (d) SSRF admission refusal with the typed detail --------------------------------

  test "(d) set with a non-public webhook URL is refused with the typed SSRF detail",
       %{on: on} do
    task_id = new_task(on)

    for {url, code, needle} <- [
          {"http://169.254.169.254/latest/meta-data", "refused_webhook_private_address",
           "169.254.169.254"},
          {"http://127.0.0.2:9/hook", "refused_webhook_private_address", "127.0.0.2"},
          {"ftp://example.com/hook", "refused_webhook_scheme", nil},
          {"http://user:pw@127.0.0.1/hook", "refused_webhook_malformed", nil}
        ] do
      resp =
        rpc(on, "tasks/pushNotificationConfig/set", %{
          "taskId" => task_id,
          "pushNotificationConfig" => %{"url" => url}
        })

      assert %{"error" => %{"code" => -32_602, "data" => [info]}} = resp, url

      assert %{
               "@type" => @error_info_type,
               "domain" => "a2a-protocol.org",
               "reason" => "INVALID_PARAMS",
               "metadata" => %{"detail" => detail}
             } = info

      assert detail =~ code, url
      if needle, do: assert(detail =~ needle, url)
    end

    # None of the refused configs were stored.
    assert rpc(on, "tasks/pushNotificationConfig/list", %{"id" => task_id})["result"] == []
  end

  # -- (e) disabled default -> -32003 PUSH_NOTIFICATION_NOT_SUPPORTED ------------------

  test "(e) push disabled by default: every push method and an inline config answer -32003",
       %{off: off} do
    for method <- ~w(set get list delete) do
      assert %{
               "error" => %{
                 "code" => -32_003,
                 "message" => "Push Notification is not supported",
                 "data" => [
                   %{
                     "@type" => @error_info_type,
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

    # An inline configuration.pushNotificationConfig on message/send is
    # refused -32003 too, not silently ignored.
    assert %{
             "error" => %{
               "code" => -32_003,
               "data" => [%{"reason" => "PUSH_NOTIFICATION_NOT_SUPPORTED"}]
             }
           } =
             rpc(off, "message/send", %{
               "message" => message(),
               "configuration" => %{
                 "pushNotificationConfig" => %{"url" => "https://example.com/hook"}
               }
             })
  end

  # -- (f) real webhook delivery on task completion --------------------------------------

  test "(f) message/send with an inline config delivers the wrapped v1.0 task to the real webhook",
       %{on: on, hook: hook, transport: transport} do
    params = %{
      "message" => message(),
      "configuration" => %{"pushNotificationConfig" => %{"url" => hook, "token" => "tok-f1"}}
    }

    %{"result" => %{"task" => %{"id" => task_id}}} = rpc(on, "message/send", params)

    assert_receive {:webhook, "POST", headers, body}, 5_000
    headers = Map.new(headers)

    assert headers["x-a2a-notification-token"] == "tok-f1"
    assert headers["content-type"] == "application/json"

    # Receiver-side HMAC verification against the real signing secret.
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

    # v1.0 StreamResponse wrapper from publish_result: `{"task" => ...}` with
    # the terminal wire state and no "final" boolean anywhere.
    decoded = Jason.decode!(body)

    assert %{
             "task" => %{
               "id" => ^task_id,
               "status" => %{"state" => "TASK_STATE_COMPLETED"}
             }
           } = decoded

    refute Map.has_key?(decoded, "final")
    refute body =~ ~s("final")

    # Exactly one real HTTP 200 delivery attempt was recorded.
    assert [%{attempt: 1, outcome: {:ok, 200}, config_id: cid}] =
             wait_attempts(transport, task_id, 1)

    assert {:ok, %{id: ^cid}} =
             PushConfigStore.get(AshA2A.A2ATransport.push_store_name(transport), task_id, cid)
  end
end
