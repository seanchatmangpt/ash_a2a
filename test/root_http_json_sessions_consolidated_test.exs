# NOTE: 26 module(s) removed from this consolidated file because the repaired originals (kept as separate files) define the same modules; see docs/reference/test-consolidation-merge.md.
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






# --- SOURCE: test/http_json_live_session_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT






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


# --- SOURCE: test/live_session_streaming_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT





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



