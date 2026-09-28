defmodule AshA2AA2AMethodsTest do
  @moduledoc """
  Per-method JSON-RPC conformance over the real `A2A.Plug` fronting a real
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
    %{agent: name, plug_opts: A2A.Plug.init(agent: name, base_url: "http://localhost:4000/a2a")}
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
    |> A2A.Plug.call(plug_opts)
  end

  defp message do
    {:ok, encoded} = A2A.JSON.encode(A2A.Message.new_user("hello"))
    encoded
  end

  test "message/send returns a task result", %{plug_opts: o} do
    conn = rpc(o, "message/send", %{"message" => message()})
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert %{"result" => %{"task" => %{"id" => id}}} = body
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

  test "tasks/cancel on an unknown id is a typed error, not success", %{plug_opts: o} do
    body =
      o |> rpc("tasks/cancel", %{"id" => "nope"}) |> Map.fetch!(:resp_body) |> Jason.decode!()

    assert %{"error" => %{"code" => code}} = body
    assert code in [-32001, -32002]
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

  # TQ-05: the vendored `A2A.Plug` answers `message/stream` for a
  # non-streaming skill with a `{:not_streaming, task}` JSON-RPC error, because
  # `A2A.stream/3` only accepts a `{:stream, enum}` handler reply. ash_a2a's
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

    assert %{"final" => true, "status" => %{"state" => state}} = List.last(events)
    assert state in ["TASK_STATE_COMPLETED", "TASK_STATE_FAILED"]
  end

  test "raw A2A.Plug message/stream on a non-streaming skill is the vendored JSON error",
       %{plug_opts: o} do
    conn = rpc(o, "message/stream", %{"message" => message()})
    assert [ct] = Plug.Conn.get_resp_header(conn, "content-type")
    assert ct =~ "application/json"
    assert %{"error" => %{"code" => -32603}} = Jason.decode!(conn.resp_body)
  end

  test "unknown method is -32601", %{plug_opts: o} do
    body = o |> rpc("no/such", %{}) |> Map.fetch!(:resp_body) |> Jason.decode!()
    assert %{"error" => %{"code" => -32601}} = body
  end
end
