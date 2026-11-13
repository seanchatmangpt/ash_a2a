# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.W25HTTPJSON.Resource do
  @moduledoc "Real fixture: `:converse` parks in input_required when :text is omitted."

  use Ash.Resource,
    domain: AshA2A.W25HTTPJSON.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  actions do
    action :converse, :map do
      argument(:text, :string, allow_nil?: false)

      run(fn input, _context -> {:ok, %{text: input.arguments.text}} end)
    end
  end

  a2a do
    skill(:converse, :converse, consequence: :observe)
  end
end

defmodule AshA2A.W25HTTPJSON.Domain do
  @moduledoc false
  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.W25HTTPJSON.Resource)
  end
end

defmodule AshA2A.W25HTTPJSON.Agent do
  @moduledoc false
  use AshA2A.Agent,
    resource_or_domain: AshA2A.W25HTTPJSON.Resource,
    name: "w25_http_json_agent"
end

defmodule AshA2A.W25HTTPJSON.Pipeline do
  @moduledoc "Stamps a verified identity on every request."

  @behaviour Plug

  def init(opts) when is_map(opts), do: opts
  def init(opts), do: AshA2A.Transport.HTTPJSON.init(opts)

  def call(conn, opts) do
    conn = AshA2A.Protocol.Plug.Auth.put_identity(conn, %{identity: "alice"})
    AshA2A.Transport.HTTPJSON.call(conn, opts)
  end
end

defmodule AshA2A.W25HTTPJSONTest do
  @moduledoc """
  W25 court: REST binding wiring (W8 error mapping, W12 tenant binding, W15
  request span, W17 traceparent). Real Bandit server, real agent, real `Req`.
  """

  use ExUnit.Case, async: false

  @moduletag :serial_shard

  alias AshA2A.Protocol.{Message, Part}
  alias AshA2A.Test.EphemeralHttp
  alias AshA2A.W25HTTPJSON.Pipeline

  @agent AshA2A.W25HTTPJSON.Agent
  @traceparent "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"

  setup do
    {_sup, _registry} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [@agent])

    opts = [agent: @agent, base_url: "http://127.0.0.1/fixture"]
    {:ok, server: EphemeralHttp.start!({Pipeline, Pipeline.init(opts)})}
  end

  defp wire(parts), do: AshA2A.Protocol.JSON.encode!(Message.new_user(parts))
  defp parked, do: wire([Part.Data.new(%{})])

  defp send_message(server, message, prefix \\ "", headers \\ []) do
    Req.post!(
      url: server.base_url <> prefix <> "/message:send",
      json: %{"message" => message},
      headers: headers,
      retry: false
    )
  end

  test "follow-up with a mismatching contextId answers 400 invalid params", %{server: server} do
    resp = send_message(server, parked())
    assert %{"task" => %{"id" => id}} = resp.body

    follow_up = Map.merge(parked(), %{"taskId" => id, "contextId" => "ctx-not-the-task"})
    bad = send_message(server, follow_up)

    assert bad.status == 400
    assert bad.body["error"]["message"] =~ "Invalid"
    assert inspect(bad.body) =~ "contextId does not match task"
  end

  test "unsupported input media type answers -32005 over 415", %{server: server} do
    message = wire([%Part.Data{data: %{}, media_type: "application/x-w25-unsupported"}])
    resp = send_message(server, message)

    assert resp.status == 415
    assert inspect(resp.body) =~ "CONTENT_TYPE_NOT_SUPPORTED"
  end

  test "follow-up to a terminal task answers 400 UNSUPPORTED_OPERATION", %{server: server} do
    done = send_message(server, wire([Part.Data.new(%{"text" => "hi"})]))

    assert %{"task" => %{"id" => id, "status" => %{"state" => "TASK_STATE_COMPLETED"}}} =
             done.body

    resp = send_message(server, Map.put(parked(), "taskId", id))

    assert resp.status == 400
    assert %{"error" => %{"details" => [%{"reason" => "UNSUPPORTED_OPERATION"} | _]}} = resp.body
  end

  test "tenant A cannot read tenant B's task over /{tenant}/tasks/{id}", %{server: server} do
    resp = send_message(server, parked(), "/acme")
    assert %{"task" => %{"id" => id}} = resp.body

    assert Req.get!(url: server.base_url <> "/acme/tasks/#{id}", retry: false).status == 200
    assert Req.get!(url: server.base_url <> "/globex/tasks/#{id}", retry: false).status == 404
    assert Req.get!(url: server.base_url <> "/tasks/#{id}", retry: false).status == 404

    listed = Req.get!(url: server.base_url <> "/globex/tasks", retry: false)
    assert listed.status == 200
    refute inspect(listed.body) =~ id
  end

  test "a client-supplied tenant in metadata cannot override the path tenant", %{server: server} do
    resp =
      Req.post!(
        url: server.base_url <> "/acme/message:send",
        json: %{"message" => parked(), "metadata" => %{"ash_a2a.tenant" => "globex"}},
        retry: false
      )

    assert %{"task" => %{"id" => id}} = resp.body
    assert Req.get!(url: server.base_url <> "/acme/tasks/#{id}", retry: false).status == 200
    assert Req.get!(url: server.base_url <> "/globex/tasks/#{id}", retry: false).status == 404
  end

  test "traceparent header reaches the dispatch context and is echoed", %{server: server} do
    test_pid = self()
    handler = "w25-trace-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:ash_a2a, :dispatch, :start],
      fn _event, _measurements, meta, _config -> send(test_pid, {:dispatch_meta, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    resp =
      send_message(server, wire([Part.Data.new(%{"text" => "hi"})]), "", [
        {"traceparent", @traceparent}
      ])

    assert resp.status == 200
    assert resp.headers["traceparent"] == [@traceparent]
    assert_receive {:dispatch_meta, %{traceparent: @traceparent}}, 2_000
  end

  test "each request emits one :http_json request span, error flagged on 4xx", %{server: server} do
    test_pid = self()
    handler = "w25-span-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler,
      [[:ash_a2a, :transport, :request, :stop], [:ash_a2a, :transport, :request, :error]],
      fn event, _m, meta, _c -> send(test_pid, {:span, event, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert Req.get!(url: server.base_url <> "/tasks/nope", retry: false).status == 404

    assert_receive {:span, [:ash_a2a, :transport, :request, :error], %{binding: :http_json}},
                   2_000

    assert_receive {:span, [:ash_a2a, :transport, :request, :stop], %{route: "GET /tasks/{id}"}},
                   2_000
  end
end
