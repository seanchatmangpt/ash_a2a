# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.RestLivePaths.Resource do
  @moduledoc "Real fixture: `:converse` parks in input_required when :text is omitted."

  use Ash.Resource,
    domain: AshA2A.RestLivePaths.Domain,
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

defmodule AshA2A.RestLivePaths.Domain do
  @moduledoc false
  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.RestLivePaths.Resource)
  end
end

defmodule AshA2A.RestLivePaths.Agent do
  @moduledoc false
  use AshA2A.Agent,
    resource_or_domain: AshA2A.RestLivePaths.Resource,
    name: "y5_rest_live_agent"
end

defmodule AshA2A.RestLivePaths.PlainAgent do
  @moduledoc false
  # Real Protocol.Agent that does not declare streaming.
  use AshA2A.Protocol.Agent, name: "y5-rest-plain", description: "no streaming"

  @impl AshA2A.Protocol.Agent
  def handle_message(_message, _ctx),
    do: {:input_required, [AshA2A.Protocol.Part.Text.new("more?")]}
end

defmodule AshA2A.RestLivePaths.StreamingAgent do
  @moduledoc false
  use AshA2A.Protocol.Agent,
    name: "y5-rest-streaming",
    description: "streaming, parks in input_required",
    capabilities: %{streaming: true}

  @impl AshA2A.Protocol.Agent
  def handle_message(_message, _ctx),
    do: {:input_required, [AshA2A.Protocol.Part.Text.new("more?")]}
end

defmodule AshA2A.RestLivePaths.FlakyCardAgent do
  @moduledoc false
  # Hand-written real implementation of the agent card interface: the first
  # `:get_agent_card` (the transport's own capability probe) answers a
  # streaming card; every later one (the Live core's own card fetch) answers
  # a non-card, which the Live core reports as `{:error, :unavailable}`.
  use GenServer

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, :ok, name: Keyword.fetch!(opts, :name))

  @impl true
  def init(:ok), do: {:ok, 0}

  @impl true
  def handle_call(:get_agent_card, _from, 0),
    do: {:reply, %{name: "y5-flaky", capabilities: %{streaming: true}}, 1}

  def handle_call(:get_agent_card, _from, n), do: {:reply, :unavailable, n + 1}
  def handle_call(_other, _from, n), do: {:reply, {:error, :unsupported}, n}
end

defmodule AshA2A.RestLivePaths.Pipeline do
  @moduledoc "Stamps a verified identity (`x-y5-user` header, default alice) on every request."

  @behaviour Plug

  def init(opts) when is_map(opts), do: opts
  def init(opts), do: AshA2A.Transport.HTTPJSON.init(opts)

  def call(conn, opts) do
    user = List.first(Plug.Conn.get_req_header(conn, "x-y5-user")) || "alice"
    conn = AshA2A.Protocol.Plug.Auth.put_identity(conn, %{identity: user})
    AshA2A.Transport.HTTPJSON.call(conn, opts)
  end
end

defmodule AshA2A.RestLivePathsTest do
  @moduledoc """
  Y5 courts: REST `POST /{tenant}/message:live` and its uplink failure
  surface over real Bandit and real `Req`: path tenant binding, uplink by
  `live_session_id` (query and body), streaming-disabled 400, 503 when the
  agent card is unreachable (downlink and uplink), and the missing-task
  uplink at the Live core the REST binding maps to 404. Waits are
  deadline-bounded receives, no sleeps.
  """

  use ExUnit.Case, async: false

  @moduletag :serial_shard

  alias AshA2A.Protocol.{Message, Part}
  alias AshA2A.Test.EphemeralHttp
  alias AshA2A.RestLivePaths.{Agent, FlakyCardAgent, PlainAgent, Pipeline, StreamingAgent}

  @v11 [{"a2a-version", "1.1"}]
  @deadline_ms 5_000

  setup do
    {_sup, _registry} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [Agent])

    {:ok, server: start_server(Agent)}
  end

  # -- helpers -----------------------------------------------------------------

  defp start_server(agent) do
    versions = Enum.uniq(AshA2A.Protocol.Version.supported_default() ++ ["1.0", "1.1"])
    opts = [agent: agent, base_url: "http://127.0.0.1/fixture", versions: versions]
    EphemeralHttp.start!({Pipeline, Pipeline.init(opts)})
  end

  defp parked, do: AshA2A.Protocol.JSON.encode!(Message.new_user([Part.Data.new(%{})]))
  defp send_body(message), do: %{"sendMessage" => %{"message" => message}}
  defp live_url(server, prefix \\ ""), do: server.base_url <> prefix <> "/message:live"

  defp frames(buffer) do
    buffer
    |> String.split("\n\n")
    |> Enum.drop(-1)
    |> Enum.flat_map(fn
      "data: " <> json -> [Jason.decode!(json)]
      _comment -> []
    end)
  end

  defp open_sse(url, json, headers) do
    parent = self()
    ref = make_ref()

    task =
      Task.async(fn ->
        Req.request!(
          method: :post,
          url: url,
          json: json,
          headers: headers,
          retry: false,
          receive_timeout: 20_000,
          into: fn {:data, data}, {req, resp} ->
            case Req.Response.get_header(resp, "a2a-live-session-id") do
              [sid | _] -> send(parent, {:sid, ref, sid})
              [] -> :ok
            end

            send(parent, {:sse, ref, data})
            {:cont, {req, resp}}
          end
        )
      end)

    on_exit(fn -> Process.exit(task.pid, :kill) end)
    ref
  end

  defp session_id(ref) do
    receive do
      {:sid, ^ref, sid} -> sid
    after
      @deadline_ms -> flunk("no a2a-live-session-id response header")
    end
  end

  defp collect_until(ref, buffer, pred) do
    deadline = System.monotonic_time(:millisecond) + @deadline_ms
    do_collect(ref, buffer, pred, deadline)
  end

  defp do_collect(ref, buffer, pred, deadline) do
    all = frames(buffer)

    if pred.(all) do
      {all, buffer}
    else
      remaining = deadline - System.monotonic_time(:millisecond)
      if remaining <= 0, do: flunk("deadline; frames so far: #{inspect(all)}")

      receive do
        {:sse, ^ref, data} -> do_collect(ref, buffer <> data, pred, deadline)
      after
        remaining -> flunk("deadline; frames so far: #{inspect(all)}")
      end
    end
  end

  # Opens a downlink and returns {ref, task_id, sid, buffer}.
  defp open_downlink(url) do
    ref = open_sse(url, send_body(parked()), @v11)
    {[%{"task" => %{"id" => id}} | _], buffer} = collect_until(ref, "", &(&1 != []))
    {ref, id, session_id(ref), buffer}
  end

  # -- per-request tenant --------------------------------------------------------

  test "/{tenant}/message:live binds the path tenant: the live task is visible to that tenant only",
       %{
         server: server
       } do
    {ref, id, sid, buffer} = open_downlink(live_url(server, "/acme"))

    ack =
      Req.post!(
        url: live_url(server, "/acme"),
        json: send_body(Map.put(parked(), "taskId", id)),
        headers: @v11 ++ [{"a2a-live-session-id", sid}],
        retry: false
      )

    assert ack.status == 200
    assert %{"id" => ^id} = ack.body

    {frames, _} =
      collect_until(ref, buffer, fn fs -> Enum.any?(fs, &Map.has_key?(&1, "statusUpdate")) end)

    assert Enum.any?(frames, &Map.has_key?(&1, "statusUpdate"))

    own = Req.get!(url: server.base_url <> "/acme/tasks/#{id}", headers: @v11, retry: false)
    assert own.status == 200
    assert %{"id" => ^id} = own.body

    foreign = Req.get!(url: server.base_url <> "/other/tasks/#{id}", headers: @v11, retry: false)
    assert foreign.status == 404
  end

  # -- uplink via live_session_id ---------------------------------------------------

  test "uplink via the live_session_id query parameter answers the ack task only", %{
    server: server
  } do
    {ref, id, sid, buffer} = open_downlink(live_url(server))

    ack =
      Req.post!(
        url: live_url(server) <> "?live_session_id=#{sid}",
        json: send_body(Map.put(parked(), "taskId", id)),
        headers: @v11,
        retry: false
      )

    assert ack.status == 200
    assert %{"id" => ^id} = ack.body
    refute Map.has_key?(ack.body, "statusUpdate")

    {frames, _} =
      collect_until(ref, buffer, fn fs -> Enum.any?(fs, &Map.has_key?(&1, "statusUpdate")) end)

    assert Enum.any?(frames, &Map.has_key?(&1, "statusUpdate"))
  end

  test "uplink via the live_session_id body key answers the ack task only", %{server: server} do
    {_ref, id, sid, _buffer} = open_downlink(live_url(server))

    body =
      send_body(Map.put(parked(), "taskId", id))
      |> Map.put("live_session_id", sid)

    ack = Req.post!(url: live_url(server), json: body, headers: @v11, retry: false)

    assert ack.status == 200
    assert %{"id" => ^id} = ack.body
  end

  # -- missing task -----------------------------------------------------------------

  test "uplink naming a task that does not exist is {:error, :not_found} at the Live core (REST: 404)" do
    start_supervised!({StreamingAgent, []})

    unless Process.whereis(AshA2A.Transport.Live.Registry),
      do: start_supervised!(AshA2A.Transport.Live.Supervisor)

    request = send_body(Map.put(parked(), "taskId", "y5-no-such-task"))

    assert {:error, :not_found} =
             AshA2A.Transport.Live.uplink_call(
               StreamingAgent,
               %{metadata: %{}, principal: :anonymous},
               request
             )
  end

  # -- streaming disabled -------------------------------------------------------------

  test "message:live when streaming is disabled is 400 UNSUPPORTED_OPERATION" do
    start_supervised!({PlainAgent, []})
    server = start_server(PlainAgent)

    resp =
      Req.post!(url: live_url(server), json: send_body(parked()), headers: @v11, retry: false)

    assert resp.status == 400
    assert %{"error" => %{"details" => [%{"reason" => "UNSUPPORTED_OPERATION"} | _]}} = resp.body
  end

  # -- 503 unavailable ------------------------------------------------------------------

  test "uplink is 503 when the agent card becomes unreachable" do
    name = :"y5_flaky_uplink_#{System.unique_integer([:positive])}"
    start_supervised!({FlakyCardAgent, name: name}, id: name)
    server = start_server(name)

    resp =
      Req.post!(
        url: live_url(server),
        json: send_body(parked()),
        headers: @v11 ++ [{"a2a-live-session-id", "live-y5-any"}],
        retry: false
      )

    assert resp.status == 503
    assert %{"error" => %{}} = resp.body
  end

  test "downlink open is 503 when the agent card becomes unreachable" do
    name = :"y5_flaky_downlink_#{System.unique_integer([:positive])}"
    start_supervised!({FlakyCardAgent, name: name}, id: name)
    server = start_server(name)

    resp =
      Req.post!(url: live_url(server), json: send_body(parked()), headers: @v11, retry: false)

    assert resp.status == 503
    assert %{"error" => %{}} = resp.body
  end
end
