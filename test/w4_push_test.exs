defmodule AshA2A.W4PushTest.Receiver do
  @moduledoc false
  # Real Bandit/Plug webhook receiver. Event `n` = 1 answers 500 on its first
  # two calls (when `flaky: true`), everything else answers `status` (default
  # 200). Forwards (n, call-count, status, headers) to the test pid.
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, %{test: test, counts: counts} = opts) do
    {:ok, body, conn} = read_body(conn)
    n = body |> Jason.decode!() |> Map.get("n")
    calls = Agent.get_and_update(counts, fn m -> c = Map.get(m, n, 0) + 1; {c, Map.put(m, n, c)} end)

    status =
      cond do
        Map.get(opts, :flaky, false) == true and n == 1 and calls <= 2 -> 500
        s = Map.get(opts, :status) -> s
        true -> 200
      end

    headers = if status == 429 or Map.get(opts, :retry_after), do: [{"retry-after", "0"}], else: []
    conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_resp_header(c, k, v) end)
    send(test, {:webhook, n, calls, status, conn.req_headers})
    send_resp(conn, status, "")
  end
end

defmodule AshA2A.W4PushTest.ReplyAgent do
  @moduledoc false
  use AshA2A.Protocol.Agent, name: "w4-push-reply", description: "replies ok"

  @impl AshA2A.Protocol.Agent
  def handle_message(_message, _context), do: {:reply, [AshA2A.Protocol.Part.Text.new("ok")]}
end

defmodule AshA2A.W4PushTest do
  @moduledoc """
  W4: push-notification conformance -- ordered delivery, auth schemes, v1 flat
  config shape, list pagination, retry classification, event-id header and
  port allowlist. Real transport, real Bandit receivers, no mocks, no sleeps.
  """
  use ExUnit.Case, async: true

  alias AshA2A.A2ATransport.{PushConfigStore, PushDelivery, PushQueue, TaskEvents, WebhookPolicy}
  alias AshA2A.A2ATransport.Plug, as: TransportPlug
  alias AshA2A.Test.EphemeralHttp
  alias AshA2A.W4PushTest.{Receiver, ReplyAgent}

  @push [
    allow_http: true,
    allow_cidrs: ["127.0.0.1/32"],
    max_attempts: 5,
    base_backoff_ms: 5,
    max_backoff_ms: 20
  ]

  setup do
    uniq = System.unique_integer([:positive])
    agent = :"w4_push_agent_#{uniq}"
    transport = :"w4_push_transport_#{uniq}"
    start_supervised!({ReplyAgent, name: agent})
    start_supervised!({AshA2A.A2ATransport, name: transport, push: @push})
    {:ok, counts} = Agent.start_link(fn -> %{} end)

    %{
      agent: agent,
      transport: transport,
      counts: counts,
      on:
        TransportPlug.init(
          agent: agent,
          base_url: "http://x/a2a",
          transport: transport,
          push_notifications: true
        )
    }
  end

  defp receiver(counts, extra \\ %{}),
    do: EphemeralHttp.start!({Receiver, Map.merge(%{test: self(), counts: counts}, extra)}).base_url <> "/hook"

  defp cfg(url, task_id, extra \\ %{}),
    do: Map.merge(%{id: "c1", task_id: task_id, url: url, token: nil, authentication: nil}, extra)

  defp rpc(opts, method, params) do
    body = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params})

    :post
    |> Plug.Test.conn("/", body)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> TransportPlug.call(opts)
    |> Map.fetch!(:resp_body)
    |> Jason.decode!()
  end

  defp new_task(opts) do
    {:ok, msg} = AshA2A.Protocol.JSON.encode(AshA2A.Protocol.Message.new_user("hello"))
    %{"result" => %{"task" => %{"id" => id}}} = rpc(opts, "message/send", %{"message" => msg})
    id
  end

  # -- G1: ordering ------------------------------------------------------------

  test "event 2 never overtakes event 1 while 1 is in retry backoff", ctx do
    url = receiver(ctx.counts, %{flaky: true})
    store = AshA2A.A2ATransport.push_store_name(ctx.transport)
    {:ok, _} = PushConfigStore.put(store, cfg(url, "ord-1"))

    1 = TaskEvents.publish(ctx.transport, "ord-1", "status-update", %{"n" => 1})
    2 = TaskEvents.publish(ctx.transport, "ord-1", "status-update", %{"n" => 2})

    assert_receive {:webhook, 1, 1, 500, _}, 3_000
    assert_receive {:webhook, 1, 2, 500, _}, 3_000
    assert_receive {:webhook, 1, 3, 200, _}, 3_000
    assert_receive {:webhook, 2, 1, 200, _}, 3_000
  end

  test "a head event that exhausts retries is recorded, then the next event proceeds", ctx do
    url = receiver(ctx.counts, %{status: 503})
    store = AshA2A.A2ATransport.push_store_name(ctx.transport)
    {:ok, _} = PushConfigStore.put(store, cfg(url, "ord-2"))

    TaskEvents.publish(ctx.transport, "ord-2", "status-update", %{"n" => 1})
    TaskEvents.publish(ctx.transport, "ord-2", "status-update", %{"n" => 2})

    for call <- 1..5, do: assert_receive({:webhook, 1, ^call, 503, _}, 3_000)
    assert_receive {:webhook, 2, 1, 503, _}, 3_000
  end

  test "PushQueue is FIFO per key and independent across keys" do
    me = self()

    start = fn job ->
      send(me, {:started, job})
      {:ok, make_ref()}
    end

    {pq, :ok} = PushQueue.enqueue(PushQueue.new(), :k, :a, start, 10)
    {pq, :ok} = PushQueue.enqueue(pq, :k, :b, start, 10)
    {pq, :ok} = PushQueue.enqueue(pq, :other, :x, start, 10)
    assert_received {:started, :a}
    assert_received {:started, :x}
    refute_received {:started, :b}

    [ref_a] = for {ref, :k} <- pq.refs, do: ref
    pq = PushQueue.down(pq, ref_a, start)
    assert_received {:started, :b}
    assert PushQueue.active_keys(pq) == 2
    {_pq, :dropped} = PushQueue.enqueue(Map.put(pq, :keys, %{k: {:queue.from_list([1, 2]), make_ref()}}), :k, :z, start, 2)
  end

  # -- G2: auth schemes --------------------------------------------------------

  defp deliver(ctx, auth, task_id \\ "auth-t") do
    url = receiver(ctx.counts)
    config = cfg(url, task_id, %{authentication: auth})
    :ok = PushDelivery.deliver(ctx.transport, config, %{"n" => 7}, 7, @push)
    assert_receive {:webhook, 7, 1, 200, headers}, 3_000
    headers
  end

  test "Basic, generic IANA, ApiKey and OAuth2 render the right headers", ctx do
    h = deliver(ctx, %{"schemes" => ["Basic"], "credentials" => "dTpw"})
    assert {"authorization", "Basic dTpw"} in h

    ctx2 = %{ctx | counts: elem(Agent.start_link(fn -> %{} end), 1)}
    h = deliver(ctx2, %{"scheme" => "Digest", "credentials" => "abc"})
    assert {"authorization", "Digest abc"} in h

    ctx3 = %{ctx | counts: elem(Agent.start_link(fn -> %{} end), 1)}
    h = deliver(ctx3, %{"schemes" => ["ApiKey"], "credentials" => "k-1"})
    assert {"x-api-key", "k-1"} in h

    ctx4 = %{ctx | counts: elem(Agent.start_link(fn -> %{} end), 1)}
    h = deliver(ctx4, %{"schemes" => ["OAuth2"], "credentials" => "tok"})
    assert {"authorization", "Bearer tok"} in h
  end

  test "set refuses mTLS and unknown schemes with typed codes, accepts Basic", %{on: on} do
    task_id = new_task(on)
    set = fn auth ->
      rpc(on, "tasks/pushNotificationConfig/set", %{
        "taskId" => task_id,
        "pushNotificationConfig" => %{"url" => "http://127.0.0.1:9/h", "authentication" => auth}
      })
    end

    # v1.1 errors carry google.rpc.ErrorInfo; the typed refusal code rides in
    # `metadata.detail`.
    typed = fn resp, code ->
      assert %{"error" => %{"code" => -32602, "data" => [%{"reason" => "INVALID_PARAMS", "metadata" => %{"detail" => d}}]}} =
               resp

      assert d =~ code
    end

    typed.(set.(%{"schemes" => ["mutualTLS"]}), "refused_push_auth_mtls")
    typed.(set.(%{"schemes" => ["Carrier-Pigeon"], "credentials" => "x"}), "refused_push_auth_scheme")

    assert %{"error" => %{"code" => -32602}} =
             set.(%{"schemes" => ["Basic"], "credentials" => "a\r\nX-Evil: 1"})

    assert %{"result" => _} = set.(%{"schemes" => ["Basic"], "credentials" => "dTpw"})
  end

  # -- G4: flat shape ----------------------------------------------------------

  test "set accepts the v1 flat shape and answers flat; nested stays nested", %{on: on} do
    task_id = new_task(on)

    assert %{"result" => %{"id" => "flat-1", "taskId" => ^task_id, "url" => "http://127.0.0.1:9/h", "token" => "t"} = r} =
             rpc(on, "tasks/pushNotificationConfig/set", %{
               "taskId" => task_id,
               "id" => "flat-1",
               "url" => "http://127.0.0.1:9/h",
               "token" => "t"
             })

    refute Map.has_key?(r, "pushNotificationConfig")

    assert %{"result" => %{"taskId" => ^task_id, "pushNotificationConfig" => %{"id" => "nest-1"}}} =
             rpc(on, "tasks/pushNotificationConfig/set", %{
               "taskId" => task_id,
               "pushNotificationConfig" => %{"id" => "nest-1", "url" => "http://127.0.0.1:9/h"}
             })
  end

  # -- G3: pagination ----------------------------------------------------------

  test "list pages with pageSize/pageToken; legacy list stays a bare list; bad token is -32602", %{on: on} do
    task_id = new_task(on)

    for i <- 1..3 do
      %{"result" => _} =
        rpc(on, "tasks/pushNotificationConfig/set", %{
          "taskId" => task_id,
          "pushNotificationConfig" => %{"id" => "p#{i}", "url" => "http://127.0.0.1:9/h"}
        })
    end

    assert %{"result" => %{"configs" => page1, "nextPageToken" => tok}} =
             rpc(on, "tasks/pushNotificationConfig/list", %{"id" => task_id, "pageSize" => 2})

    assert length(page1) == 2
    assert tok != ""

    assert %{"result" => %{"configs" => [_], "nextPageToken" => ""}} =
             rpc(on, "tasks/pushNotificationConfig/list", %{
               "id" => task_id,
               "pageSize" => 2,
               "pageToken" => tok
             })

    assert %{"result" => bare} = rpc(on, "tasks/pushNotificationConfig/list", %{"id" => task_id})
    assert is_list(bare) and length(bare) == 3

    assert %{"error" => %{"code" => -32602}} =
             rpc(on, "tasks/pushNotificationConfig/list", %{"id" => task_id, "pageToken" => "!!notatoken"})
  end

  # -- G5/G7 -------------------------------------------------------------------

  test "tenant is routing-only: it does not partition the config store", %{on: on} do
    task_id = new_task(on)

    %{"result" => _} =
      rpc(on, "tasks/pushNotificationConfig/set", %{
        "taskId" => task_id,
        "tenant" => "acme",
        "pushNotificationConfig" => %{"id" => "tn1", "url" => "http://127.0.0.1:9/h"}
      })

    assert %{"result" => %{"pushNotificationConfig" => %{"id" => "tn1"}}} =
             rpc(on, "tasks/pushNotificationConfig/get", %{
               "id" => task_id,
               "tenant" => "other",
               "pushNotificationConfigId" => "tn1"
             })
  end

  test "4xx (not 408/429) is not retried; 429 is retried", ctx do
    url = receiver(ctx.counts, %{status: 400})
    assert {:error, {:http_error, 400}} =
             PushDelivery.deliver(ctx.transport, cfg(url, "r4"), %{"n" => 1}, 1, @push)

    assert_received {:webhook, 1, 1, 400, _}
    refute_received {:webhook, 1, 2, _, _}

    {:ok, c2} = Agent.start_link(fn -> %{} end)
    url2 = receiver(c2, %{status: 429})
    assert {:error, {:http_error, 429}} =
             PushDelivery.deliver(ctx.transport, cfg(url2, "r5"), %{"n" => 1}, 1, Keyword.put(@push, :max_attempts, 3))

    for call <- 1..3, do: assert_received({:webhook, 1, ^call, 429, _})
  end

  test "Retry-After parses delta-seconds and rejects garbage" do
    assert PushDelivery.parse_retry_after("2") == 2000
    assert PushDelivery.parse_retry_after("0") == 0
    assert PushDelivery.parse_retry_after("soon") == nil
    assert PushDelivery.parse_retry_after(nil) == nil
  end

  test "x-a2a-event-id carries task id and seq, stable across configs", ctx do
    url = receiver(ctx.counts)
    :ok = PushDelivery.deliver(ctx.transport, cfg(url, "evt-task"), %{"n" => 7}, 7, @push)
    assert_receive {:webhook, 7, 1, 200, headers}, 3_000
    assert {"x-a2a-event-id", "evt-task:7"} in headers
    assert {"x-a2a-delivery-id", "evt-task:c1:7"} in headers
  end

  test ":allow_ports restricts destination ports; default is unrestricted" do
    base = [allow_http: true, allow_cidrs: ["127.0.0.1/32"]]
    assert {:ok, _} = WebhookPolicy.admit("http://127.0.0.1:8123/h", base)
    assert {:ok, _} = WebhookPolicy.admit("http://127.0.0.1:8123/h", base ++ [allow_ports: [8123]])

    assert {:error, :refused_webhook_port, _} =
             WebhookPolicy.admit("http://127.0.0.1:8123/h", base ++ [allow_ports: [443]])
  end
end
