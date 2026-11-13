defmodule AshA2A.PushConfigProtocolVersionTest.Receiver do
  @moduledoc false
  # Real Bandit/Plug webhook receiver: forwards {:hook, tag, decoded_body} to
  # the test process.
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, %{test: test, tag: tag}) do
    {:ok, body, conn} = read_body(conn)
    send(test, {:hook, tag, Jason.decode!(body)})
    send_resp(conn, 200, "")
  end
end

defmodule AshA2A.PushConfigProtocolVersionTest.ReplyAgent do
  @moduledoc false
  use AshA2A.Protocol.Agent, name: "v4-push-reply", description: "replies ok"

  @impl AshA2A.Protocol.Agent
  def handle_message(_message, _context), do: {:reply, [AshA2A.Protocol.Part.Text.new("ok")]}
end

defmodule AshA2A.PushConfigProtocolVersionTest do
  @moduledoc """
  V4: push `protocol_version` honoured per config. Real transport, real Bandit
  receivers, deadlines not sleeps.
  """
  use ExUnit.Case, async: true

  alias AshA2A.A2ATransport.{PushConfigStore, PushDelivery, TaskEvents}
  alias AshA2A.A2ATransport.Plug, as: TransportPlug
  alias AshA2A.Test.EphemeralHttp
  alias AshA2A.PushConfigProtocolVersionTest.{Receiver, ReplyAgent}

  @push [
    allow_http: true,
    allow_cidrs: ["127.0.0.1/32"],
    max_attempts: 3,
    base_backoff_ms: 5,
    max_backoff_ms: 20
  ]

  setup do
    uniq = System.unique_integer([:positive])
    agent = :"v4_push_agent_#{uniq}"
    transport = :"v4_push_transport_#{uniq}"
    start_supervised!({ReplyAgent, name: agent})
    start_supervised!({AshA2A.A2ATransport, name: transport, push: @push})

    %{
      agent: agent,
      transport: transport,
      tid: "v4-push-#{uniq}",
      store: AshA2A.A2ATransport.push_store_name(transport),
      on:
        TransportPlug.init(
          agent: agent,
          base_url: "http://x/a2a",
          transport: transport,
          push_notifications: true
        )
    }
  end

  defp receiver(tag),
    do: EphemeralHttp.start!({Receiver, %{test: self(), tag: tag}}).base_url <> "/hook"

  defp cfg(id, url, tid, version),
    do: %{
      id: id,
      task_id: tid,
      url: url,
      token: nil,
      authentication: nil,
      protocol_version: version
    }

  defp rpc(opts, method, params, headers \\ []) do
    body = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params})

    conn =
      :post
      |> Plug.Test.conn("/", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")

    conn = Enum.reduce(headers, conn, fn {k, v}, c -> Plug.Conn.put_req_header(c, k, v) end)
    conn |> TransportPlug.call(opts) |> Map.fetch!(:resp_body) |> Jason.decode!()
  end

  defp su(tid),
    do: %{"statusUpdate" => %{"taskId" => tid, "status" => %{"state" => "TASK_STATE_WORKING"}}}

  test "payload_for/3 shapes by protocol_version" do
    payload = %{"statusUpdate" => %{"taskId" => "t", "generation" => 5}}

    assert {:ok, %{"statusUpdate" => inner}} =
             PushDelivery.payload_for(%{protocol_version: "1.0"}, "status-update", payload)

    refute Map.has_key?(inner, "generation")

    assert {:ok, ^payload} =
             PushDelivery.payload_for(%{protocol_version: "1.1"}, "status-update", payload)

    assert :skip = PushDelivery.payload_for(%{protocol_version: "1.0"}, "message-update", %{})
    assert :skip = PushDelivery.payload_for(%{}, "message-update", %{})

    assert {:ok, %{}} =
             PushDelivery.payload_for(%{protocol_version: "1.1"}, "message-update", %{})
  end

  test "1.0 config gets no generation / message-update; 1.1 config gets both, in generation order",
       ctx do
    {:ok, _} = PushConfigStore.put(ctx.store, cfg("c10", receiver(:v10), ctx.tid, "1.0"))
    {:ok, _} = PushConfigStore.put(ctx.store, cfg("c11", receiver(:v11), ctx.tid, "1.1"))

    TaskEvents.publish(ctx.transport, ctx.tid, "status-update", su(ctx.tid))

    TaskEvents.publish(
      ctx.transport,
      ctx.tid,
      "message-update",
      %{"messageUpdate" => %{"taskId" => ctx.tid, "message" => %{"messageId" => "m1"}}}
    )

    TaskEvents.publish(ctx.transport, ctx.tid, "status-update", su(ctx.tid))

    assert_receive {:hook, :v11, %{"statusUpdate" => s1}}, 5_000
    assert_receive {:hook, :v11, %{"messageUpdate" => m}}, 5_000
    assert_receive {:hook, :v11, %{"statusUpdate" => s2}}, 5_000
    assert s1["generation"] < m["generation"]
    assert m["generation"] < s2["generation"]

    assert_receive {:hook, :v10, %{"statusUpdate" => l1}}, 5_000
    assert_receive {:hook, :v10, %{"statusUpdate" => l2}}, 5_000
    refute Map.has_key?(l1, "generation")
    refute Map.has_key?(l2, "generation")
    # v11 has seen all three, so a message-update bound for v10 would have been queued by now.
    refute_received {:hook, :v10, %{"messageUpdate" => _}}
  end

  test "set/get/list encode protocolVersion; explicit wins, default is the request version",
       ctx do
    {:ok, msg} = AshA2A.Protocol.JSON.encode(AshA2A.Protocol.Message.new_user("hello"))
    %{"result" => %{"task" => %{"id" => tid}}} = rpc(ctx.on, "message/send", %{"message" => msg})
    url = receiver(:rpc)

    %{"result" => explicit} =
      rpc(ctx.on, "tasks/pushNotificationConfig/set", %{
        "taskId" => tid,
        "id" => "e1",
        "url" => url,
        "protocolVersion" => "1.1"
      })

    assert explicit["protocolVersion"] == "1.1"

    %{"result" => default} =
      rpc(
        ctx.on,
        "tasks/pushNotificationConfig/set",
        %{"taskId" => tid, "id" => "d1", "url" => url},
        [{"a2a-version", "1.0"}]
      )

    assert default["protocolVersion"] == "1.0"

    assert {:ok, %{protocol_version: "1.1"}} = PushConfigStore.get(ctx.store, tid, "e1")
    assert {:ok, %{protocol_version: "1.0"}} = PushConfigStore.get(ctx.store, tid, "d1")

    %{"error" => %{"code" => -32_602}} =
      rpc(ctx.on, "tasks/pushNotificationConfig/set", %{
        "taskId" => tid,
        "id" => "bad",
        "url" => url,
        "protocolVersion" => "nope"
      })
  end
end
