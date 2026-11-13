# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.V14.Resource do
  @moduledoc "Real fixture: `:converse` parks in input_required when :text is omitted."

  use Ash.Resource,
    domain: AshA2A.V14.Domain,
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

defmodule AshA2A.V14.Domain do
  @moduledoc false
  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.V14.Resource)
  end
end

defmodule AshA2A.V14.Agent do
  @moduledoc false
  use AshA2A.Agent,
    resource_or_domain: AshA2A.V14.Resource,
    name: "v14_http_json_agent"
end

defmodule AshA2A.V14.Pipeline do
  @moduledoc "Stamps a verified identity (`x-v14-user` header, default alice) on every request."

  @behaviour Plug

  def init(opts) when is_map(opts), do: opts
  def init(opts), do: AshA2A.Transport.HTTPJSON.init(opts)

  def call(conn, opts) do
    user = List.first(Plug.Conn.get_req_header(conn, "x-v14-user")) || "alice"
    conn = AshA2A.Protocol.Plug.Auth.put_identity(conn, %{identity: user})
    AshA2A.Transport.HTTPJSON.call(conn, opts)
  end
end

defmodule AshA2A.V14HTTPJSONLiveCoreTest do
  @moduledoc """
  V14 court: `POST /message:live` runs on the `AshA2A.Transport.Live` core --
  session id response header, ack-only uplink by session id, foreign-principal
  isolation, and messageUpdate gating for pre-1.1 clients. Real Bandit, real
  agent, real `Req`; waits are deadline-bounded observations.
  """

  use ExUnit.Case, async: false

  @moduletag :serial_shard

  alias AshA2A.Protocol.{Message, Part}
  alias AshA2A.Test.EphemeralHttp
  alias AshA2A.V14.Pipeline

  @agent AshA2A.V14.Agent
  @v11 [{"a2a-version", "1.1"}]
  @deadline_ms 5_000

  setup do
    {_sup, _registry} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [@agent])

    versions = Enum.uniq(AshA2A.Protocol.Version.supported_default() ++ ["1.0", "1.1"])
    opts = [agent: @agent, base_url: "http://127.0.0.1/fixture", versions: versions]
    {:ok, server: EphemeralHttp.start!({Pipeline, Pipeline.init(opts)})}
  end

  defp parked, do: AshA2A.Protocol.JSON.encode!(Message.new_user([Part.Data.new(%{})]))
  defp live_url(server), do: server.base_url <> "/message:live"
  defp send_body(message), do: %{"sendMessage" => %{"message" => message}}

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

  test "uplink by session id answers the ack task only; events arrive on the downlink", %{
    server: server
  } do
    ref = open_sse(live_url(server), send_body(parked()), @v11)
    {[%{"task" => %{"id" => id}} | _], buffer} = collect_until(ref, "", &(&1 != []))
    sid = session_id(ref)
    assert is_binary(sid) and sid != ""

    ack =
      Req.post!(
        url: live_url(server),
        json: send_body(Map.put(parked(), "taskId", id)),
        headers: @v11 ++ [{"a2a-live-session-id", sid}],
        retry: false
      )

    assert ack.status == 200
    assert %{"id" => ^id} = ack.body
    refute Map.has_key?(ack.body, "statusUpdate")

    {frames, _} =
      collect_until(ref, buffer, fn fs -> Enum.any?(fs, &Map.has_key?(&1, "statusUpdate")) end)

    assert Enum.any?(frames, &Map.has_key?(&1, "messageUpdate"))
  end

  test "pre-1.1 downlink never receives messageUpdate frames", %{server: server} do
    ref = open_sse(live_url(server), send_body(parked()), [{"a2a-version", "1.0"}])
    {[%{"task" => %{"id" => id}} | _], buffer} = collect_until(ref, "", &(&1 != []))
    sid = session_id(ref)

    ack =
      Req.post!(
        url: live_url(server) <> "?live_session_id=#{sid}",
        json: send_body(Map.put(parked(), "taskId", id)),
        headers: [{"a2a-version", "1.0"}],
        retry: false
      )

    assert ack.status == 200

    {frames, _} =
      collect_until(ref, buffer, fn fs -> Enum.any?(fs, &Map.has_key?(&1, "statusUpdate")) end)

    refute Enum.any?(frames, &Map.has_key?(&1, "messageUpdate"))
  end

  test "a foreign principal cannot uplink into another caller's session", %{server: server} do
    ref = open_sse(live_url(server), send_body(parked()), @v11)
    {[%{"task" => %{"id" => id}} | _], _buffer} = collect_until(ref, "", &(&1 != []))
    sid = session_id(ref)

    foreign =
      Req.post!(
        url: live_url(server),
        json: send_body(Map.put(parked(), "taskId", id)),
        headers: @v11 ++ [{"a2a-live-session-id", sid}, {"x-v14-user", "mallory"}],
        retry: false
      )

    assert foreign.status == 400
    assert %{"error" => %{"code" => 400}} = foreign.body
  end

  test "an unknown session id is a 400 JSON error", %{server: server} do
    resp =
      Req.post!(
        url: live_url(server),
        json: send_body(parked()),
        headers: @v11 ++ [{"a2a-live-session-id", "live-nope"}],
        retry: false
      )

    assert resp.status == 400
    assert %{"error" => %{"code" => 400}} = resp.body
  end
end
