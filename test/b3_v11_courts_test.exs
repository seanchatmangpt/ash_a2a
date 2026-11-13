# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.B3.Resource do
  @moduledoc "Real fixture: `:converse` parks in input_required when :text is omitted."

  use Ash.Resource,
    domain: AshA2A.B3.Domain,
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

defmodule AshA2A.B3.Domain do
  @moduledoc false
  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.B3.Resource)
  end
end

defmodule AshA2A.B3.ClosedAgent do
  @moduledoc "No `user_artifacts` declared."
  use AshA2A.Agent,
    resource_or_domain: AshA2A.B3.Resource,
    name: "b3_closed_agent"
end

defmodule AshA2A.B3.OpenAgent do
  @moduledoc "Declares `capabilities.user_artifacts`."
  use AshA2A.Agent,
    resource_or_domain: AshA2A.B3.Resource,
    name: "b3_open_agent",
    capabilities: %{streaming: true, user_artifacts: true}
end

defmodule AshA2A.B3.Pipeline do
  @moduledoc "Stamps a verified identity taken from the `x-test-user` header (default alice)."

  @behaviour Plug

  def init(opts), do: AshA2A.Transport.Plug.init(opts)

  def call(conn, opts) do
    user =
      case Plug.Conn.get_req_header(conn, "x-test-user") do
        [u | _] -> u
        [] -> "alice"
      end

    conn
    |> AshA2A.Protocol.Plug.Auth.put_identity(%{identity: user})
    |> AshA2A.Transport.Plug.call(opts)
  end
end

defmodule AshA2A.B3.V11CourtsTest do
  @moduledoc """
  B3 courts over the JSON-RPC `AshA2A.Transport.Plug` on a real Bandit
  listener with a real `AshA2A.Agent` and real `Req` clients.

  Covered here (gaps only):

    1. `tasks/resubscribe` on an owned task: snapshot first; no snapshot when
       `lastSeenGeneration` equals the current generation; foreign principal
       gets `-32001`.
    2. `message/stream` messageUpdate frames: absent for A2A-Version 1.0,
       present for 1.1.
    3. `capabilities.userArtifacts` advertised on the served card when
       declared; `artifactUpdates` refused (-32004) when not.
    4. `ifGenerationMatch` mismatch -> JSON-RPC `-32010` TASK_GENERATION_MISMATCH.

  Already covered elsewhere (not repeated): REST 409 mismatch, REST
  subscribe `lastSeenGeneration`, REST artifactUpdates refusal and REST
  message:stream version gating (test/v9_http_json_v11_test.exs); -32010 and
  1.0 gating on `AshA2A.Protocol.Plug` (test/v12_plug_wiring_test.exs,
  test/v13_sse_generation_test.exs).
  """

  use ExUnit.Case, async: false

  @moduletag :serial_shard

  alias AshA2A.Protocol.{Message, Part}
  alias AshA2A.Test.EphemeralHttp

  @deadline_ms 5_000
  @v11 [{"a2a-version", "1.1"}]

  setup do
    agents = [AshA2A.B3.ClosedAgent, AshA2A.B3.OpenAgent]

    {_sup, _registry} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, agents)

    versions = Enum.uniq(AshA2A.Protocol.Version.supported_default() ++ ["1.0", "1.1"])

    servers =
      Map.new(agents, fn agent ->
        opts = [agent: agent, base_url: "http://127.0.0.1/b3", versions: versions]
        {agent, EphemeralHttp.start!({AshA2A.B3.Pipeline, opts})}
      end)

    {:ok, closed: servers[AshA2A.B3.ClosedAgent], open: servers[AshA2A.B3.OpenAgent]}
  end

  # -- helpers ---------------------------------------------------------------

  defp wire(parts), do: AshA2A.Protocol.JSON.encode!(Message.new_user(parts))
  defp parked, do: wire([Part.Data.new(%{})])
  defp completing, do: wire([Part.Data.new(%{"text" => "hi"})])

  defp envelope(method, params),
    do: %{
      "jsonrpc" => "2.0",
      "id" => System.unique_integer([:positive]),
      "method" => method,
      "params" => params
    }

  defp rpc(server, method, params, headers \\ @v11) do
    Req.post!(
      url: server.base_url <> "/",
      json: envelope(method, params),
      headers: headers,
      retry: false
    ).body
  end

  defp park_task(server) do
    assert %{"result" => %{"task" => %{"id" => id} = task}} =
             rpc(server, "message/send", %{"message" => parked()})

    {id, gen(task)}
  end

  defp gen(%{"generation" => g}) do
    {n, ""} = g |> to_string() |> Integer.parse()
    n
  end

  # `data:` frames of a buffered SSE body, as JSON-RPC envelopes.
  defp frames(buffer) do
    buffer
    |> String.split("\n\n")
    |> Enum.drop(-1)
    |> Enum.flat_map(fn
      "data: " <> json -> [Jason.decode!(json)]
      _comment -> []
    end)
  end

  defp results(frames), do: Enum.map(frames, &Map.get(&1, "result", &1))

  # Opens an SSE request and returns once the response HEADERS arrived. For a
  # resubscribe the plug registers the subscriber before it starts the
  # response, so a returned handle means the subscription is live.
  defp open_stream(server, params, headers) do
    resp =
      Req.post!(
        url: server.base_url <> "/",
        json: envelope("tasks/resubscribe", params),
        headers: headers,
        retry: false,
        into: :self,
        receive_timeout: 20_000
      )

    assert resp.status == 200
    resp
  end

  defp collect(resp, buffer, pred) do
    deadline = System.monotonic_time(:millisecond) + @deadline_ms
    do_collect(resp, buffer, pred, deadline)
  end

  defp do_collect(resp, buffer, pred, deadline) do
    all = frames(buffer)

    if pred.(all) do
      {all, buffer}
    else
      remaining = deadline - System.monotonic_time(:millisecond)
      if remaining <= 0, do: flunk("deadline; frames so far: #{inspect(all)}")

      receive do
        msg ->
          case Req.parse_message(resp, msg) do
            {:ok, chunks} ->
              data = for {:data, d} <- chunks, into: "", do: d
              do_collect(resp, buffer <> data, pred, deadline)

            _unknown ->
              do_collect(resp, buffer, pred, deadline)
          end
      after
        remaining -> flunk("deadline; frames so far: #{inspect(all)}")
      end
    end
  end

  defp advance(server, id) do
    assert %{"result" => %{"task" => %{"id" => ^id}}} =
             rpc(server, "message/send", %{"message" => Map.put(parked(), "taskId", id)})
  end

  # -- 1. tasks/resubscribe on an owned task ------------------------------------

  test "resubscribe on an owned task sends the task snapshot first", %{open: server} do
    {id, generation} = park_task(server)

    resp = open_stream(server, %{"id" => id}, @v11)
    {[first | _], _} = collect(resp, "", &(&1 != []))

    assert %{"result" => %{"task" => %{"id" => ^id} = snapshot}} = first
    assert gen(snapshot) == generation
    Req.cancel_async_response(resp)
  end

  test "resubscribe with lastSeenGeneration == current sends no snapshot, only newer events", %{
    open: server
  } do
    {id, generation} = park_task(server)

    resp = open_stream(server, %{"id" => id, "lastSeenGeneration" => generation}, @v11)

    advance(server, id)

    {frames, _} = collect(resp, "", &(&1 != []))
    refute Enum.any?(results(frames), &Map.has_key?(&1, "task"))

    assert [update] =
             frames
             |> hd()
             |> Map.fetch!("result")
             |> Map.take(["statusUpdate", "messageUpdate"])
             |> Map.values()

    assert gen(update) > generation
    Req.cancel_async_response(resp)
  end

  test "resubscribe by a foreign principal is -32001, indistinguishable from an unknown task", %{
    open: server
  } do
    {id, _} = park_task(server)

    foreign = rpc(server, "tasks/resubscribe", %{"id" => id}, @v11 ++ [{"x-test-user", "bob"}])

    unknown =
      rpc(
        server,
        "tasks/resubscribe",
        %{"id" => "tsk-no-such-task"},
        @v11 ++ [{"x-test-user", "bob"}]
      )

    assert %{"error" => %{"code" => -32_001}} = foreign
    assert get_in(foreign, ["error", "code"]) == get_in(unknown, ["error", "code"])
    assert get_in(foreign, ["error", "data"]) == get_in(unknown, ["error", "data"])
    refute Map.has_key?(foreign, "result")
  end

  # -- 2. messageUpdate version gating on message/stream -------------------------

  test "message/stream frames carry messageUpdate for A2A-Version 1.1 and not for 1.0", %{
    open: server
  } do
    stream = fn version ->
      resp =
        Req.post!(
          url: server.base_url <> "/",
          json: envelope("message/stream", %{"message" => completing()}),
          headers: [{"a2a-version", version}],
          retry: false,
          decode_body: false
        )

      assert resp.status == 200
      resp.body |> frames() |> results()
    end

    new = stream.("1.1")
    assert Enum.any?(new, &Map.has_key?(&1, "messageUpdate"))
    assert Enum.any?(new, &Map.has_key?(&1, "statusUpdate"))

    old = stream.("1.0")
    refute Enum.any?(old, &Map.has_key?(&1, "messageUpdate"))
    refute Enum.any?(old, &Map.has_key?(&1, "error"))
    assert Enum.any?(old, &Map.has_key?(&1, "statusUpdate"))
  end

  # -- 3. userArtifacts ------------------------------------------------------------

  test "card advertises capabilities.userArtifacts when declared and not when undeclared", %{
    open: open,
    closed: closed
  } do
    open_card = Req.get!(url: open.base_url <> "/.well-known/agent-card.json", retry: false).body
    assert get_in(open_card, ["capabilities", "userArtifacts"]) == true

    closed_card =
      Req.get!(url: closed.base_url <> "/.well-known/agent-card.json", retry: false).body

    refute get_in(closed_card, ["capabilities", "userArtifacts"]) == true
  end

  test "artifactUpdates are refused -32004 when userArtifacts is not declared, task untouched", %{
    closed: server
  } do
    {id, generation} = park_task(server)

    artifact =
      AshA2A.Protocol.JSON.encode!(AshA2A.Protocol.Artifact.new([Part.Data.new(%{"k" => "v"})]))

    resp =
      rpc(server, "message/send", %{
        "artifactUpdates" => [%{"taskId" => id, "artifact" => artifact}]
      })

    assert %{"error" => %{"code" => -32_004}} = resp

    assert %{"result" => %{"id" => ^id} = task} = rpc(server, "tasks/get", %{"id" => id})
    assert gen(task) == generation
  end

  # -- 4. ifGenerationMatch ----------------------------------------------------------

  test "ifGenerationMatch mismatch is -32010 TASK_GENERATION_MISMATCH; match proceeds", %{
    open: server
  } do
    {id, generation} = park_task(server)
    follow_up = Map.put(parked(), "taskId", id)

    stale =
      rpc(server, "message/send", %{
        "message" => follow_up,
        "configuration" => %{"ifGenerationMatch" => generation + 5}
      })

    assert %{"error" => %{"code" => -32_010, "data" => data}} = stale
    assert Enum.any?(data, &(&1["reason"] == "TASK_GENERATION_MISMATCH"))

    # refused before mutation
    assert %{"result" => task} = rpc(server, "tasks/get", %{"id" => id})
    assert gen(task) == generation

    ok =
      rpc(server, "message/send", %{
        "message" => follow_up,
        "configuration" => %{"ifGenerationMatch" => generation}
      })

    assert %{"result" => %{"task" => %{"id" => ^id}}} = ok
  end
end
