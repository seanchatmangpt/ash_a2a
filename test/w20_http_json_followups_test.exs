# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.W20HTTPJSON.Resource do
  @moduledoc "Real fixture: `:converse` parks in input_required when :text is omitted."

  use Ash.Resource,
    domain: AshA2A.W20HTTPJSON.Domain,
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

defmodule AshA2A.W20HTTPJSON.Domain do
  @moduledoc false
  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.W20HTTPJSON.Resource)
  end
end

defmodule AshA2A.W20HTTPJSON.Agent do
  @moduledoc false
  use AshA2A.Agent,
    resource_or_domain: AshA2A.W20HTTPJSON.Resource,
    name: "w20_http_json_agent"
end

defmodule AshA2A.W20HTTPJSON.Pipeline do
  @moduledoc "Stamps a verified identity when an authorization header is present."

  @behaviour Plug
  import Plug.Conn

  def init(opts) when is_map(opts), do: opts
  def init(opts), do: AshA2A.Transport.HTTPJSON.init(opts)

  def call(conn, opts) do
    conn =
      case get_req_header(conn, "authorization") do
        [_ | _] -> AshA2A.Protocol.Plug.Auth.put_identity(conn, %{identity: "alice"})
        [] -> conn
      end

    AshA2A.Transport.HTTPJSON.call(conn, opts)
  end
end

defmodule AshA2A.W20HTTPJSONTest do
  @moduledoc """
  W20 court: REST binding follow-ups. Real Bandit server, real agent, real
  `Req` calls; no mocks.
  """

  use ExUnit.Case, async: false

  @moduletag :serial_shard

  alias AshA2A.Protocol.{Message, Part}
  alias AshA2A.Test.EphemeralHttp
  alias AshA2A.W20HTTPJSON.Pipeline

  @agent AshA2A.W20HTTPJSON.Agent

  setup do
    {_sup, _registry} = AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [@agent])
    :ok
  end

  defp start(extra \\ []) do
    opts = Keyword.merge([agent: @agent, base_url: "http://127.0.0.1/fixture"], extra)
    EphemeralHttp.start!({Pipeline, Pipeline.init(opts)})
  end

  defp parked_message do
    AshA2A.Protocol.JSON.encode!(Message.new_user([Part.Data.new(%{})]))
  end

  test "extended card never carries inherited (stale) signatures" do
    provider = fn _identity, public ->
      {:ok, public |> Map.put("name", "w20-extended") |> Map.put("signatures", [%{"signature" => "stale"}])}
    end

    server = start(extended_card: provider)
    resp = Req.get!(url: server.base_url <> "/extendedAgentCard", headers: [authorization: "Bearer t"])

    assert resp.status == 200
    assert resp.body["name"] == "w20-extended"
    refute Map.has_key?(resp.body, "signatures")
  end

  test "message:send accepts configuration.returnImmediately / acceptedOutputModes" do
    server = start()

    resp =
      Req.post!(
        url: server.base_url <> "/message:send",
        json: %{
          "message" => parked_message(),
          "configuration" => %{"returnImmediately" => true, "acceptedOutputModes" => ["text/plain"]}
        }
      )

    assert resp.status == 200
    assert %{"task" => %{"id" => _}} = resp.body
  end

  test "push list on a push-disabled server stays -32003 even with paging params" do
    server = start()
    resp = Req.get!(url: server.base_url <> "/tasks/x/pushNotificationConfigs?pageSize=1&pageToken=")
    assert resp.status == 400
  end

  test "GET :subscribe on a non-terminal task streams the snapshot; terminal 400; unknown 404" do
    server = start()

    resp = Req.post!(url: server.base_url <> "/message:send", json: %{"message" => parked_message()})
    assert %{"task" => %{"id" => id, "status" => %{"state" => "TASK_STATE_INPUT_REQUIRED"}}} = resp.body

    # Halt after the first SSE frame (the snapshot); the stream would
    # otherwise follow until a final event.
    sse =
      Req.get!(
        url: server.base_url <> "/tasks/#{id}:subscribe",
        decode_body: false,
        retry: false,
        into: fn {:data, data}, {req, response} ->
          {:halt, {req, %{response | body: data}}}
        end
      )

    assert sse.status == 200
    assert hd(sse.headers["content-type"]) =~ "text/event-stream"
    assert "data: " <> json = sse.body
    assert %{"task" => %{"id" => ^id}} = json |> String.trim() |> Jason.decode!()

    canceled = Req.post!(url: server.base_url <> "/tasks/#{id}:cancel")
    assert canceled.status == 200

    terminal = Req.get!(url: server.base_url <> "/tasks/#{id}:subscribe")
    assert terminal.status == 400
    assert %{"error" => %{"details" => [%{"reason" => "UNSUPPORTED_OPERATION"}]}} = terminal.body

    unknown = Req.get!(url: server.base_url <> "/tasks/nope:subscribe")
    assert unknown.status == 404
  end
end
