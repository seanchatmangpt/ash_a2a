# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
# SPDX-License-Identifier: MIT

# ==============================================================================
# Consolidated Test Suite: Root HTTP JSON & Sessions
# Consolidated from 15 source files:
#   - test/http_json_binding_test.exs
#   - test/http_json_followups_test.exs
#   - test/http_json_generation_stream_test.exs
#   - test/http_json_live_session_test.exs
#   - test/http_json_plug_wiring_test.exs
#   - test/jsonrpc_artifact_resubscribe_test.exs
#   - test/jsonrpc_routing_test.exs
#   - test/live_session_streaming_test.exs
#   - test/no_personal_names_test.exs
#   - test/protocol_codec_fidelity_test.exs
#   - test/protocol_codec_v1_1_test.exs
#   - test/protocol_downgrade_wire_test.exs
#   - test/protocol_error_tables_test.exs
#   - test/protocol_version_negotiation_test.exs
#   - test/push_config_protocol_version_test.exs
# ==============================================================================

# --- SOURCE: test/http_json_binding_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.HttpJsonBinding.Resource do
  @moduledoc "Real ETS-backed fixture resource with one `:read` skill."

  use Ash.Resource,
    domain: AshA2A.HttpJsonBinding.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
  end

  actions do
    defaults([:read])
  end

  a2a do
    skill(:echo, :read)
  end
end

defmodule AshA2A.HttpJsonBinding.Domain do
  @moduledoc "Real fixture domain."

  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.HttpJsonBinding.Resource)
  end
end

defmodule AshA2A.HttpJsonBinding.Agent do
  @moduledoc "Real `AshA2A.Agent` over the fixture resource."

  use AshA2A.Agent,
    resource_or_domain: AshA2A.HttpJsonBinding.Resource,
    name: "w1_http_json_agent"
end

defmodule AshA2A.HttpJsonBinding.RequiredExtension do
  @moduledoc "Real required extension: clients must request its URI."

  @behaviour AshA2A.Protocol.Extension

  @uri "https://example.com/ext/w1-required"

  def uri, do: @uri

  @impl true
  def declaration(_state),
    do: %AshA2A.Protocol.AgentExtension{uri: @uri, description: "w1", required: true}

  @impl true
  def activate(_requested, _ctx, _state), do: {:ok, :on}
end

defmodule AshA2A.HttpJsonBinding.Pipeline do
  @moduledoc """
  Real wrapper plug: stamps a verified identity when an `authorization`
  header is present, runs the binding, and exposes the tenant the binding
  recorded as an `x-seen-tenant` response header.
  """

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

    # The binding sends the response; the sent conn still carries the
    # recorded tenant, but headers are already on the wire, so the binding's
    # strip happens before send. Read the tenant via a before_send hook.
    conn =
      register_before_send(conn, fn conn ->
        case conn.private |> Map.get(:a2a, %{}) |> Map.get(:tenant) do
          nil -> conn
          tenant -> put_resp_header(conn, "x-seen-tenant", tenant)
        end
      end)

    AshA2A.Transport.HTTPJSON.call(conn, opts)
  end
end

defmodule AshA2A.HttpJsonBindingTest do
  @moduledoc """
  W1 court: HTTP+JSON binding surface additions (extended card GET route,
  GET :subscribe, tenant prefix, content-type negotiation, A2A-Version /
  A2A-Extensions service parameters, gRPC status names). Real Bandit server,
  real agent, real `Req` calls; no mocks.
  """

  use ExUnit.Case, async: false

  @moduletag :serial_shard

  alias AshA2A.Test.EphemeralHttp
  alias AshA2A.HttpJsonBinding.Pipeline

  @agent AshA2A.HttpJsonBinding.Agent
  @ext_uri AshA2A.HttpJsonBinding.RequiredExtension.uri()

  setup do
    {_sup, _registry} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [@agent])

    :ok
  end

  defp start(extra \\ []) do
    opts =
      Keyword.merge(
        [
          agent: @agent,
          base_url: "http://127.0.0.1/fixture",
          extended_card: fn _identity, _public -> {:ok, %{"name" => "w1-extended"}} end
        ],
        extra
      )

    EphemeralHttp.start!({Pipeline, Pipeline.init(opts)})
  end

  defp message_map(text),
    do: AshA2A.Protocol.JSON.encode!(AshA2A.Protocol.Message.new_user(text))

  defp send_message!(server, path \\ "/message:send") do
    resp = Req.post!(url: server.base_url <> path, json: %{"message" => message_map("go")})
    assert resp.status == 200
    resp.body
  end

  # -- 1. extended card ---------------------------------------------------------

  test "GET /extendedAgentCard serves the extended card; POST /agent stays a legacy alias" do
    server = start()
    auth = [authorization: "Bearer t"]

    resp = Req.get!(url: server.base_url <> "/extendedAgentCard", headers: auth)
    assert resp.status == 200
    assert resp.body["name"] == "w1-extended"

    legacy = Req.post!(url: server.base_url <> "/agent", json: %{}, headers: auth)
    assert legacy.status == 200
    assert legacy.body["name"] == "w1-extended"

    # No identity -> 401 on the new route too.
    assert Req.get!(url: server.base_url <> "/extendedAgentCard").status == 401
  end

  test "wrong method on /extendedAgentCard answers 405 with allow: GET" do
    server = start()
    resp = Req.post!(url: server.base_url <> "/extendedAgentCard", json: %{})
    assert resp.status == 405
    assert resp.headers["allow"] == ["GET"]
  end

  # -- 2. subscribe ---------------------------------------------------------------

  test "GET and POST :subscribe on an unknown task answer 404 TaskNotFound" do
    server = start()

    for method <- [:get, :post] do
      resp = Req.request!(method: method, url: server.base_url <> "/tasks/nope:subscribe")
      assert resp.status == 404
      assert %{"error" => %{"code" => 404, "status" => "NOT_FOUND"}} = resp.body
    end
  end

  test "GET :subscribe on a terminal task answers 400 UNSUPPORTED_OPERATION" do
    server = start()
    %{"task" => %{"id" => id}} = send_message!(server)

    resp = Req.get!(url: server.base_url <> "/tasks/#{id}:subscribe")
    assert resp.status == 400

    assert %{"error" => %{"details" => [%{"reason" => "UNSUPPORTED_OPERATION"}]}} = resp.body
  end

  test "DELETE :subscribe answers 405 allowing GET and POST; DELETE :cancel unchanged" do
    server = start()
    resp = Req.delete!(url: server.base_url <> "/tasks/x:subscribe")
    assert resp.status == 405
    assert resp.headers["allow"] == ["GET, POST"]
  end

  # -- 3. tenant ------------------------------------------------------------------

  test "leading tenant segment is stripped and recorded" do
    server = start()

    resp =
      Req.post!(
        url: server.base_url <> "/acme/message:send",
        json: %{"message" => message_map("hi")}
      )

    assert resp.status == 200
    assert %{"task" => %{"id" => id}} = resp.body
    assert resp.headers["x-seen-tenant"] == ["acme"]

    get = Req.get!(url: server.base_url <> "/acme/tasks/#{id}")
    assert get.status == 200
    assert get.headers["x-seen-tenant"] == ["acme"]

    list = Req.get!(url: server.base_url <> "/acme/tasks")
    assert list.status == 200

    card =
      Req.get!(
        url: server.base_url <> "/acme/extendedAgentCard",
        headers: [authorization: "Bearer t"]
      )

    assert card.status == 200
    assert card.body["name"] == "w1-extended"
  end

  test "no tenant is recorded for un-prefixed routes, and unknown remainders stay 404" do
    server = start()
    resp = Req.get!(url: server.base_url <> "/tasks")
    assert resp.status == 200
    assert resp.headers["x-seen-tenant"] == nil

    assert Req.get!(url: server.base_url <> "/acme/nope").status == 404
  end

  # -- 4. content type ------------------------------------------------------------

  test "default response is application/json; Accept a2a+json is answered a2a+json" do
    server = start()

    default = Req.get!(url: server.base_url <> "/tasks", decode_body: false)
    assert hd(default.headers["content-type"]) =~ "application/json"

    negotiated =
      Req.get!(
        url: server.base_url <> "/tasks",
        headers: [accept: "application/a2a+json"],
        decode_body: false
      )

    assert hd(negotiated.headers["content-type"]) =~ "application/a2a+json"
  end

  test "a2a+json request bodies are accepted" do
    server = start()

    resp =
      Req.post!(
        url: server.base_url <> "/message:send",
        body: Jason.encode!(%{"message" => message_map("hi")}),
        headers: [{"content-type", "application/a2a+json"}]
      )

    assert resp.status == 200
  end

  test ":content_type option changes the default" do
    server = start(content_type: "application/a2a+json")
    resp = Req.get!(url: server.base_url <> "/tasks", decode_body: false)
    assert hd(resp.headers["content-type"]) =~ "application/a2a+json"
  end

  # -- 5. version + extensions ----------------------------------------------------

  test "A2A-Version query parameter is read when the header is absent" do
    server = start()

    bad = Req.get!(url: server.base_url <> "/tasks?A2A-Version=9.9")
    assert bad.status == 400
    assert bad.headers["a2a-version"] == ["9.9"]

    ok = Req.get!(url: server.base_url <> "/tasks?A2A-Version=1.0")
    assert ok.status == 200
  end

  test ":versions option restricts supported versions" do
    server = start(versions: ["1.0"])

    assert Req.get!(url: server.base_url <> "/tasks", headers: [{"a2a-version", "0.3"}]).status ==
             400

    assert Req.get!(url: server.base_url <> "/tasks", headers: [{"a2a-version", "1.0"}]).status ==
             200
  end

  test "required extension missing answers 400 -32008; present is activated and echoed" do
    server = start(extensions: [AshA2A.HttpJsonBinding.RequiredExtension])

    missing = Req.get!(url: server.base_url <> "/tasks")
    assert missing.status == 400
    # AIP-193 body: -32008 maps to status FAILED_PRECONDITION; the missing URI
    # rides in the error details.
    assert %{"error" => %{"code" => 400, "status" => "FAILED_PRECONDITION", "message" => message}} =
             missing.body

    assert message =~ @ext_uri or inspect(missing.body) =~ @ext_uri

    via_header =
      Req.get!(url: server.base_url <> "/tasks", headers: [{"a2a-extensions", @ext_uri}])

    assert via_header.status == 200
    assert via_header.headers["a2a-extensions"] == [@ext_uri]

    via_query = Req.get!(url: server.base_url <> "/tasks", params: [{"A2A-Extensions", @ext_uri}])
    assert via_query.status == 200
    assert via_query.headers["a2a-extensions"] == [@ext_uri]
  end

  # -- 6. gRPC status names (pure shape via the public envelope) -------------------

  test "aip193 status names for 403/422/429 are canonical" do
    # grpc_status_name/1 is private; the clauses are pinned structurally.
    source = File.read!("lib/ash_a2a/transport/http_json.ex")
    assert source =~ ~s|grpc_status_name(403), do: "PERMISSION_DENIED"|
    assert source =~ ~s|grpc_status_name(429), do: "RESOURCE_EXHAUSTED"|
    assert source =~ ~s|grpc_status_name(422), do: "INVALID_ARGUMENT"|
  end
end

# --- SOURCE: test/http_json_followups_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.HttpJsonFollowups.Resource do
  @moduledoc "Real fixture: `:converse` parks in input_required when :text is omitted."

  use Ash.Resource,
    domain: AshA2A.HttpJsonFollowups.Domain,
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

defmodule AshA2A.HttpJsonFollowups.Domain do
  @moduledoc false
  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.HttpJsonFollowups.Resource)
  end
end

defmodule AshA2A.HttpJsonFollowups.Agent do
  @moduledoc false
  use AshA2A.Agent,
    resource_or_domain: AshA2A.HttpJsonFollowups.Resource,
    name: "w20_http_json_agent"
end

defmodule AshA2A.HttpJsonFollowups.Pipeline do
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

defmodule AshA2A.HttpJsonFollowupsTest do
  @moduledoc """
  W20 court: REST binding follow-ups. Real Bandit server, real agent, real
  `Req` calls; no mocks.
  """

  use ExUnit.Case, async: false

  @moduletag :serial_shard

  alias AshA2A.Protocol.{Message, Part}
  alias AshA2A.Test.EphemeralHttp
  alias AshA2A.HttpJsonFollowups.Pipeline

  @agent AshA2A.HttpJsonFollowups.Agent

  setup do
    {_sup, _registry} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [@agent])

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
      {:ok,
       public
       |> Map.put("name", "w20-extended")
       |> Map.put("signatures", [%{"signature" => "stale"}])}
    end

    server = start(extended_card: provider)

    resp =
      Req.get!(url: server.base_url <> "/extendedAgentCard", headers: [authorization: "Bearer t"])

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
          "configuration" => %{
            "returnImmediately" => true,
            "acceptedOutputModes" => ["text/plain"]
          }
        }
      )

    assert resp.status == 200
    assert %{"task" => %{"id" => _}} = resp.body
  end

  test "push list on a push-disabled server stays -32003 even with paging params" do
    server = start()

    resp =
      Req.get!(url: server.base_url <> "/tasks/x/pushNotificationConfigs?pageSize=1&pageToken=")

    assert resp.status == 400
  end

  test "GET :subscribe on a non-terminal task streams the snapshot; terminal 400; unknown 404" do
    server = start()

    resp =
      Req.post!(url: server.base_url <> "/message:send", json: %{"message" => parked_message()})

    assert %{"task" => %{"id" => id, "status" => %{"state" => "TASK_STATE_INPUT_REQUIRED"}}} =
             resp.body

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

# --- SOURCE: test/http_json_generation_stream_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.HttpJsonGenerationStream.Resource do
  @moduledoc "Real fixture: `:converse` parks in input_required when :text is omitted."

  use Ash.Resource,
    domain: AshA2A.HttpJsonGenerationStream.Domain,
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

defmodule AshA2A.HttpJsonGenerationStream.Domain do
  @moduledoc false
  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.HttpJsonGenerationStream.Resource)
  end
end

defmodule AshA2A.HttpJsonGenerationStream.Agent do
  @moduledoc false
  use AshA2A.Agent,
    resource_or_domain: AshA2A.HttpJsonGenerationStream.Resource,
    name: "v9_http_json_agent"
end

defmodule AshA2A.HttpJsonGenerationStream.Pipeline do
  @moduledoc "Stamps a verified identity (and an opt-in second one) on every request."

  @behaviour Plug

  def init(opts) when is_map(opts), do: opts
  def init(opts), do: AshA2A.Transport.HTTPJSON.init(opts)

  def call(conn, opts) do
    conn = AshA2A.Protocol.Plug.Auth.put_identity(conn, %{identity: "alice"})
    AshA2A.Transport.HTTPJSON.call(conn, opts)
  end
end

defmodule AshA2A.HttpJsonGenerationStreamTest do
  @moduledoc """
  V9 court: the v1.1 REST/HTTP+JSON binding -- `POST /message:live`
  (downlink SSE + ack-only uplink), `ifGenerationMatch` (409), long-poll
  `currentGeneration`, `timelineLength`, `lastSeenGeneration` resume,
  `artifactUpdates` refusal, and `messageUpdate` version gating. Real Bandit,
  real agent, real `Req`; waits are deadline-bounded observations, not sleeps.
  """

  use ExUnit.Case, async: false

  @moduletag :serial_shard

  alias AshA2A.Protocol.{Artifact, Message, Part}
  alias AshA2A.Test.EphemeralHttp
  alias AshA2A.HttpJsonGenerationStream.Pipeline

  @agent AshA2A.HttpJsonGenerationStream.Agent
  @v11 [{"a2a-version", "1.1"}]
  @deadline_ms 5_000

  setup do
    {_sup, _registry} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [@agent])

    versions = Enum.uniq(AshA2A.Protocol.Version.supported_default() ++ ["1.0", "1.1"])
    opts = [agent: @agent, base_url: "http://127.0.0.1/fixture", versions: versions]

    previous = Application.get_env(:ash_a2a, :long_poll_timeout_ms)
    Application.put_env(:ash_a2a, :long_poll_timeout_ms, 10_000)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:ash_a2a, :long_poll_timeout_ms, previous),
        else: Application.delete_env(:ash_a2a, :long_poll_timeout_ms)
    end)

    {:ok, server: EphemeralHttp.start!({Pipeline, Pipeline.init(opts)})}
  end

  # -- helpers -------------------------------------------------------------------

  defp wire(parts), do: AshA2A.Protocol.JSON.encode!(Message.new_user(parts))
  defp parked, do: wire([Part.Data.new(%{})])
  defp completing, do: wire([Part.Data.new(%{"text" => "hi"})])

  defp send_message(server, message, configuration \\ %{}, headers \\ @v11) do
    Req.post!(
      url: server.base_url <> "/message:send",
      json: %{"message" => message, "configuration" => configuration},
      headers: headers,
      retry: false
    )
  end

  defp park_task(server) do
    resp = send_message(server, parked())
    assert %{"task" => %{"id" => id} = task} = resp.body
    {id, gen(task)}
  end

  defp gen(%{"generation" => g}) do
    {n, ""} = g |> to_string() |> Integer.parse()
    n
  end

  defp frames(buffer) do
    buffer
    |> String.split("\n\n")
    |> Enum.drop(-1)
    |> Enum.flat_map(fn
      "data: " <> json -> [Jason.decode!(json)]
      _comment -> []
    end)
  end

  # Opens an SSE request in a task that forwards every chunk to the test process.
  defp open_sse(method, url, json \\ nil, headers \\ @v11) do
    parent = self()
    ref = make_ref()

    task =
      Task.async(fn ->
        req_opts =
          [
            method: method,
            url: url,
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
          ] ++ if(json, do: [json: json], else: [])

        Req.request!(req_opts)
      end)

    # on_exit runs in a different process than the Task owner: kill by pid.
    on_exit(fn -> Process.exit(task.pid, :kill) end)
    {ref, task}
  end

  # The downlink's `a2a-live-session-id` response header (deadline-bounded).
  defp live_session_id(ref) do
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

  defp status_updates(frames), do: Enum.filter(frames, &Map.has_key?(&1, "statusUpdate"))

  defp live_url(server), do: server.base_url <> "/message:live"

  defp live_send_body(message), do: %{"sendMessage" => %{"message" => message}}

  # -- POST /message:live ---------------------------------------------------------

  test "live downlink opens with the task snapshot, then uplink events arrive on the downlink only",
       %{
         server: server
       } do
    {ref, _task} = open_sse(:post, live_url(server), live_send_body(parked()))

    {frames0, buffer} = collect_until(ref, "", &(&1 != []))
    assert %{"task" => %{"id" => id}} = hd(frames0)

    uplink = fn ->
      Req.post!(
        url: live_url(server),
        json: live_send_body(Map.put(parked(), "taskId", id)),
        headers: @v11,
        retry: false
      )
    end

    # taskId-correlated uplink: ack Task only (bare task JSON), no event frames.
    ack = uplink.()
    assert ack.status == 200
    assert %{"id" => ^id} = ack.body
    refute Map.has_key?(ack.body, "statusUpdate")

    {_frames1, buffer} = collect_until(ref, buffer, &(length(status_updates(&1)) >= 1))

    ack2 = uplink.()
    assert ack2.status == 200

    {frames2, _buffer} = collect_until(ref, buffer, &(length(status_updates(&1)) >= 2))
    gens = frames2 |> status_updates() |> Enum.map(&gen(&1["statusUpdate"]))

    # one event per uplink: strictly increasing, no duplicates, snapshot never replayed
    assert gens == Enum.uniq(gens)
    assert gens == Enum.sort(gens)
    assert length(Enum.filter(frames2, &Map.has_key?(&1, "task"))) == 1
  end

  test "a live uplink naming another task is a 400 and a StreamError on the downlink", %{
    server: server
  } do
    {ref, _task} = open_sse(:post, live_url(server), live_send_body(parked()))
    {[%{"task" => %{"id" => _id}} | _], buffer} = collect_until(ref, "", &(&1 != []))
    sid = live_session_id(ref)

    bad =
      Req.post!(
        url: live_url(server),
        json: %{"sendMessage" => %{"message" => Map.put(parked(), "taskId", "some-other-task")}},
        headers: @v11 ++ [{"a2a-live-session-id", sid}],
        retry: false
      )

    assert bad.status == 400

    {frames, _} =
      collect_until(ref, buffer, fn fs -> Enum.any?(fs, &Map.has_key?(&1, "error")) end)

    assert %{"error" => %{"code" => "INVALID_ARGUMENT"}} =
             Enum.find(frames, &Map.has_key?(&1, "error"))
  end

  test "live downlink on an unknown task frames a StreamError and never a transport failure", %{
    server: server
  } do
    {ref, _task} =
      open_sse(:post, live_url(server), %{"subscribe" => %{"taskId" => "no-such-task"}})

    {frames, _} = collect_until(ref, "", &(&1 != []))
    assert [%{"error" => %{"code" => "TASK_NOT_FOUND", "taskId" => "no-such-task"}} | _] = frames
  end

  test "live downlink with an unknown payload kind frames UNKNOWN_PAYLOAD", %{server: server} do
    {ref, _task} = open_sse(:post, live_url(server), %{"telepathy" => %{}})
    {frames, _} = collect_until(ref, "", &(&1 != []))
    assert [%{"error" => %{"code" => "UNKNOWN_PAYLOAD"}} | _] = frames
  end

  test "live uplink with an unknown session id is a 400 JSON error", %{server: server} do
    resp =
      Req.post!(
        url: live_url(server) <> "?live_session_id=expired",
        json: live_send_body(parked()),
        headers: @v11,
        retry: false
      )

    assert resp.status == 400
    assert %{"error" => %{"code" => 400}} = resp.body
  end

  # -- ifGenerationMatch ------------------------------------------------------------

  test "ifGenerationMatch: stale generation is 409 TASK_GENERATION_MISMATCH, matching generation succeeds",
       %{
         server: server
       } do
    {id, generation} = park_task(server)
    follow_up = Map.put(parked(), "taskId", id)

    stale = send_message(server, follow_up, %{"ifGenerationMatch" => generation + 5})
    assert stale.status == 409

    assert %{"error" => %{"code" => 409, "status" => "ABORTED", "details" => details}} =
             stale.body

    assert Enum.any?(details, &(&1["reason"] == "TASK_GENERATION_MISMATCH"))

    ok = send_message(server, follow_up, %{"ifGenerationMatch" => generation})
    assert ok.status == 200
    assert %{"task" => %{"id" => ^id}} = ok.body
  end

  # -- GET /tasks/{id}: long-poll + timelineLength ------------------------------------

  test "currentGeneration below the task's generation answers immediately", %{server: server} do
    {id, _generation} = park_task(server)

    poll =
      Task.async(fn ->
        Req.get!(
          url: server.base_url <> "/tasks/#{id}?currentGeneration=0",
          headers: @v11,
          retry: false
        )
      end)

    assert %Req.Response{status: 200, body: %{"id" => ^id}} = Task.await(poll, @deadline_ms)
  end

  test "currentGeneration at the task's generation parks until the task advances", %{
    server: server
  } do
    {id, generation} = park_task(server)

    poll =
      Task.async(fn ->
        Req.get!(
          url: server.base_url <> "/tasks/#{id}?currentGeneration=#{generation}",
          headers: @v11,
          retry: false,
          receive_timeout: 15_000
        )
      end)

    # Still parked: no answer within a short observation window.
    assert Task.yield(poll, 250) == nil

    woke = send_message(server, Map.put(parked(), "taskId", id))
    assert woke.status == 200

    assert %Req.Response{status: 200, body: body} = Task.await(poll, @deadline_ms)
    assert gen(body) > generation
  end

  test "invalid query integers are 400", %{server: server} do
    {id, _} = park_task(server)

    for query <- ["timelineLength=-1", "currentGeneration=abc", "timelineLength=x"] do
      resp =
        Req.get!(url: server.base_url <> "/tasks/#{id}?" <> query, headers: @v11, retry: false)

      assert resp.status == 400, query
    end
  end

  test "timelineLength truncates GET /tasks/{id} and GET /tasks", %{server: server} do
    {id, _} = park_task(server)
    _ = send_message(server, Map.put(parked(), "taskId", id))

    full = Req.get!(url: server.base_url <> "/tasks/#{id}", headers: @v11, retry: false)
    assert length(full.body["timeline"] || []) >= 2

    one =
      Req.get!(
        url: server.base_url <> "/tasks/#{id}?timelineLength=1",
        headers: @v11,
        retry: false
      )

    assert length(one.body["timeline"] || []) == 1

    none =
      Req.get!(
        url: server.base_url <> "/tasks/#{id}?timelineLength=0",
        headers: @v11,
        retry: false
      )

    assert (none.body["timeline"] || []) == []

    list =
      Req.get!(url: server.base_url <> "/tasks?timelineLength=1", headers: @v11, retry: false)

    assert list.status == 200
    assert Enum.all?(list.body["tasks"], &(length(&1["timeline"] || []) <= 1))
  end

  # -- SubscribeToTask lastSeenGeneration ----------------------------------------------

  test "subscribe sends the snapshot first; with lastSeenGeneration it sends none", %{
    server: server
  } do
    {id, generation} = park_task(server)

    {ref, _t} = open_sse(:get, server.base_url <> "/tasks/#{id}:subscribe")
    {[first | _], _} = collect_until(ref, "", &(&1 != []))
    assert %{"task" => %{"id" => ^id}} = first

    {ref2, _t2} =
      open_sse(:get, server.base_url <> "/tasks/#{id}:subscribe?lastSeenGeneration=#{generation}")

    # The subscription is registered once an event can be observed: advance the task.
    advance = send_message(server, Map.put(parked(), "taskId", id))
    assert advance.status == 200

    {frames, _} = collect_until(ref2, "", &(&1 != []))
    refute Enum.any?(frames, &Map.has_key?(&1, "task"))
    # v1.1 emits the messageUpdate for the advancing message before the statusUpdate.
    [first_frame | _] = frames
    assert [update] = Map.values(Map.take(first_frame, ["statusUpdate", "messageUpdate"]))
    assert gen(update) > generation
  end

  # -- artifactUpdates -------------------------------------------------------------------

  test "artifactUpdates are refused 400 UNSUPPORTED_OPERATION when the capability is off", %{
    server: server
  } do
    {id, _} = park_task(server)
    artifact = AshA2A.Protocol.JSON.encode!(Artifact.new([Part.Data.new(%{"k" => "v"})]))

    resp =
      Req.post!(
        url: server.base_url <> "/message:send",
        json: %{"artifactUpdates" => [%{"taskId" => id, "artifact" => artifact}]},
        headers: @v11,
        retry: false
      )

    assert resp.status == 400
    assert %{"error" => %{"details" => [%{"reason" => "UNSUPPORTED_OPERATION"} | _]}} = resp.body
  end

  # -- version-gated frames ----------------------------------------------------------------

  test "message:stream emits messageUpdate frames only for A2A-Version >= 1.1, all stamped", %{
    server: server
  } do
    stream = fn headers ->
      Req.post!(
        url: server.base_url <> "/message:stream",
        json: %{"message" => completing()},
        headers: headers,
        retry: false
      )
    end

    new = stream.([{"a2a-version", "1.1"}])
    assert new.status == 200
    new_frames = frames(new.body)
    assert Enum.any?(new_frames, &Map.has_key?(&1, "messageUpdate"))

    final = new_frames |> status_updates() |> List.last()
    assert is_map(final["statusUpdate"]) and Map.has_key?(final["statusUpdate"], "generation")

    old = stream.([{"a2a-version", "1.0"}])
    assert old.status == 200
    old_frames = frames(old.body)
    refute Enum.any?(old_frames, &Map.has_key?(&1, "messageUpdate"))
    assert Enum.any?(old_frames, &Map.has_key?(&1, "statusUpdate"))
  end
end

# --- SOURCE: test/http_json_live_session_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.HttpJsonLiveSession.Resource do
  @moduledoc "Real fixture: `:converse` parks in input_required when :text is omitted."

  use Ash.Resource,
    domain: AshA2A.HttpJsonLiveSession.Domain,
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

defmodule AshA2A.HttpJsonLiveSession.Domain do
  @moduledoc false
  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.HttpJsonLiveSession.Resource)
  end
end

defmodule AshA2A.HttpJsonLiveSession.Agent do
  @moduledoc false
  use AshA2A.Agent,
    resource_or_domain: AshA2A.HttpJsonLiveSession.Resource,
    name: "v14_http_json_agent"
end

defmodule AshA2A.HttpJsonLiveSession.Pipeline do
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

defmodule AshA2A.HttpJsonLiveSessionTest do
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
  alias AshA2A.HttpJsonLiveSession.Pipeline

  @agent AshA2A.HttpJsonLiveSession.Agent
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

# --- SOURCE: test/http_json_plug_wiring_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.HttpJsonPlugWiring.Resource do
  @moduledoc "Real fixture: `:converse` parks in input_required when :text is omitted."

  use Ash.Resource,
    domain: AshA2A.HttpJsonPlugWiring.Domain,
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

defmodule AshA2A.HttpJsonPlugWiring.Domain do
  @moduledoc false
  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.HttpJsonPlugWiring.Resource)
  end
end

defmodule AshA2A.HttpJsonPlugWiring.Agent do
  @moduledoc false
  use AshA2A.Agent,
    resource_or_domain: AshA2A.HttpJsonPlugWiring.Resource,
    name: "w25_http_json_agent"
end

defmodule AshA2A.HttpJsonPlugWiring.Pipeline do
  @moduledoc "Stamps a verified identity on every request."

  @behaviour Plug

  def init(opts) when is_map(opts), do: opts
  def init(opts), do: AshA2A.Transport.HTTPJSON.init(opts)

  def call(conn, opts) do
    conn = AshA2A.Protocol.Plug.Auth.put_identity(conn, %{identity: "alice"})
    AshA2A.Transport.HTTPJSON.call(conn, opts)
  end
end

defmodule AshA2A.HttpJsonPlugWiringTest do
  @moduledoc """
  W25 court: REST binding wiring (W8 error mapping, W12 tenant binding, W15
  request span, W17 traceparent). Real Bandit server, real agent, real `Req`.
  """

  use ExUnit.Case, async: false

  @moduletag :serial_shard

  alias AshA2A.Protocol.{Message, Part}
  alias AshA2A.Test.EphemeralHttp
  alias AshA2A.HttpJsonPlugWiring.Pipeline

  @agent AshA2A.HttpJsonPlugWiring.Agent
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

# --- SOURCE: test/jsonrpc_artifact_resubscribe_test.exs ---
defmodule AshA2A.JsonRpcArtifactResubscribeTest do
  @moduledoc """
  Y2 courts: (1) the JSON-RPC message-less (artifact-only) send honours
  `ifGenerationMatch` (-32010 on a stale value, proceeds on a match);
  (2) `tasks/resubscribe` with `lastSeenGeneration` closes without a snapshot
  at the current generation and replays newer events from the transport event
  log when one exists. Real agents, real transport log, real Plug.Test conns.
  """

  use ExUnit.Case, async: false
  import Plug.Test

  alias AshA2A.A2ATransport.TaskEvents
  alias AshA2A.Protocol.JSONRPC
  alias AshA2A.Protocol.JSONRPC.Error

  defmodule OpenAgent do
    use AshA2A.Protocol.Agent,
      name: "y2-open",
      description: "accepts client artifacts",
      capabilities: %{user_artifacts: true}

    @impl AshA2A.Protocol.Agent
    def handle_message(message, _ctx) do
      case AshA2A.Protocol.Message.text(message) do
        "ask" -> {:input_required, [AshA2A.Protocol.Part.Text.new("more?")]}
        _ -> {:reply, [AshA2A.Protocol.Part.Text.new("ok")]}
      end
    end
  end

  defmodule Handler do
    @behaviour AshA2A.Protocol.JSONRPC

    @impl true
    def handle_send(message, _params, %{agent: agent}) do
      opts = [task_id: message.task_id, context_id: message.context_id]

      case AshA2A.Protocol.call(agent, message, opts) do
        {:ok, _} = ok -> ok
        {:error, :not_found} -> {:error, Error.task_not_found()}
        {:error, _} -> {:error, Error.internal_error()}
      end
    end

    @impl true
    def handle_get(id, _params, %{agent: agent}) do
      case GenServer.call(agent, {:get_task, id}) do
        {:ok, _} = ok -> ok
        {:error, :not_found} -> {:error, Error.task_not_found()}
      end
    end

    @impl true
    def handle_cancel(_id, _params, _ctx), do: {:error, Error.task_not_cancelable()}
  end

  setup do
    start_supervised!({OpenAgent, []})
    :ok
  end

  defp rpc(params) do
    raw = %{"jsonrpc" => "2.0", "id" => 1, "method" => "SendMessage", "params" => params}
    {:reply, resp} = JSONRPC.handle(raw, Handler, %{agent: OpenAgent})
    resp
  end

  defp wire_message(text) do
    %{
      "messageId" => "m-#{System.unique_integer([:positive])}",
      "role" => "ROLE_USER",
      "parts" => [%{"text" => text}]
    }
  end

  defp to_int(v) when is_binary(v), do: String.to_integer(v)
  defp to_int(v), do: v

  defp artifact_update(task_id, id) do
    %{"taskId" => task_id, "artifact" => %{"artifactId" => id, "parts" => [%{"text" => "x"}]}}
  end

  test "artifact-only send: stale ifGenerationMatch -> -32010, matching proceeds" do
    %{"result" => %{"task" => task}} = rpc(%{"message" => wire_message("ask")})
    current = to_int(task["generation"])

    stale =
      rpc(%{
        "artifactUpdates" => [artifact_update(task["id"], "a1")],
        "configuration" => %{"ifGenerationMatch" => current + 5}
      })

    assert stale["error"]["code"] == -32_010
    assert [%{"reason" => "TASK_GENERATION_MISMATCH"}] = stale["error"]["data"]

    ok =
      rpc(%{
        "artifactUpdates" => [artifact_update(task["id"], "a1")],
        "configuration" => %{"ifGenerationMatch" => current}
      })

    assert %{"result" => %{"task" => out}} = ok
    assert to_int(out["generation"]) == current + 1

    # The stale attempt wrote nothing: the only artifact is the matching one.
    assert "a1" in Enum.map(out["artifacts"], & &1["artifactId"])

    # Reusing the pre-write generation is now stale.
    again =
      rpc(%{
        "artifactUpdates" => [artifact_update(task["id"], "a2")],
        "configuration" => %{"ifGenerationMatch" => current}
      })

    assert again["error"]["code"] == -32_010
  end

  describe "tasks/resubscribe lastSeenGeneration" do
    setup do
      transport = :"y2_transport_#{System.unique_integer([:positive])}"
      start_supervised!({AshA2A.A2ATransport, name: transport})

      %{"result" => %{"task" => task}} = rpc(%{"message" => wire_message("done")})
      assert task["status"]["state"] =~ ~r/completed/i
      %{transport: transport, task_id: task["id"], gen: to_int(task["generation"])}
    end

    defp resubscribe(transport, task_id, last_seen) do
      conn(:post, "/", "")
      |> AshA2A.Protocol.Plug.SSE.subscribe_task(OpenAgent, task_id, 7, 200,
        params: %{"lastSeenGeneration" => last_seen},
        version: "1.1",
        transport: transport
      )
    end

    defp frames(conn) do
      for "data: " <> json <- String.split(conn.resp_body, "\n", trim: true),
          do: Jason.decode!(json)["result"]
    end

    test "at the current generation of a terminal task closes with no snapshot", ctx do
      conn = resubscribe(ctx.transport, ctx.task_id, ctx.gen)

      assert conn.state == :chunked
      assert frames(conn) == []
    end

    test "replays newer logged events without a snapshot, then closes", ctx do
      next = ctx.gen + 1

      TaskEvents.publish(
        ctx.transport,
        ctx.task_id,
        "status-update",
        %{
          "statusUpdate" => %{
            "taskId" => ctx.task_id,
            "status" => %{"state" => "TASK_STATE_COMPLETED"},
            "final" => true,
            "generation" => next
          }
        },
        true,
        generation: next
      )

      conn = resubscribe(ctx.transport, ctx.task_id, ctx.gen)
      frames = frames(conn)

      assert [%{"statusUpdate" => update}] = frames
      assert to_int(update["generation"]) == next
      refute Enum.any?(frames, &Map.has_key?(&1, "task"))
    end

    test "without an event log a terminal task keeps the documented -32004 fallback", ctx do
      conn =
        conn(:post, "/", "")
        |> AshA2A.Protocol.Plug.SSE.subscribe_task(OpenAgent, ctx.task_id, 7, 200,
          params: %{"lastSeenGeneration" => ctx.gen},
          version: "1.1"
        )

      assert Jason.decode!(conn.resp_body)["error"]["code"] == -32_004
    end
  end
end

# --- SOURCE: test/jsonrpc_routing_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.JSONRPCRoutingTest do
  @moduledoc """
  W9 items 3 and 8: JSON-RPC routing hardening on `AshA2A.A2ATransport.Plug`
  (unknown method -> -32601, optional `:strict_pascal_case`, the
  `tasks/subscribe` alias, push methods with push disabled -> -32003), the
  alias-table parity court against `AshA2A.Protocol.JSONRPC`'s own source, and
  `GetExtendedAgentCard` with `params` absent. Real conns, real agent.
  """

  use ExUnit.Case, async: true

  alias AshA2A.A2ATransport.Plug, as: TransportPlug
  alias AshA2A.Test.PlugFixture.GreeterAgent

  setup do
    agent = :"w9_routing_agent_#{System.unique_integer([:positive])}"
    {:ok, pid} = GreeterAgent.start_link(name: agent)
    on_exit(fn -> AshA2A.TestSupport.SafeStop.stop(pid) end)
    %{agent: agent}
  end

  def provider(identity, card), do: {:ok, Map.put(card, "w9_sub", identity.sub)}

  defp opts(agent, extra \\ []),
    do: TransportPlug.init([agent: agent, base_url: "http://x/a2a"] ++ extra)

  defp message do
    {:ok, encoded} = AshA2A.Protocol.JSON.encode(AshA2A.Protocol.Message.new_user("hi"))
    encoded
  end

  defp rpc(mod, opts, method, params, identity \\ nil) do
    envelope = %{"jsonrpc" => "2.0", "id" => 1, "method" => method}
    envelope = if params == :absent, do: envelope, else: Map.put(envelope, "params", params)

    conn =
      :post
      |> Plug.Test.conn("/", Jason.encode!(envelope))
      |> Plug.Conn.put_req_header("content-type", "application/json")

    conn = if identity, do: AshA2A.Protocol.Plug.Auth.put_identity(conn, identity), else: conn
    conn = mod.call(conn, opts)
    {conn, Jason.decode!(conn.resp_body)}
  end

  defp code({_conn, body}), do: get_in(body, ["error", "code"])

  describe "unknown methods" do
    test "PascalCase and slash unknowns answer -32601, not a delegate crash", %{agent: agent} do
      o = opts(agent)

      for method <- ["NoSuchMethod", "message/nope", "tasks/unknown", "foo", "agent/other"] do
        assert code(rpc(TransportPlug, o, method, %{})) == -32_601, "method #{inspect(method)}"
      end
    end

    test "an unknown method is still version-gated first (-32009 beats -32601)", %{agent: agent} do
      body =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "NoSuchMethod",
          "params" => %{}
        })

      conn =
        :post
        |> Plug.Test.conn("/", body)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("a2a-version", "9.9")
        |> TransportPlug.call(opts(agent))

      assert %{"error" => %{"code" => -32_009}} = Jason.decode!(conn.resp_body)
    end
  end

  describe ":strict_pascal_case" do
    test "default (off) accepts both spellings", %{agent: agent} do
      o = opts(agent)

      for method <- ["message/send", "SendMessage"] do
        {_conn, body} = rpc(TransportPlug, o, method, %{"message" => message()})
        assert %{"result" => _} = body, method
      end
    end

    test "on: legacy slash names are -32601, PascalCase names still route", %{agent: agent} do
      o = opts(agent, strict_pascal_case: true)

      for method <- [
            "message/send",
            "message/stream",
            "tasks/get",
            "tasks/list",
            "tasks/resubscribe",
            "tasks/subscribe",
            "agent/getAuthenticatedExtendedCard"
          ] do
        assert code(rpc(TransportPlug, o, method, %{"id" => "t"})) == -32_601, method
      end

      assert {_, %{"result" => _}} =
               rpc(TransportPlug, o, "SendMessage", %{"message" => message()})

      # PascalCase still routes: an owner-scoped miss is -32001, not -32601.
      assert code(rpc(TransportPlug, o, "GetTask", %{"id" => "no-such-task"})) == -32_001
    end
  end

  describe "tasks/subscribe alias" do
    test "routes to tasks/resubscribe on A2ATransport.Plug (unknown task -> -32001)", %{
      agent: agent
    } do
      # Transport instance not running -> the resubscribe is delegated to the
      # vendored plug (which needs `streaming` declared to reach the task lookup).
      o =
        opts(agent,
          transport: :"w9_not_running_#{System.unique_integer([:positive])}",
          agent_card_opts: [capabilities: %{streaming: true}]
        )

      assert code(rpc(TransportPlug, o, "tasks/subscribe", %{"id" => "no-such-task"})) == -32_001

      assert code(rpc(TransportPlug, o, "tasks/resubscribe", %{"id" => "no-such-task"})) ==
               -32_001

      assert code(rpc(TransportPlug, o, "SubscribeToTask", %{"id" => "no-such-task"})) == -32_001
    end

    test "routes to tasks/resubscribe on Transport.Plug (unknown task -> -32001)", %{agent: agent} do
      o = AshA2A.Transport.Plug.init(agent: agent, base_url: "http://x/a2a")

      assert code(rpc(AshA2A.Transport.Plug, o, "tasks/subscribe", %{"id" => "no-such-task"})) ==
               -32_001
    end
  end

  describe "alias-table parity" do
    @jsonrpc_src "lib/ash_a2a/protocol/jsonrpc.ex"

    test "the transport routing table equals JSONRPC's alias table" do
      src = File.read!(@jsonrpc_src)
      [_, block] = Regex.run(~r/@method_aliases %\{(.*?)\n  \}/s, src)

      jsonrpc_aliases =
        ~r/"(\w+)" => "([^"]+)"/
        |> Regex.scan(block)
        |> Map.new(fn [_, k, v] -> {k, v} end)

      assert TransportPlug.method_aliases() == jsonrpc_aliases
    end

    test "the canonical methods the transport routes equal JSONRPC's dispatch clauses" do
      src = File.read!(@jsonrpc_src)

      dispatched =
        ~r/defp dispatch\(\s*%Request\{method: "([^"]+)"\}/
        |> Regex.scan(src)
        |> Enum.map(fn [_, m] -> m end)
        |> Enum.sort()

      assert dispatched != []
      assert TransportPlug.canonical_methods() == dispatched

      assert TransportPlug.canonical_methods() ==
               TransportPlug.method_aliases() |> Map.values() |> Enum.sort()
    end

    test "extra (slash) aliases are routing-only and target a canonical method" do
      extra = TransportPlug.extra_method_aliases()
      assert extra["tasks/subscribe"] == "tasks/resubscribe"

      for {alias_name, canonical} <- extra do
        assert canonical in TransportPlug.canonical_methods()
        refute Map.has_key?(TransportPlug.method_aliases(), alias_name)
      end
    end
  end

  describe "push methods with push disabled" do
    @push_methods [
      {"tasks/pushNotificationConfig/set",
       %{
         "taskId" => "t",
         "pushNotificationConfig" => %{"id" => "c", "url" => "https://93.184.215.14/h"}
       }},
      {"tasks/pushNotificationConfig/get", %{"id" => "t", "pushNotificationConfigId" => "c"}},
      {"tasks/pushNotificationConfig/list", %{"id" => "t"}},
      {"tasks/pushNotificationConfig/delete", %{"id" => "t", "pushNotificationConfigId" => "c"}},
      {"CreateTaskPushNotificationConfig",
       %{
         "taskId" => "t",
         "pushNotificationConfig" => %{"id" => "c", "url" => "https://93.184.215.14/h"}
       }},
      {"ListTaskPushNotificationConfigs", %{"id" => "t"}}
    ]

    test "default (push_notifications: false) answers -32003", %{agent: agent} do
      for {method, params} <- @push_methods do
        assert code(rpc(TransportPlug, opts(agent), method, params)) == -32_003, method
      end
    end

    test "push_notifications: true without a running transport instance still answers -32003",
         %{agent: agent} do
      o =
        opts(agent,
          push_notifications: true,
          transport: :"w9_not_running_#{System.unique_integer([:positive])}"
        )

      for {method, params} <- @push_methods do
        assert code(rpc(TransportPlug, o, method, params)) == -32_003, method
      end
    end

    test "Transport.Plug answers -32003 for push methods (no provider)", %{agent: agent} do
      o = AshA2A.Transport.Plug.init(agent: agent, base_url: "http://x/a2a")

      for {method, params} <- @push_methods do
        assert code(rpc(AshA2A.Transport.Plug, o, method, params)) == -32_003, method
      end
    end
  end

  describe "GetExtendedAgentCard with params absent (upstream #2425)" do
    test "serves the extended card on both spellings with no params member", %{agent: agent} do
      o = opts(agent, extended_card: &__MODULE__.provider/2)

      for method <- ["GetExtendedAgentCard", "agent/getAuthenticatedExtendedCard"] do
        {_conn, body} = rpc(TransportPlug, o, method, :absent, %{sub: "u9"})
        assert %{"result" => %{"w9_sub" => "u9", "name" => _}} = body, method
      end
    end

    test "also with params: null and params: {}", %{agent: agent} do
      o = opts(agent, extended_card: &__MODULE__.provider/2)

      for params <- [nil, %{}] do
        {_conn, body} = rpc(TransportPlug, o, "GetExtendedAgentCard", params, %{sub: "u9"})
        assert %{"result" => %{"w9_sub" => "u9"}} = body
      end
    end

    test "absent params without a provider is -32007, never a crash", %{agent: agent} do
      assert code(rpc(TransportPlug, opts(agent), "GetExtendedAgentCard", :absent, %{sub: "u9"})) ==
               -32_007
    end
  end
end

# --- SOURCE: test/live_session_streaming_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.LiveSessionStreaming.LiveAgent do
  @moduledoc false
  use AshA2A.Protocol.Agent,
    name: "v5_live",
    description: "v1.1 live session fixture",
    capabilities: %{streaming: true, user_artifacts: true}

  alias AshA2A.Protocol.{Message, Part}

  @impl AshA2A.Protocol.Agent
  def handle_message(message, _context) do
    case Message.text(message) do
      "slow" ->
        send(:v5_probe, {:handler_started, self()})

        receive do
          :release -> {:reply, [Part.Text.new("slow done")]}
        end

      "answer" ->
        {:reply, [Part.Text.new("done")]}

      _ask ->
        {:input_required, [Part.Text.new("which one?")]}
    end
  end
end

defmodule AshA2A.LiveSessionStreaming.StreamOnlyAgent do
  @moduledoc false
  use AshA2A.Protocol.Agent,
    name: "v5_stream_only",
    description: "streaming without userArtifacts",
    capabilities: %{streaming: true}

  @impl AshA2A.Protocol.Agent
  def handle_message(_message, _context),
    do: {:input_required, [AshA2A.Protocol.Part.Text.new("more?")]}
end

defmodule AshA2A.LiveSessionStreaming.PlainAgent do
  @moduledoc false
  use AshA2A.Protocol.Agent, name: "v5_plain", description: "no capabilities"

  @impl AshA2A.Protocol.Agent
  def handle_message(_message, _context),
    do: {:reply, [AshA2A.Protocol.Part.Text.new("ok")]}
end

defmodule AshA2A.LiveSessionStreamingTest do
  use ExUnit.Case, async: false

  alias AshA2A.Protocol.{Message, StreamError}
  alias AshA2A.Protocol.Event.{ArtifactUpdate, StatusUpdate}
  alias AshA2A.Protocol.Task, as: T
  alias AshA2A.Transport.Live
  alias AshA2A.LiveSessionStreaming.{LiveAgent, PlainAgent, StreamOnlyAgent}

  setup do
    unless Process.whereis(AshA2A.Transport.Live.Registry),
      do: start_supervised!(Live.Supervisor)

    Process.register(self(), :v5_probe)
    :ok
  end

  defp start_agent(module) do
    name = :"v5_agent_#{System.unique_integer([:positive])}"

    start_supervised!(%{
      id: name,
      start: {module, :start_link, [[name: name]]}
    })

    name
  end

  defp msg(text, extra \\ %{}) do
    Map.merge(
      %{
        "messageId" => "m-#{System.unique_integer([:positive])}",
        "role" => "user",
        "parts" => [%{"text" => text}]
      },
      extra
    )
  end

  defp send_req(text, extra \\ %{}), do: %{"sendMessage" => %{"message" => msg(text, extra)}}

  defp open!(agent) do
    {:ok, session} = Live.open(agent, %{}, self())
    {session, Live.session_id(session)}
  end

  defp open_bound_on_ask(agent) do
    {session, sid} = open!(agent)
    assert :ok = Live.uplink(session, send_req("ask"))
    assert_receive {:a2a_live, ^sid, %T{status: %{state: :input_required}} = task}, 2_000
    {session, sid, task}
  end

  test "send_message opens with a snapshot, input_required, then a second message on the same stream" do
    agent = start_agent(LiveAgent)
    {session, sid, task} = open_bound_on_ask(agent)

    assert is_binary(task.id)
    refute Map.has_key?(task.metadata, :stream)

    # second message: no taskId, applies to the bound task
    assert :ok = Live.uplink(session, send_req("answer"))

    assert_receive {:a2a_live, ^sid, %StatusUpdate{status: %{state: :completed}} = status}, 2_000
    assert status.task_id == task.id
    assert is_integer(status.generation)
    assert_receive {:a2a_live_closed, ^sid, :terminal}, 2_000

    # downlink closed: session process cleaned itself up
    ref = Process.monitor(session)
    assert_receive {:DOWN, ^ref, :process, ^session, _}, 2_000
  end

  test "request naming a different task is a StreamError and the stream stays open" do
    agent = start_agent(LiveAgent)
    {session, sid, _task} = open_bound_on_ask(agent)

    bad = send_req("answer", %{"messageId" => "wrong-task-1", "taskId" => "tsk-someone-else"})
    assert :ok = Live.uplink(session, bad)

    assert_receive {:a2a_live, ^sid,
                    %StreamError{code: "INVALID_ARGUMENT", reference_id: "wrong-task-1"}},
                   2_000

    assert Process.alive?(session)

    # still usable
    assert :ok = Live.uplink(session, send_req("answer"))
    assert_receive {:a2a_live, ^sid, %StatusUpdate{status: %{state: :completed}}}, 2_000
  end

  test "subscribe after the first request is a StreamError, stream stays open" do
    agent = start_agent(LiveAgent)
    {session, sid, task} = open_bound_on_ask(agent)

    assert :ok = Live.uplink(session, %{"subscribe" => %{"taskId" => task.id}})
    assert_receive {:a2a_live, ^sid, %StreamError{code: "FAILED_PRECONDITION"}}, 2_000
    assert Process.alive?(session)
  end

  test "unknown payload kind and malformed requests are StreamErrors" do
    agent = start_agent(LiveAgent)
    {session, sid, _task} = open_bound_on_ask(agent)

    assert :ok = Live.uplink(session, %{"futureThing" => %{"x" => 1}})
    assert_receive {:a2a_live, ^sid, %StreamError{code: "UNIMPLEMENTED"}}, 2_000

    bad = %{
      "sendMessage" => %{
        "message" => %{
          "messageId" => "bad-1",
          "role" => "not-a-role",
          "parts" => [%{"text" => "x"}]
        }
      }
    }

    assert :ok = Live.uplink(session, bad)

    assert_receive {:a2a_live, ^sid,
                    %StreamError{code: "INVALID_ARGUMENT", reference_id: "bad-1"}},
                   2_000

    assert Process.alive?(session)
  end

  test "agent not accepting input is UNAVAILABLE while a send is in flight" do
    agent = start_agent(LiveAgent)
    {session, sid} = open!(agent)

    assert :ok = Live.uplink(session, send_req("slow"))
    assert_receive {:handler_started, handler}, 2_000

    assert :ok = Live.uplink(session, send_req("answer", %{"messageId" => "busy-1"}))

    assert_receive {:a2a_live, ^sid, %StreamError{code: "UNAVAILABLE", reference_id: "busy-1"}},
                   2_000

    send(handler, :release)
    assert_receive {:a2a_live, ^sid, %T{status: %{state: :completed}}}, 2_000
    assert_receive {:a2a_live_closed, ^sid, :terminal}, 2_000
  end

  test "subscribe-first opens with a snapshot of an existing task" do
    agent = start_agent(LiveAgent)
    {:ok, task} = AshA2A.Protocol.call(agent, "ask")
    {session, sid} = open!(agent)

    assert :ok = Live.uplink(session, %{"subscribe" => %{"taskId" => task.id}})
    assert_receive {:a2a_live, ^sid, %T{id: id, status: %{state: :input_required}}}, 2_000
    assert id == task.id
  end

  test "subscribe to an unknown task is not_found" do
    agent = start_agent(LiveAgent)
    {session, _sid} = open!(agent)

    assert {:error, :not_found} =
             Live.uplink(session, %{"subscribe" => %{"taskId" => "tsk-nope"}})

    # first request failed: stream is still unbound and usable
    assert :ok = Live.uplink(session, send_req("ask"))
  end

  test "subscribe with lastSeenGeneration skips the snapshot; unreplayable generation resyncs" do
    agent = start_agent(LiveAgent)
    {:ok, task} = AshA2A.Protocol.call(agent, "ask")
    seen = T.Generation.generation_of(task)

    {session, sid} = open!(agent)

    assert :ok =
             Live.uplink(session, %{
               "subscribe" => %{"taskId" => task.id, "lastSeenGeneration" => seen}
             })

    assert {:ack, %T{}} = Live.uplink_call(agent, %{}, send_req("answer", %{"taskId" => task.id}))

    assert_receive {:a2a_live, ^sid, first}, 2_000
    refute match?(%T{}, first)
    assert_receive {:a2a_live, ^sid, %StatusUpdate{status: %{state: :completed}}}, 2_000

    # a generation the server cannot replay from (in the future) -> snapshot
    agent2 = start_agent(LiveAgent)
    {:ok, task2} = AshA2A.Protocol.call(agent2, "ask")
    {session2, sid2} = open!(agent2)

    assert :ok =
             Live.uplink(session2, %{
               "subscribe" => %{"taskId" => task2.id, "lastSeenGeneration" => 9_999}
             })

    assert_receive {:a2a_live, ^sid2, %T{id: id2}}, 2_000
    assert id2 == task2.id
  end

  test "ack-only uplink call never duplicates events on the downlink" do
    agent = start_agent(LiveAgent)
    {_session, sid, task} = open_bound_on_ask(agent)

    assert {:ack, %T{id: id}} =
             Live.uplink_call(agent, %{}, send_req("answer", %{"taskId" => task.id}))

    assert id == task.id

    assert_receive {:a2a_live_closed, ^sid, :terminal}, 2_000

    # session is gone, so the mailbox is complete: exactly one completed status
    events = drain(sid)
    completed = Enum.filter(events, &match?(%StatusUpdate{status: %{state: :completed}}, &1))
    assert length(completed) == 1
    refute Enum.any?(events, &match?(%T{}, &1))
  end

  test "uplink_call routes by live_session_id and rejects unknown sessions" do
    agent = start_agent(LiveAgent)
    {_session, sid, _task} = open_bound_on_ask(agent)

    assert {:error, :unknown_session} =
             Live.uplink_call(agent, %{live_session_id: "live-nope"}, send_req("answer"))

    assert {:ack, %T{}} =
             Live.uplink_call(agent, %{live_session_id: sid}, send_req("answer"))

    assert_receive {:a2a_live, ^sid, %StatusUpdate{status: %{state: :completed}}}, 2_000
  end

  test "uplink_call without any downlink creates the task and returns only an ack" do
    agent = start_agent(LiveAgent)

    assert {:ack, %T{status: %{state: :input_required}}} =
             Live.uplink_call(agent, %{}, send_req("ask"))

    assert {:error, %StreamError{code: "FAILED_PRECONDITION"}} =
             Live.uplink_call(agent, %{}, %{"subscribe" => %{"taskId" => "tsk-x"}})
  end

  test "streaming must be declared" do
    plain = start_agent(PlainAgent)
    assert {:error, :unsupported_operation} = Live.open(plain, %{}, self())
    assert {:error, :unsupported_operation} = Live.uplink_call(plain, %{}, send_req("hi"))
  end

  test "artifactUpdates need user_artifacts" do
    agent = start_agent(StreamOnlyAgent)
    {session, sid} = open!(agent)

    req = %{
      "sendMessage" => %{
        "message" => msg("hi", %{"messageId" => "art-msg-1"}),
        "artifactUpdates" => [
          %{"artifact" => %{"artifactId" => "a1", "parts" => [%{"text" => "data"}]}}
        ]
      }
    }

    assert :ok = Live.uplink(session, req)

    assert_receive {:a2a_live, ^sid,
                    %StreamError{code: "UNSUPPORTED_OPERATION", reference_id: "art-msg-1"}},
                   2_000
  end

  test "client artifactUpdates are applied and observable as artifact updates" do
    agent = start_agent(LiveAgent)
    {session, sid, task} = open_bound_on_ask(agent)

    req = %{
      "sendMessage" => %{
        "message" => msg("ask again"),
        "artifactUpdates" => [
          %{
            "artifact" => %{"artifactId" => "client-a1", "parts" => [%{"text" => "payload"}]},
            "lastChunk" => true
          }
        ]
      }
    }

    assert :ok = Live.uplink(session, req)

    assert_receive {:a2a_live, ^sid, %ArtifactUpdate{artifact: %{artifact_id: "client-a1"}} = ev},
                   2_000

    assert ev.task_id == task.id
    assert is_integer(ev.generation)
  end

  test "downlink death cleans the session up" do
    agent = start_agent(LiveAgent)
    parent = self()

    dl =
      spawn(fn ->
        send(parent, :dl_up)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :dl_up, 2_000
    {:ok, session} = Live.open(agent, %{}, dl)
    ref = Process.monitor(session)
    send(dl, :stop)
    assert_receive {:DOWN, ^ref, :process, ^session, _}, 2_000
  end

  test "encode/1 yields the StreamResponse wrapper maps" do
    agent = start_agent(LiveAgent)
    {_session, _sid, task} = open_bound_on_ask(agent)

    assert %{"task" => %{"id" => id}} = Live.encode(task)
    assert id == task.id

    err = Live.encode(%StreamError{code: "UNAVAILABLE", reference_id: "r1"})
    assert %{"error" => %{"code" => "UNAVAILABLE", "referenceId" => "r1"}} = err
    assert %{"message" => _} = Live.encode(Message.new_agent("x"))
  end

  defp drain(sid, acc \\ []) do
    receive do
      {:a2a_live, ^sid, event} -> drain(sid, [event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end

# --- SOURCE: test/no_personal_names_test.exs ---
defmodule AshA2A.NoPersonalNamesTest do
  @moduledoc """
  Repo-hygiene guard: personal first names of individuals must not appear in
  any tracked file. Roles (CEO, COO) are used instead. The forbidden names are
  assembled from fragments so this file does not itself contain them.
  """

  use ExUnit.Case, async: true

  @root Path.expand("..", __DIR__)
  @forbidden [~w(Vi nce), ~w(To ny)] |> Enum.map(&Enum.join/1)

  test "no tracked file contains a forbidden personal name" do
    {files, 0} = System.cmd("git", ["ls-files", "-z"], cd: @root)

    offenders =
      for path <- String.split(files, <<0>>, trim: true),
          full = Path.join(@root, path),
          File.regular?(full),
          content = File.read!(full),
          String.valid?(content),
          name <- @forbidden,
          Regex.match?(~r/(?<![a-z])#{name}(?![a-z])/i, content) or
            (Regex.match?(~r/#{name}/, content) and
               not Regex.match?(~r/(province|antony|stony)/i, content)),
          do: {path, name}

    assert offenders == [], "personal names found: #{inspect(Enum.uniq(offenders))}"
  end
end

# --- SOURCE: test/protocol_codec_fidelity_test.exs ---
defmodule AshA2A.ProtocolCodecFidelityTest do
  @moduledoc """
  W2 codec fidelity court: typed OAuth flows, AgentCardSignature, Artifact and
  AgentCard required members, Message/Artifact extensions defaults.
  Reference: priv/a2a_v1_spec_corpus/a2a.proto. Real encode/decode round trips.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Protocol.{Artifact, JSON, Message, Part}
  alias AshA2A.Protocol.SecurityScheme.{OAuth2, OAuthFlows}

  defp card_map(overrides \\ %{}) do
    Map.merge(
      %{
        "name" => "agent",
        "description" => "d",
        "version" => "1.0.0",
        "supportedInterfaces" => [
          %{
            "url" => "https://a.example",
            "protocolBinding" => "JSONRPC",
            "protocolVersion" => "1.0"
          }
        ],
        "capabilities" => %{},
        "defaultInputModes" => ["text/plain"],
        "defaultOutputModes" => ["text/plain"],
        "skills" => []
      },
      overrides
    )
  end

  defp oauth_card(flows) do
    card_map(%{
      "securitySchemes" => %{
        "o" => %{"oauth2SecurityScheme" => %{"flows" => flows}}
      }
    })
  end

  describe "OAuth flows" do
    test "deviceCode round-trips" do
      flows = %{
        "deviceCode" => %{
          "deviceAuthorizationUrl" => "https://auth.example/device",
          "tokenUrl" => "https://auth.example/token",
          "scopes" => %{"read" => "r"}
        }
      }

      assert {:ok, card} = JSON.decode_agent_card(oauth_card(flows))
      assert %OAuth2{flows: ^flows} = card.security_schemes["o"]

      assert {:ok, again} =
               card
               |> JSON.encode_agent_card(url: "https://a.example")
               |> JSON.decode_agent_card()

      assert again.security_schemes["o"].flows == flows
    end

    test "authorizationCode with pkceRequired round-trips and types strictly" do
      flows = %{
        "authorizationCode" => %{
          "authorizationUrl" => "https://a",
          "tokenUrl" => "https://t",
          "scopes" => %{"s" => "d"},
          "pkceRequired" => true
        }
      }

      assert {:ok, card} = JSON.decode_agent_card(oauth_card(flows))

      assert {:ok, again} =
               card
               |> JSON.encode_agent_card(url: "https://a.example")
               |> JSON.decode_agent_card()

      assert again.security_schemes["o"].flows == flows

      assert {:ok, %OAuthFlows.AuthorizationCode{pkce_required: true}} = OAuthFlows.decode(flows)
      assert OAuthFlows.encode(elem(OAuthFlows.decode(flows), 1)) == flows
    end

    test "typed struct encodes on the wire" do
      {:ok, typed} =
        OAuthFlows.decode(%{
          "clientCredentials" => %{"tokenUrl" => "https://t", "scopes" => %{}}
        })

      scheme = %OAuth2{flows: typed}

      card = %AshA2A.Protocol.AgentCard{
        name: "n",
        description: "d",
        url: "http://x",
        version: "1",
        skills: [],
        security_schemes: %{"o" => scheme}
      }

      wire = JSON.encode_agent_card(card, url: "https://a.example")

      assert get_in(wire, ["securitySchemes", "o", "oauth2SecurityScheme", "flows"]) ==
               %{"clientCredentials" => %{"tokenUrl" => "https://t", "scopes" => %{}}}
    end

    test "two flow keys violate the oneof" do
      flows = %{
        "clientCredentials" => %{"tokenUrl" => "https://t", "scopes" => %{}},
        "deviceCode" => %{
          "deviceAuthorizationUrl" => "https://d",
          "tokenUrl" => "https://t",
          "scopes" => %{}
        }
      }

      assert {:error, {:oneof_violation, _, ["clientCredentials", "deviceCode"]}} =
               JSON.decode_agent_card(oauth_card(flows))
    end

    test "unknown flow key and unknown member are rejected" do
      assert {:error, {:unknown_flow, "magic"}} =
               JSON.decode_agent_card(oauth_card(%{"magic" => %{}}))

      assert {:error, {:unknown_field, _}} =
               JSON.decode_agent_card(
                 oauth_card(%{"clientCredentials" => %{"tokenUrl" => "t", "bogus" => 1}})
               )
    end

    test "deviceCode missing deviceAuthorizationUrl is rejected" do
      flows = %{"deviceCode" => %{"tokenUrl" => "https://t", "scopes" => %{}}}

      assert {:error,
              {:missing_field, "oauth2SecurityScheme.flows.deviceCode.deviceAuthorizationUrl"}} =
               JSON.decode_agent_card(oauth_card(flows))
    end

    test "deviceCode missing tokenUrl or scopes is rejected" do
      assert {:error, {:missing_field, _}} =
               JSON.decode_agent_card(
                 oauth_card(%{
                   "deviceCode" => %{"deviceAuthorizationUrl" => "d", "scopes" => %{}}
                 })
               )

      assert {:error, {:missing_field, _}} =
               JSON.decode_agent_card(
                 oauth_card(%{
                   "deviceCode" => %{"deviceAuthorizationUrl" => "d", "tokenUrl" => "t"}
                 })
               )
    end

    test "deprecated implicit and password decode and are flagged" do
      implicit = %{"implicit" => %{"authorizationUrl" => "https://a", "scopes" => %{}}}
      password = %{"password" => %{"tokenUrl" => "https://t"}}

      assert {:ok, _} = JSON.decode_agent_card(oauth_card(implicit))
      assert {:ok, _} = JSON.decode_agent_card(oauth_card(password))
      assert OAuthFlows.deprecated?(implicit)
      assert OAuthFlows.deprecated?("password")
      refute OAuthFlows.deprecated?(%{"deviceCode" => %{}})
    end

    test "wrong member types are rejected" do
      assert {:error, {:invalid_field, _}} =
               JSON.decode_agent_card(
                 oauth_card(%{
                   "authorizationCode" => %{
                     "authorizationUrl" => "a",
                     "tokenUrl" => "t",
                     "scopes" => %{},
                     "pkceRequired" => "yes"
                   }
                 })
               )
    end
  end

  describe "AgentCardSignature" do
    test "valid signature decodes; header optional" do
      sigs = [
        %{"protected" => "p", "signature" => "s"},
        %{"protected" => "p", "signature" => "s", "header" => %{"k" => "v"}}
      ]

      assert {:ok, card} = JSON.decode_agent_card(card_map(%{"signatures" => sigs}))
      assert card.signatures == sigs
    end

    test "missing protected, missing signature, bad header, non-list fail" do
      for bad <- [
            [%{"signature" => "s"}],
            [%{"protected" => "p"}],
            [%{"protected" => "p", "signature" => "s", "header" => "nope"}],
            [%{"protected" => 1, "signature" => "s"}],
            "x"
          ] do
        assert {:error, {:invalid_field, "signatures"}} =
                 JSON.decode_agent_card(card_map(%{"signatures" => bad}))
      end
    end
  end

  describe "AgentCard required members" do
    test "each REQUIRED member is enforced" do
      for key <-
            ~w(name description version supportedInterfaces capabilities defaultInputModes defaultOutputModes skills) do
        assert {:error, {:missing_field, ^key}} =
                 JSON.decode_agent_card(Map.delete(card_map(), key))
      end
    end

    test "protocolBinding must be JSONRPC, GRPC or HTTP+JSON" do
      for b <- ["JSONRPC", "GRPC", "HTTP+JSON"] do
        card = card_map(%{"supportedInterfaces" => [%{"url" => "u", "protocolBinding" => b}]})
        assert {:ok, _} = JSON.decode_agent_card(card)
      end

      card = card_map(%{"supportedInterfaces" => [%{"url" => "u", "protocolBinding" => "SOAP"}]})

      assert {:error, {:invalid_field, "supportedInterfaces.protocolBinding"}} =
               JSON.decode_agent_card(card)
    end
  end

  describe "Artifact" do
    test "requires artifactId and non-empty parts" do
      part = %{"text" => "hi"}

      assert {:error, {:missing_field, "artifactId"}} =
               JSON.decode(%{"parts" => [part]}, :artifact)

      assert {:error, {:invalid_field, "artifactId"}} =
               JSON.decode(%{"artifactId" => "", "parts" => [part]}, :artifact)

      assert {:error, {:empty_field, "parts"}} =
               JSON.decode(%{"artifactId" => "a", "parts" => []}, :artifact)

      assert {:error, {:missing_field, "parts"}} = JSON.decode(%{"artifactId" => "a"}, :artifact)
    end

    test "new/2 extensions default [] and accept :extensions" do
      assert %Artifact{extensions: []} = Artifact.new([Part.Text.new("x")])

      assert %Artifact{extensions: ["urn:x"]} =
               Artifact.new([Part.Text.new("x")], extensions: ["urn:x"])
    end

    test "Message extensions default []" do
      assert %Message{extensions: []} = Message.new_user("hi")
    end
  end
end

# --- SOURCE: test/protocol_codec_v1_1_test.exs ---
defmodule AshA2A.ProtocolCodecV11Test do
  @moduledoc """
  A2A v1.1 codec court: generation, timeline, artifact generations/role,
  MessageUpdate/StreamError, request decoders, and v1.0 legacy tolerance.
  Real encode/decode round trips; no doubles.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Protocol.{Artifact, Message, StreamError, TimelineEntry, JSON, Task}
  alias AshA2A.Protocol.Event.{ArtifactUpdate, MessageUpdate, StatusUpdate}
  alias AshA2A.Protocol.Task.Status

  defp rt(struct, type) do
    {:ok, map} = JSON.encode(struct)
    # force a real JSON hop
    map = map |> Jason.encode!() |> Jason.decode!()
    {map, JSON.decode!(map, type)}
  end

  defp user_msg(id \\ "m1"), do: %{Message.new_user("hi") | message_id: id}

  describe "Task generation + timeline" do
    test "round trips generation and timeline entries" do
      task = %Task{
        id: "t1",
        context_id: "c1",
        status: Status.new(:working),
        generation: 7,
        timeline: [
          %TimelineEntry{entry: {:message, user_msg()}, generation: 2},
          %TimelineEntry{entry: {:status, Status.new(:working)}, generation: 5}
        ]
      }

      {wire, back} = rt(task, :task)
      assert wire["generation"] == 7

      assert [%{"message" => _, "generation" => 2}, %{"status" => _, "generation" => 5}] =
               wire["timeline"]

      assert back.generation == 7

      assert [
               %TimelineEntry{entry: {:message, %Message{}}, generation: 2},
               %TimelineEntry{entry: {:status, %Status{state: :working}}, generation: 5}
             ] = back.timeline
    end

    test "generation 0 is omitted" do
      {:ok, wire} = JSON.encode(%Task{id: "t", status: Status.new(:submitted), generation: 0})
      refute Map.has_key?(wire, "generation")
    end

    test "int64 string generation decodes" do
      back =
        JSON.decode!(
          %{"id" => "t", "status" => %{"state" => "TASK_STATE_WORKING"}, "generation" => "12"},
          :task
        )

      assert back.generation == 12
    end

    test "legacy v1.0 minimal task decodes with default generation and empty timeline" do
      back = JSON.decode!(%{"id" => "t", "status" => %{"state" => "TASK_STATE_WORKING"}}, :task)
      assert back.generation == 1
      assert back.timeline == []
    end

    test "timeline fails open on unknown entry kind" do
      back =
        JSON.decode!(
          %{
            "id" => "t",
            "status" => %{"state" => "TASK_STATE_WORKING"},
            "timeline" => [%{"futureKind" => %{"x" => 1}, "generation" => 4}]
          },
          :task
        )

      assert [%TimelineEntry{entry: {:unknown, %{"futureKind" => %{"x" => 1}}}, generation: 4}] =
               back.timeline

      {:ok, wire} = JSON.encode(hd(back.timeline))
      assert wire == %{"futureKind" => %{"x" => 1}, "generation" => 4}
    end

    test "truncate_timeline keeps the last n" do
      entries = for g <- 1..3, do: %TimelineEntry{entry: {:unknown, nil}, generation: g}
      t = %Task{id: "t", status: Status.new(:working), timeline: entries}
      assert [%{generation: 3}] = Task.truncate_timeline(t, 1).timeline
      assert Task.truncate_timeline(t, 0).timeline == []
      assert Task.truncate_timeline(t, nil) == t
    end
  end

  describe "Artifact" do
    test "start/end generation and role round trip" do
      art = %Artifact{
        Artifact.new([AshA2A.Protocol.Part.Text.new("x")])
        | start_generation: 3,
          end_generation: 9,
          role: :user
      }

      {wire, back} = rt(art, :artifact)
      assert wire["startGeneration"] == 3
      assert wire["endGeneration"] == 9
      assert wire["role"] == "ROLE_USER"
      assert {back.start_generation, back.end_generation, back.role} == {3, 9, :user}
    end

    test "defaults omit the new members" do
      {wire, back} = rt(Artifact.new([AshA2A.Protocol.Part.Text.new("x")]), :artifact)
      refute Map.has_key?(wire, "startGeneration")
      refute Map.has_key?(wire, "role")
      assert {back.start_generation, back.end_generation, back.role} == {nil, nil, nil}
    end
  end

  describe "events" do
    test "status and artifact updates carry generation" do
      {w1, b1} =
        rt(StatusUpdate.new("t", Status.new(:working), generation: 4), :status_update_event)

      assert w1["generation"] == 4 and b1.generation == 4

      art = Artifact.new([AshA2A.Protocol.Part.Text.new("x")])
      {w2, b2} = rt(ArtifactUpdate.new("t", art, generation: 6), :artifact_update_event)
      assert w2["generation"] == 6 and b2.generation == 6
    end

    test "nil generation omitted on events" do
      {:ok, w} = JSON.encode(StatusUpdate.new("t", Status.new(:working)))
      refute Map.has_key?(w, "generation")
    end

    test "MessageUpdate round trips through the StreamResponse wrapper" do
      ev =
        MessageUpdate.new("t", user_msg(),
          context_id: "c",
          generation: 8,
          metadata: %{"k" => "v"}
        )

      {:ok, wrapped} = JSON.encode_stream_response(ev)
      assert Map.keys(wrapped) == ["messageUpdate"]
      back = wrapped |> Jason.encode!() |> Jason.decode!() |> JSON.decode!(:event)

      assert %MessageUpdate{task_id: "t", context_id: "c", generation: 8, metadata: %{"k" => "v"}} =
               back

      assert %Message{} = back.message
    end

    test "StreamError round trips through the StreamResponse wrapper" do
      err = %StreamError{
        task_id: "t",
        code: "INVALID_ARGUMENT",
        message: "bad",
        reference_id: "m1",
        metadata: %{"a" => 1}
      }

      {:ok, wrapped} = JSON.encode_stream_response(err)
      assert %{"error" => %{"code" => "INVALID_ARGUMENT", "referenceId" => "m1"}} = wrapped
      assert ^err = wrapped |> Jason.encode!() |> Jason.decode!() |> JSON.decode!(:event)
    end

    test "unknown StreamResponse payload kind is skipped, not an error" do
      assert {:skip, {:unknown_payload, "futureThing"}} =
               JSON.decode(%{"futureThing" => %{"a" => 1}}, :event)
    end

    test "known v1.0 wrappers still decode" do
      assert %StatusUpdate{} =
               JSON.decode!(
                 %{
                   "statusUpdate" => %{
                     "taskId" => "t",
                     "status" => %{"state" => "TASK_STATE_WORKING"}
                   }
                 },
                 :event
               )
    end
  end

  describe "card + push config" do
    test "userArtifacts capability round trips" do
      card = %AshA2A.Protocol.AgentCard{
        name: "a",
        description: "d",
        url: "https://a",
        version: "1",
        skills: [],
        capabilities: %{user_artifacts: true}
      }

      wire = JSON.encode_agent_card(card, url: "https://a") |> Jason.encode!() |> Jason.decode!()
      assert wire["capabilities"]["userArtifacts"] == true
      assert {:ok, back} = JSON.decode_agent_card(wire)
      assert back.capabilities.user_artifacts == true
    end

    test "push config protocolVersion round trips and is optional" do
      cfg = %AshA2A.Protocol.PushNotificationConfig{url: "https://h", protocol_version: "1.1"}
      {wire, back} = rt(cfg, :push_notification_config)
      assert wire["protocolVersion"] == "1.1"
      assert back.protocol_version == "1.1"

      {w2, b2} =
        rt(%AshA2A.Protocol.PushNotificationConfig{url: "https://h"}, :push_notification_config)

      refute Map.has_key?(w2, "protocolVersion")
      assert b2.protocol_version == nil
    end
  end

  describe "request decoders" do
    @msg %{"messageId" => "m1", "role" => "ROLE_USER", "parts" => [%{"text" => "hi"}]}
    @art_update %{
      "taskId" => "t",
      "contextId" => "c",
      "artifact" => %{"artifactId" => "a1", "parts" => [%{"text" => "x"}], "role" => "ROLE_USER"}
    }

    test "SendMessageRequest legacy v1.0 shape" do
      assert {:ok, %{message: %Message{}, artifact_updates: [], configuration: nil}} =
               JSON.decode_send_message_request(%{"message" => @msg})
    end

    test "message required without artifactUpdates" do
      assert {:error, {:missing_field, "message"}} = JSON.decode_send_message_request(%{})
    end

    test "message optional with artifactUpdates" do
      assert {:ok, %{message: nil, artifact_updates: [%ArtifactUpdate{task_id: "t"} = u]}} =
               JSON.decode_send_message_request(%{"artifactUpdates" => [@art_update]})

      assert u.artifact.role == :user
    end

    test "configuration carries timelineLength, historyLength, ifGenerationMatch" do
      assert {:ok, %{configuration: cfg}} =
               JSON.decode_send_message_request(%{
                 "message" => @msg,
                 "configuration" => %{
                   "timelineLength" => 5,
                   "historyLength" => 2,
                   "ifGenerationMatch" => "9",
                   "returnImmediately" => true
                 }
               })

      assert %{
               timeline_length: 5,
               history_length: 2,
               if_generation_match: 9,
               return_immediately: true
             } = cfg
    end

    test "GetTask / ListTasks / Subscribe v1.1 members" do
      assert {:ok, %{id: "t", timeline_length: 3, current_generation: 4}} =
               JSON.decode_get_task_request(%{
                 "id" => "t",
                 "timelineLength" => 3,
                 "currentGeneration" => 4
               })

      assert {:ok, %{id: "t", current_generation: nil, timeline_length: nil}} =
               JSON.decode_get_task_request(%{"id" => "t"})

      assert {:ok, %{timeline_length: 2}} =
               JSON.decode_list_tasks_request(%{"timelineLength" => 2})

      assert {:ok, %{id: "t", last_seen_generation: 11}} =
               JSON.decode_subscribe_request(%{"id" => "t", "lastSeenGeneration" => 11})

      assert {:ok, %{last_seen_generation: nil}} = JSON.decode_subscribe_request(%{"id" => "t"})
    end

    test "StreamRequest sendMessage / subscribe / unknown payload" do
      assert {:ok, %{tenant: "x", payload: {:send_message, %{message: %Message{}}}}} =
               JSON.decode_stream_request(%{
                 "tenant" => "x",
                 "sendMessage" => %{"message" => @msg}
               })

      assert {:ok, %{payload: {:subscribe, %{id: "t"}}}} =
               JSON.decode_stream_request(%{"subscribe" => %{"id" => "t"}})

      assert {:error, {:unknown_payload, ["futureOp"]}} =
               JSON.decode_stream_request(%{"tenant" => "x", "futureOp" => %{}})
    end
  end
end

# --- SOURCE: test/protocol_downgrade_wire_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ProtocolDowngradeWire.Resource do
  @moduledoc "Real fixture: `:converse` parks in input_required when :text is omitted."

  use Ash.Resource,
    domain: AshA2A.ProtocolDowngradeWire.Domain,
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

defmodule AshA2A.ProtocolDowngradeWire.Domain do
  @moduledoc false
  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.ProtocolDowngradeWire.Resource)
  end
end

defmodule AshA2A.ProtocolDowngradeWire.Agent do
  @moduledoc false
  use AshA2A.Agent,
    resource_or_domain: AshA2A.ProtocolDowngradeWire.Resource,
    name: "t1_downgrade_agent",
    capabilities: %{streaming: true}
end

defmodule AshA2A.ProtocolDowngradeWire.Pipeline do
  @moduledoc false
  @behaviour Plug

  def init(opts), do: AshA2A.Transport.Plug.init(opts)

  def call(conn, opts) do
    conn
    |> AshA2A.Protocol.Plug.Auth.put_identity(%{identity: "alice"})
    |> AshA2A.Transport.Plug.call(opts)
  end
end

defmodule AshA2A.ProtocolDowngradeWireTest do
  @moduledoc """
  T1: an explicit `A2A-Version: 1.0` consumer (the official TCK) never sees
  v1.1-only wire fields; 1.1 and header-less consumers do.
  """

  use ExUnit.Case, async: false

  @moduletag :serial_shard

  alias AshA2A.Protocol.{Message, Part}
  alias AshA2A.Test.EphemeralHttp

  @deadline_ms 5_000
  @v10_keys ["generation", "timeline", "startGeneration", "endGeneration"]

  setup do
    {_sup, _registry} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [
        AshA2A.ProtocolDowngradeWire.Agent
      ])

    versions = Enum.uniq(AshA2A.Protocol.Version.supported_default() ++ ["1.0", "1.1"])

    opts = [
      agent: AshA2A.ProtocolDowngradeWire.Agent,
      base_url: "http://127.0.0.1/t1",
      versions: versions
    ]

    {:ok, server: EphemeralHttp.start!({AshA2A.ProtocolDowngradeWire.Pipeline, opts})}
  end

  defp parked, do: AshA2A.Protocol.JSON.encode!(Message.new_user([Part.Data.new(%{})]))

  defp envelope(method, params),
    do: %{
      "jsonrpc" => "2.0",
      "id" => System.unique_integer([:positive]),
      "method" => method,
      "params" => params
    }

  defp rpc(server, method, params, headers) do
    Req.post!(
      url: server.base_url <> "/",
      json: envelope(method, params),
      headers: headers,
      retry: false
    ).body
  end

  defp send_task(server, headers) do
    assert %{"result" => %{"task" => %{"id" => _} = task}} =
             rpc(server, "message/send", %{"message" => parked()}, headers)

    task
  end

  defp frames(buffer) do
    buffer
    |> String.split("\n\n")
    |> Enum.drop(-1)
    |> Enum.flat_map(fn
      "data: " <> json -> [Jason.decode!(json)]
      _ -> []
    end)
  end

  # Streams message/stream until the first frame carrying `"task"` or a terminal
  # frame arrived, returning every decoded frame.
  defp stream(server, headers) do
    resp =
      Req.post!(
        url: server.base_url <> "/",
        json: envelope("message/stream", %{"message" => parked()}),
        headers: headers,
        retry: false,
        into: :self,
        receive_timeout: 20_000
      )

    assert resp.status == 200
    deadline = System.monotonic_time(:millisecond) + @deadline_ms
    out = collect(resp, "", deadline)
    Req.cancel_async_response(resp)
    out
  end

  defp collect(resp, buffer, deadline) do
    all = frames(buffer)
    remaining = deadline - System.monotonic_time(:millisecond)

    cond do
      Enum.any?(all, &match?(%{"result" => %{"task" => _}}, &1)) and length(all) >= 1 -> all
      remaining <= 0 -> flunk("deadline; frames so far: #{inspect(all)}")
      true -> receive_more(resp, buffer, deadline, remaining)
    end
  end

  defp receive_more(resp, buffer, deadline, remaining) do
    receive do
      msg ->
        case Req.parse_message(resp, msg) do
          {:ok, chunks} ->
            collect(resp, buffer <> for({:data, d} <- chunks, into: "", do: d), deadline)

          _ ->
            collect(resp, buffer, deadline)
        end
    after
      remaining -> flunk("deadline; frames so far: #{inspect(frames(buffer))}")
    end
  end

  defp deep_keys(term, acc \\ [])
  defp deep_keys(%{} = m, acc), do: Enum.reduce(m, acc, fn {k, v}, a -> deep_keys(v, [k | a]) end)
  defp deep_keys(l, acc) when is_list(l), do: Enum.reduce(l, acc, &deep_keys/2)
  defp deep_keys(_, acc), do: acc

  test "1.0 message/send result carries none of the v1.1 keys", %{server: server} do
    task = send_task(server, [{"a2a-version", "1.0"}])
    keys = deep_keys(task)
    for k <- @v10_keys, do: refute(k in keys, "leaked #{k}: #{inspect(task)}")
  end

  test "1.1 and header-less message/send results keep generation", %{server: server} do
    assert %{"generation" => _} = send_task(server, [{"a2a-version", "1.1"}])
    assert %{"generation" => _} = send_task(server, [])
  end

  test "1.0 message/stream frames carry none of the v1.1 keys", %{server: server} do
    frames = stream(server, [{"a2a-version", "1.0"}])
    assert frames != []
    keys = deep_keys(frames)
    for k <- @v10_keys, do: refute(k in keys, "leaked #{k}: #{inspect(frames)}")
  end

  test "1.1 message/stream frames carry generation", %{server: server} do
    assert "generation" in deep_keys(stream(server, [{"a2a-version", "1.1"}]))
  end

  test "header-less message/stream frames carry generation", %{server: server} do
    assert "generation" in deep_keys(stream(server, []))
  end
end

# --- SOURCE: test/protocol_error_tables_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ProtocolErrorTablesTest do
  @moduledoc """
  Lane W14: additive spec tables and ErrorInfo builders over
  `AshA2A.Protocol.JSONRPC.Error`. Real modules, no mocks.
  """

  use ExUnit.Case, async: false

  alias AshA2A.Protocol.JSONRPC.Error

  @info "type.googleapis.com/google.rpc.ErrorInfo"

  # code => {spec http, grpc numeric, google.rpc name}
  @spec_rows %{
    -32_001 => {404, 5, "NOT_FOUND"},
    # Pinned TCK: -32002 -> HTTP 409; -32003/-32004/-32009 -> gRPC UNIMPLEMENTED(12)
    # (the google.rpc name column is the HTTP error.status string, unchanged).
    -32_002 => {409, 9, "FAILED_PRECONDITION"},
    -32_003 => {400, 12, "FAILED_PRECONDITION"},
    -32_004 => {400, 12, "FAILED_PRECONDITION"},
    -32_005 => {415, 3, "INVALID_ARGUMENT"},
    -32_006 => {502, 13, "INTERNAL"},
    -32_007 => {400, 9, "FAILED_PRECONDITION"},
    -32_008 => {400, 9, "FAILED_PRECONDITION"},
    -32_009 => {400, 12, "FAILED_PRECONDITION"}
  }

  test "spec tables match the nine upstream rows" do
    for {code, {http, grpc, name}} <- @spec_rows do
      assert Error.spec_http_status(code) == http
      assert Error.grpc_status(code) == grpc
      assert Error.status_name_for_code(code) == name
    end

    assert Error.grpc_status(-32_603) == nil
    assert Error.spec_http_status(-32_000) == nil
  end

  test "unauthenticated / permission_denied carry ErrorInfo and keep -32600" do
    for {fun, reason} <- [
          unauthenticated: "UNAUTHENTICATED",
          permission_denied: "PERMISSION_DENIED"
        ] do
      wire = Error.to_map(apply(Error, fun, ["nope"]))
      assert wire["code"] == -32_600

      assert [%{"@type" => @info, "domain" => "a2a-protocol.org", "reason" => ^reason} = i] =
               wire["data"]

      assert i["metadata"] == %{"detail" => "nope"}
      assert Error.status_name_for_reason(reason) == reason
    end
  end

  test "taskId and supportedVersions metadata; legacy shape unchanged without opts" do
    wire = Error.to_map(Error.task_not_found(nil, task_id: "tsk-1"))
    assert [%{"reason" => "TASK_NOT_FOUND", "metadata" => %{"taskId" => "tsk-1"}}] = wire["data"]

    wire = Error.to_map(Error.task_not_cancelable("terminal", task_id: "tsk-2"))

    assert [
             %{
               "reason" => "TASK_NOT_CANCELABLE",
               "metadata" => %{"taskId" => "tsk-2", "detail" => "terminal"}
             }
           ] =
             wire["data"]

    wire = Error.to_map(Error.version_not_supported("9.9", supported_versions: ["1.0", "0.3"]))

    assert [
             %{
               "reason" => "VERSION_NOT_SUPPORTED",
               "metadata" => %{"supportedVersions" => "1.0,0.3", "detail" => "9.9"}
             }
           ] =
             wire["data"]

    assert Error.to_map(Error.task_not_found()) ==
             Error.to_map(%Error{code: -32_001, message: "Task not found", data: nil})
  end

  test "server_busy variants" do
    for {kind, reason} <- [unavailable: "UNAVAILABLE", resource_exhausted: "RESOURCE_EXHAUSTED"] do
      wire = Error.to_map(Error.server_busy(nil, kind))
      assert wire["code"] == -32_000
      assert [%{"reason" => ^reason, "domain" => "a2a-protocol.org"}] = wire["data"]
    end
  end

  test "BadRequest violations builder and opt-in ToA2AError details" do
    wire =
      Error.to_map(Error.invalid_params_with_violations("bad", [{:status, "must be one of"}]))

    assert [
             %{"reason" => "INVALID_PARAMS"},
             %{
               "@type" => "type.googleapis.com/google.rpc.BadRequest",
               "fieldViolations" => [%{"field" => "status", "description" => "must be one of"}]
             }
           ] =
             wire["data"]

    arg =
      Ash.Error.Changes.InvalidArgument.exception(
        field: :status,
        message: "must be one of",
        value: "x"
      )

    invalid = %Ash.Error.Invalid{errors: [arg]}

    # default: legacy single-ErrorInfo shape
    assert [_one] = AshA2A.ToA2AError.to_a2a_error(invalid, 1)["error"]["data"]

    Application.put_env(:ash_a2a, :bad_request_details, true)

    try do
      assert [%{"reason" => "INVALID_PARAMS"}, %{"fieldViolations" => [%{"field" => "status"}]}] =
               AshA2A.ToA2AError.to_a2a_error(invalid, 1)["error"]["data"]
    after
      Application.delete_env(:ash_a2a, :bad_request_details)
    end
  end
end

# --- SOURCE: test/protocol_version_negotiation_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ProtocolVersionNegotiationTest do
  @moduledoc """
  W9 item 1: A2A-Version negotiation is configurable per plug (`:versions`)
  and v1.1 is supported by default. Real `Plug.Test` conns against the three
  HTTP JSON-RPC plugs fronting a real agent GenServer; no mocks.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Protocol.Version
  alias AshA2A.Test.PlugFixture.GreeterAgent

  setup do
    agent = :"w9_versions_agent_#{System.unique_integer([:positive])}"
    {:ok, pid} = GreeterAgent.start_link(name: agent)
    on_exit(fn -> AshA2A.TestSupport.SafeStop.stop(pid) end)
    %{agent: agent}
  end

  defp message do
    {:ok, encoded} = AshA2A.Protocol.JSON.encode(AshA2A.Protocol.Message.new_user("hi"))
    encoded
  end

  defp send_message(mod, opts, headers, query \\ "") do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "message/send",
        "params" => %{"message" => message()}
      })

    :post
    |> Plug.Test.conn("/" <> query, body)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.merge_req_headers(headers)
    |> mod.call(opts)
  end

  defp plugs(agent, extra \\ []) do
    base = [agent: agent, base_url: "http://localhost:4000/a2a"] ++ extra

    [
      {"Protocol.Plug", AshA2A.Protocol.Plug, AshA2A.Protocol.Plug.init(base)},
      {"A2ATransport.Plug", AshA2A.A2ATransport.Plug, AshA2A.A2ATransport.Plug.init(base)},
      {"Transport.Plug", AshA2A.Transport.Plug, AshA2A.Transport.Plug.init(base)}
    ]
  end

  describe "Version" do
    test "v1.1 is supported by default and advertised as the protocol version" do
      assert Version.protocol_version() == "1.1"
      assert "1.1" in Version.supported_default()
      assert Version.supported_default() == ["0.3", "1.0", "1.1"]
      assert Version.validate("1.1", Version.supported_default()) == :ok
      assert Version.validate("1.2", Version.supported_default()) == {:error, "1.2"}
    end

    test "at_least?/2 compares Major.Minor and ignores the patch" do
      assert Version.at_least?("1.1", "1.1")
      assert Version.at_least?("1.1.4", "1.1")
      assert Version.at_least?("2.0", "1.1")
      refute Version.at_least?("1.0", "1.1")
      refute Version.at_least?("1.0.9", "1.1")
      refute Version.at_least?("0.3", "1.1")
      refute Version.at_least?("garbage", "1.1")
      refute Version.at_least?(nil, "1.1")
    end

    test "negotiated_version/1 normalizes header values and defaults to 0.3" do
      assert Version.negotiated_version(["1.1.2"]) == "1.1"
      assert Version.negotiated_version("1.0") == "1.0"
      assert Version.negotiated_version([]) == "0.3"
      assert Version.negotiated_version(nil) == "0.3"
    end

    test "negotiated_version/1 on a conn: header wins, else the A2A-Version query parameter" do
      header = Plug.Test.conn(:get, "/") |> Plug.Conn.put_req_header("a2a-version", "1.1")
      assert Version.negotiated_version(header) == "1.1"

      query = Plug.Test.conn(:get, "/?A2A-Version=1.0")
      assert Version.negotiated_version(query) == "1.0"

      both =
        Plug.Test.conn(:get, "/?A2A-Version=1.0")
        |> Plug.Conn.put_req_header("a2a-version", "1.1")

      assert Version.negotiated_version(both) == "1.1"

      assert Version.negotiated_version(Plug.Test.conn(:get, "/")) == "0.3"
    end
  end

  describe "every plug" do
    test "accepts 0.3 (missing header), 1.0 and 1.1 by default and refuses 1.2 with -32009",
         %{agent: agent} do
      for {label, mod, opts} <- plugs(agent) do
        for {headers, expected_echo} <- [
              {[], "0.3"},
              {[{"a2a-version", "1.0"}], "1.0"},
              {[{"a2a-version", "1.1"}], "1.1"},
              {[{"a2a-version", "1.1.3"}], "1.1"}
            ] do
          conn = send_message(mod, opts, headers)
          body = Jason.decode!(conn.resp_body)

          assert %{"result" => _} = body, "#{label} #{inspect(headers)}: #{inspect(body)}"
          assert Plug.Conn.get_resp_header(conn, "a2a-version") == [expected_echo]
        end

        conn = send_message(mod, opts, [{"a2a-version", "1.2"}])
        assert %{"error" => %{"code" => -32_009}} = Jason.decode!(conn.resp_body)
        assert Plug.Conn.get_resp_header(conn, "a2a-version") == ["1.2"]
      end
    end

    test "honors the A2A-Version query parameter when the header is absent", %{agent: agent} do
      for {label, mod, opts} <- plugs(agent) do
        ok = send_message(mod, opts, [], "?A2A-Version=1.1")
        assert %{"result" => _} = Jason.decode!(ok.resp_body), label
        assert Plug.Conn.get_resp_header(ok, "a2a-version") == ["1.1"]

        bad = send_message(mod, opts, [], "?A2A-Version=7.7")
        assert %{"error" => %{"code" => -32_009}} = Jason.decode!(bad.resp_body), label
      end
    end

    test ":versions narrows the accepted set (default unchanged elsewhere)", %{agent: agent} do
      for {label, mod, opts} <- plugs(agent, versions: ["1.1"]) do
        assert %{"result" => _} =
                 mod
                 |> send_message(opts, [{"a2a-version", "1.1"}])
                 |> Map.fetch!(:resp_body)
                 |> Jason.decode!(),
               label

        for refused <- ["0.3", "1.0"] do
          conn = send_message(mod, opts, [{"a2a-version", refused}])

          assert %{"error" => %{"code" => -32_009}} = Jason.decode!(conn.resp_body),
                 "#{label}: #{refused} must be refused when :versions is [\"1.1\"]"
        end
      end
    end

    test ":versions can widen the set beyond the default", %{agent: agent} do
      for {label, mod, opts} <- plugs(agent, versions: Version.supported_default() ++ ["1.2"]) do
        conn = send_message(mod, opts, [{"a2a-version", "1.2"}])
        assert %{"result" => _} = Jason.decode!(conn.resp_body), label
      end
    end
  end

  describe "negotiated version reaches downstream code" do
    test "Protocol.Plug records it at conn.private[:a2a][:version]", %{agent: agent} do
      opts = AshA2A.Protocol.Plug.init(agent: agent, base_url: "http://localhost:4000/a2a")
      conn = send_message(AshA2A.Protocol.Plug, opts, [{"a2a-version", "1.1"}])
      assert Version.get_negotiated(conn) == "1.1"
      assert Version.at_least?(Version.get_negotiated(conn), "1.1")

      old = send_message(AshA2A.Protocol.Plug, opts, [{"a2a-version", "1.0"}])
      assert Version.get_negotiated(old) == "1.0"
      refute Version.at_least?(Version.get_negotiated(old), "1.1")
    end

    test "Transport.Plug records it at conn.private[:a2a][:version]", %{agent: agent} do
      opts = AshA2A.Transport.Plug.init(agent: agent, base_url: "http://localhost:4000/a2a")
      conn = send_message(AshA2A.Transport.Plug, opts, [{"a2a-version", "1.1"}])
      assert Version.get_negotiated(conn) == "1.1"
    end

    test "A2ATransport.Plug records it on locally-gated methods", %{agent: agent} do
      opts = AshA2A.A2ATransport.Plug.init(agent: agent, base_url: "http://localhost:4000/a2a")

      body =
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tasks/list", "params" => %{}})

      conn =
        :post
        |> Plug.Test.conn("/", body)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("a2a-version", "1.1")
        |> AshA2A.A2ATransport.Plug.call(opts)

      assert Version.get_negotiated(conn) == "1.1"
    end
  end

  describe "agent card" do
    test "advertises protocolVersion 1.1 on supportedInterfaces", %{agent: agent} do
      opts = AshA2A.Protocol.Plug.init(agent: agent, base_url: "http://localhost:4000/a2a")

      card =
        :get
        |> Plug.Test.conn("/.well-known/agent-card.json")
        |> AshA2A.Protocol.Plug.call(opts)
        |> Map.fetch!(:resp_body)
        |> Jason.decode!()

      assert [_ | _] = interfaces = card["supportedInterfaces"]
      assert Enum.all?(interfaces, &(&1["protocolVersion"] == "1.1"))
    end
  end
end

# --- SOURCE: test/push_config_protocol_version_test.exs ---
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

