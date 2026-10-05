# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2AA2AMethodsTest do
  @moduledoc """
  Per-method JSON-RPC conformance over the real `AshA2A.Protocol.Plug` fronting a real
  `AshA2A.Agent` GenServer (no mocks; real `Plug.Test` conns). Each test
  asserts the observed wire response of ONE A2A method. Methods the vendored
  `:a2a` Plug does not implement are asserted as the typed refusal it really
  returns (`-32004` unsupported operation), never as success.

  See `docs/reference/a2a-spec-version-mapping.md`.
  """
  use ExUnit.Case, async: true

  alias AshA2A.Test.PlugFixture.GreeterAgent

  setup do
    name = :"a2a_methods_agent_#{System.unique_integer([:positive])}"
    {:ok, pid} = GreeterAgent.start_link(name: name)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    %{agent: name, plug_opts: AshA2A.Protocol.Plug.init(agent: name, base_url: "http://localhost:4000/a2a")}
  end

  defp rpc(plug_opts, method, params) do
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
    |> AshA2A.Protocol.Plug.call(plug_opts)
  end

  defp message do
    {:ok, encoded} = AshA2A.Protocol.JSON.encode(AshA2A.Protocol.Message.new_user("hello"))
    encoded
  end

  test "message/send returns a task result", %{plug_opts: o} do
    conn = rpc(o, "message/send", %{"message" => message()})
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)

    # v1.0: the send result is the StreamResponse {"task": ...} wrapper; the
    # wrapped task carries no "kind" discriminator and flat {"text": ...}
    # parts.
    assert %{"result" => %{"task" => %{"id" => id} = task_json}} = body
    refute Map.has_key?(task_json, "kind")
    assert is_binary(id)
  end

  test "tasks/get returns the task created by message/send", %{plug_opts: o} do
    %{"result" => %{"task" => %{"id" => id}}} =
      o
      |> rpc("message/send", %{"message" => message()})
      |> Map.fetch!(:resp_body)
      |> Jason.decode!()

    body = o |> rpc("tasks/get", %{"id" => id}) |> Map.fetch!(:resp_body) |> Jason.decode!()
    assert %{"result" => %{"id" => ^id}} = body
  end

  test "tasks/get on an unknown id is -32001 task not found", %{plug_opts: o} do
    body = o |> rpc("tasks/get", %{"id" => "nope"}) |> Map.fetch!(:resp_body) |> Jason.decode!()
    assert %{"error" => %{"code" => -32001}} = body
  end

  test "tasks/cancel on an unknown id is -32001 task not found", %{plug_opts: o} do
    body =
      o |> rpc("tasks/cancel", %{"id" => "nope"}) |> Map.fetch!(:resp_body) |> Jason.decode!()

    assert %{"error" => %{"code" => -32001}} = body
  end

  test "tasks/cancel on a completed task is refused (not cancelable)", %{plug_opts: o} do
    %{"result" => %{"task" => %{"id" => id}}} =
      o
      |> rpc("message/send", %{"message" => message()})
      |> Map.fetch!(:resp_body)
      |> Jason.decode!()

    body = o |> rpc("tasks/cancel", %{"id" => id}) |> Map.fetch!(:resp_body) |> Jason.decode!()
    assert %{"error" => %{"code" => -32002}} = body
  end

  test "tasks/resubscribe is the vendored plug's typed unsupported-operation refusal", %{
    plug_opts: o
  } do
    body =
      o |> rpc("tasks/resubscribe", %{"id" => "x"}) |> Map.fetch!(:resp_body) |> Jason.decode!()

    assert %{"error" => %{"code" => -32004}} = body
  end

  test "agent/getAuthenticatedExtendedCard is the typed unsupported-operation refusal", %{
    plug_opts: o
  } do
    body =
      o
      |> rpc("agent/getAuthenticatedExtendedCard", %{})
      |> Map.fetch!(:resp_body)
      |> Jason.decode!()

    assert %{"error" => %{"code" => -32004}} = body
  end

  # TQ-05: the vendored `AshA2A.Protocol.Plug` answers `message/stream` for a
  # non-streaming skill with a `{:not_streaming, task}` JSON-RPC error, because
  # `AshA2A.Protocol.stream/3` only accepts a `{:stream, enum}` handler reply. ash_a2a's
  # own transport (`AshA2A.Transport.Plug`) streams every reply: the task
  # snapshot, one `artifact-update` per artifact, and a final status. This
  # test drives the same GreeterAgent through that transport; the raw-plug
  # behavior is pinned separately below so the difference stays visible.
  test "message/stream answers with an SSE event stream (AshA2A.Transport.Plug)", %{
    agent: agent
  } do
    opts = AshA2A.Transport.Plug.init(agent: agent, base_url: "http://localhost:4000/a2a")

    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "message/stream",
        "params" => %{"message" => message()}
      })

    conn =
      :post
      |> Plug.Test.conn("/", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> AshA2A.Transport.Plug.call(opts)

    assert [ct] = Plug.Conn.get_resp_header(conn, "content-type")
    assert ct =~ "text/event-stream"
    assert conn.resp_body =~ "data: "

    events =
      conn.resp_body
      |> String.split("\n\n", trim: true)
      |> Enum.map(fn "data: " <> json -> Jason.decode!(json)["result"] end)

    # v1.0 StreamResponse wire contract: every frame's `result` is wrapped as
    # exactly one {"task" | "statusUpdate" | "artifactUpdate" => ...} key — the
    # wrapper key is the discriminator; there is no "kind" and no "final"
    # boolean anywhere (finality is the last event's terminal TASK_STATE_*).
    assert events != []

    assert Enum.all?(events, fn event ->
             map_size(event) == 1 and
               (Map.has_key?(event, "task") or Map.has_key?(event, "statusUpdate") or
                  Map.has_key?(event, "artifactUpdate"))
           end)

    refute Enum.any?(events, fn
             %{"statusUpdate" => inner} -> Map.has_key?(inner, "final")
             _event -> false
           end)

    # Finality: the stream closes on the last event's terminal TASK_STATE_*;
    # the last frame is a statusUpdate carrying a terminal state.
    assert %{"statusUpdate" => %{"status" => %{"state" => state}}} = List.last(events)
    assert state in ["TASK_STATE_COMPLETED", "TASK_STATE_FAILED", "TASK_STATE_CANCELED"]
  end

  test "raw AshA2A.Protocol.Plug message/stream on a non-streaming skill is the vendored JSON error",
       %{plug_opts: o} do
    conn = rpc(o, "message/stream", %{"message" => message()})
    assert [ct] = Plug.Conn.get_resp_header(conn, "content-type")
    assert ct =~ "application/json"
    # 0.3 wire contract: a non-streaming skill rejects `message/stream` with
    # the typed -32004 UNSUPPORTED_OPERATION error (google.rpc.ErrorInfo data).
    assert %{"error" => %{"code" => -32004}} = Jason.decode!(conn.resp_body)
  end

  test "unknown method is -32601", %{plug_opts: o} do
    body = o |> rpc("no/such", %{}) |> Map.fetch!(:resp_body) |> Jason.decode!()
    assert %{"error" => %{"code" => -32601}} = body
  end
end
