# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.TransportLane17.StreamAgent do
  @moduledoc false
  # Real AshA2A.Protocol.Agent GenServer whose handle_message/2 returns a lazy
  # three-part stream (no sleeps: the parts are produced as fast as pumped).
  use AshA2A.Protocol.Agent, name: "lane17-stream", description: "streams three parts"

  @impl AshA2A.Protocol.Agent
  def handle_message(_message, _context) do
    {:stream, Stream.map(1..3, fn i -> AshA2A.Protocol.Part.Text.new("part #{i}") end)}
  end
end

defmodule AshA2A.TransportLane17.RPCTest do
  @moduledoc """
  Lane 17 courts for `AshA2A.A2ATransport.Plug` / `PushConfigRPC` / `SSE` /
  `PushConfigStore` / `TaskEvents`, over real `Plug.Test` conns, a real
  `AshA2A.A2ATransport` supervision tree and a real streaming
  `AshA2A.Protocol.Agent`. No mocks, no sleeps.
  """

  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias AshA2A.A2ATransport
  alias AshA2A.A2ATransport.{PushConfigStore, SSE, TaskEvents}
  alias AshA2A.TransportLane17.StreamAgent

  def public_resolver(_host, _family), do: {:ok, [{93, 184, 216, 34}]}

  setup do
    uniq = System.unique_integer([:positive])
    agent = :"lane17_stream_#{uniq}"
    transport = :"lane17_transport_#{uniq}"
    start_supervised!({StreamAgent, name: agent})

    start_supervised!(
      {A2ATransport,
       name: transport, push: [resolver: &__MODULE__.public_resolver/2, signing_secret: "s"]}
    )

    plug =
      AshA2A.A2ATransport.Plug.init(
        agent: agent,
        base_url: "http://x/a2a",
        transport: transport,
        push_notifications: true,
        max_body_bytes: 4_096,
        max_idle_ms: 200,
        heartbeat_ms: 50
      )

    %{agent: agent, transport: transport, plug: plug}
  end

  defp message do
    {:ok, encoded} = AshA2A.Protocol.JSON.encode(AshA2A.Protocol.Message.new_user("go"))
    encoded
  end

  defp rpc(plug, method, params, headers \\ []) do
    body = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params})

    conn =
      Enum.reduce(headers, conn(:post, "/", body), fn {k, v}, c -> put_req_header(c, k, v) end)
      |> put_req_header("content-type", "application/json")

    AshA2A.A2ATransport.Plug.call(conn, plug)
  end

  defp decode(conn), do: Jason.decode!(conn.resp_body)

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

  describe "version/extension gate on locally-handled methods (finding 2)" do
    test "tasks/list, tasks/resubscribe, push and extended-card paths answer -32009", %{plug: plug} do
      for {method, params} <- [
            {"tasks/list", %{}},
            {"tasks/resubscribe", %{"id" => "t1"}},
            {"tasks/pushNotificationConfig/list", %{"taskId" => "t1", "id" => "t1"}},
            {"agent/getAuthenticatedExtendedCard", %{}},
            {"message/stream", %{"message" => message()}}
          ] do
        conn = rpc(plug, method, params, [{"a2a-version", "9.9"}])
        assert %{"error" => %{"code" => -32_009}} = decode(conn), "method #{method}"
      end
    end

    test "a supported version passes and is echoed", %{plug: plug} do
      conn = rpc(plug, "tasks/list", %{}, [{"a2a-version", "1.0"}])
      assert get_resp_header(conn, "a2a-version") == ["1.0"]
    end

    test "unknown message/* method is -32601, not a crash", %{plug: plug} do
      conn = rpc(plug, "message/bogus", %{"message" => message()})
      assert %{"error" => %{"code" => -32_601}} = decode(conn)
    end

    test "authorize_task applies to task-naming paths this plug answers itself", %{
      agent: agent,
      transport: transport
    } do
      plug =
        AshA2A.A2ATransport.Plug.init(
          agent: agent,
          base_url: "http://x/a2a",
          transport: transport,
          push_notifications: true,
          authorize_task: fn _op, _task -> false end
        )

      created = rpc(plug, "message/send", %{"message" => message()})
      id = get_in(decode(created), ["result", "task", "id"])
      assert is_binary(id)

      for {method, params} <- [
            {"tasks/get", %{"id" => id}},
            {"tasks/pushNotificationConfig/list", %{"id" => id, "taskId" => id}}
          ] do
        assert %{"error" => %{"code" => -32_001}} = decode(rpc(plug, method, params)),
               "method #{method}"
      end
    end
  end

  describe "body handling (finding 2)" do
    test "an over-cap body is a typed -32600 error and leaks no inspect(reason)", %{plug: plug} do
      big = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tasks/list", "params" => %{"pad" => String.duplicate("x", 9_000)}})

      conn =
        conn(:post, "/", big)
        |> put_req_header("content-type", "application/json")
        |> then(&AshA2A.A2ATransport.Plug.call(&1, plug))

      assert %{"error" => %{"code" => -32_600}} = decode(conn)
    end
  end

  describe "push config RPC bounds (finding 7)" do
    setup %{agent: agent, plug: plug} do
      created = rpc(plug, "message/send", %{"message" => message()})
      id = get_in(decode(created), ["result", "task", "id"]) || create_via_stream(plug)
      %{task_id: id, agent: agent}
    end

    defp create_via_stream(plug) do
      conn = rpc(plug, "message/stream", %{"message" => message()})
      [%{"task" => %{"id" => id}} | _] = frames(conn.resp_body)
      id
    end

    defp set(plug, task_id, config),
      do: decode(rpc(plug, "tasks/pushNotificationConfig/set", %{"taskId" => task_id, "pushNotificationConfig" => config}))

    test "id, url, token, authentication are type- and length-bounded", %{plug: plug, task_id: id} do
      ok = %{"url" => "https://hook.example/cb"}
      assert %{"result" => _} = set(plug, id, ok)

      bad = [
        Map.put(ok, "id", %{"nested" => 1}),
        Map.put(ok, "id", String.duplicate("a", 500)),
        Map.put(ok, "id", "has space"),
        %{"url" => "https://hook.example/" <> String.duplicate("a", 3_000)},
        Map.put(ok, "token", String.duplicate("t", 2_000)),
        Map.put(ok, "token", 12),
        Map.put(ok, "authentication", %{"schemes" => "Bearer"}),
        Map.put(ok, "authentication", %{"schemes" => []}),
        Map.put(ok, "authentication", %{"schemes" => [1]}),
        Map.put(ok, "authentication", %{"schemes" => ["Bearer"], "credentials" => 5})
      ]

      for config <- bad do
        assert %{"error" => %{"code" => -32_602}} = set(plug, id, config),
               "expected -32602 for #{inspect(config)}"
      end

      good_auth = Map.put(ok, "authentication", %{"schemes" => ["Bearer"], "credentials" => "c"})
      assert %{"result" => result} = set(plug, id, good_auth)
      refute inspect(result) =~ "credentials"
    end
  end

  describe "SSE (finding 5)" do
    test "message/stream continuing an unknown task preserves a typed error code", %{plug: plug} do
      msg = Map.put(message(), "taskId", "tsk-does-not-exist")
      conn = rpc(plug, "message/stream", %{"message" => msg})
      assert %{"error" => %{"code" => code}} = decode(conn)
      assert code in [-32_001, -32_602, -32_000]
    end

    test "streamed parts share ONE artifact: first create, rest append, lastChunk only on the final chunk", %{plug: plug} do
      conn = rpc(plug, "message/stream", %{"message" => message()})
      all = frames(conn.resp_body)

      artifacts = for %{"artifactUpdate" => a} <- all, do: a
      assert length(artifacts) == 3
      assert artifacts |> Enum.map(& &1["artifact"]["artifactId"]) |> Enum.uniq() |> length() == 1
      assert Enum.map(artifacts, &(&1["append"] == true)) == [false, true, true]
      assert Enum.map(artifacts, &(&1["lastChunk"] == true)) == [false, false, true]

      assert %{"statusUpdate" => %{"status" => %{"state" => "TASK_STATE_COMPLETED"}}} = List.last(all)
    end
  end

  describe "PushConfigStore / TaskEvents sweep (finding 7)" do
    test "delete_task removes every config of the task and only that task", %{transport: transport} do
      store = A2ATransport.push_store_name(transport)
      cfg = fn task, id -> %{id: id, task_id: task, url: "https://h.example/#{id}", token: nil, authentication: nil} end

      {:ok, _} = PushConfigStore.put(store, cfg.("ta", "1"))
      {:ok, _} = PushConfigStore.put(store, cfg.("ta", "2"))
      {:ok, _} = PushConfigStore.put(store, cfg.("tb", "1"))

      assert :ok = PushConfigStore.delete_task(store, "ta")
      assert PushConfigStore.list(store, "ta") == []
      assert [%{id: "1"}] = PushConfigStore.list(store, "tb")
    end

    test "a terminal task's configs are swept with its event log", _ctx do
      uniq = System.unique_integer([:positive])
      transport = :"lane17_sweep_#{uniq}"

      start_supervised!(
        {A2ATransport, name: transport, retention_ms: 1, push: [resolver: &__MODULE__.public_resolver/2]},
        id: :sweep_transport
      )

      store = A2ATransport.push_store_name(transport)
      task_id = "tsk-sweep-#{uniq}"
      {:ok, _} = PushConfigStore.put(store, %{id: "c", task_id: task_id, url: "https://h.example/c", token: nil, authentication: nil})

      final = %{"statusUpdate" => %{"taskId" => task_id, "final" => true, "status" => %{"state" => "TASK_STATE_COMPLETED"}}}
      TaskEvents.publish(transport, task_id, "status-update", final, true)

      deadline = System.monotonic_time(:millisecond) + 5_000
      assert eventually(deadline, fn -> PushConfigStore.list(store, task_id) == [] end)
    end

    test "an input-required final event does NOT sweep configs (task can resume)", _ctx do
      uniq = System.unique_integer([:positive])
      transport = :"lane17_sweep2_#{uniq}"

      start_supervised!(
        {A2ATransport, name: transport, retention_ms: 1, push: [resolver: &__MODULE__.public_resolver/2]},
        id: :sweep_transport2
      )

      store = A2ATransport.push_store_name(transport)
      task_id = "tsk-paused-#{uniq}"
      {:ok, _} = PushConfigStore.put(store, %{id: "c", task_id: task_id, url: "https://h.example/c", token: nil, authentication: nil})

      paused = %{"statusUpdate" => %{"taskId" => task_id, "final" => true, "status" => %{"state" => "TASK_STATE_INPUT_REQUIRED"}}}
      TaskEvents.publish(transport, task_id, "status-update", paused, true)

      # The log sweep is observable (backlog empties); the configs must remain.
      deadline = System.monotonic_time(:millisecond) + 5_000
      assert eventually(deadline, fn -> TaskEvents.backlog(transport, task_id) == [] end)
      assert [%{id: "c"}] = PushConfigStore.list(store, task_id)
    end
  end

  describe "SSE.stream_error/1 typed mapping (finding 5)" do
    test "typed errors survive; unknown reasons are -32000 with a ref and no detail" do
      assert %{code: -32_001} = SSE.stream_error({:error, :not_found})
      assert %{code: -32_004} = SSE.stream_error({:not_streaming, %{secret: "x"}})

      assert %{code: -32_000, data: data} = SSE.stream_error({:pump_start_failed, {:error, :max_children}})
      assert %{"ref" => _} = data
      refute inspect(data) =~ "max_children"
    end
  end

  # Bounded poll on a real observable: deadline-checked, no fixed sleeps.
  defp eventually(deadline, fun) do
    cond do
      fun.() -> true
      System.monotonic_time(:millisecond) > deadline -> false
      true ->
        :erlang.yield()
        eventually(deadline, fun)
    end
  end
end
