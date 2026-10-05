# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Transport.HTTPJSON.TCKClosuresTest.Probe do
  @moduledoc false
  # Real ETS-backed Ash resource with one real `:read` skill.
  use Ash.Resource,
    domain: AshA2A.Transport.HTTPJSON.TCKClosuresTest.Domain,
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

defmodule AshA2A.Transport.HTTPJSON.TCKClosuresTest.Domain do
  @moduledoc false

  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.Transport.HTTPJSON.TCKClosuresTest.Probe)
  end
end

defmodule AshA2A.Transport.HTTPJSON.TCKClosuresTest.EchoAgent do
  @moduledoc false

  use AshA2A.Agent,
    resource_or_domain: AshA2A.Transport.HTTPJSON.TCKClosuresTest.Probe,
    name: "httpjson_tck_closures_agent"
end

defmodule AshA2A.Transport.HTTPJSON.TCKClosuresTest do
  @moduledoc """
  Lane G-P court: the A2A v1.0 HTTP+JSON/REST binding's TCK-closure surface
  (the G-E http_json TCK matrix's transport-side failure classes, pinned
  positively over a real Bandit server, a real `use AshA2A.Agent` GenServer
  and real `Req` round trips -- no mocks).

  Six pins, one per closed failure class:

    1. `POST /message:send` answers the v1.0 SendMessageResponse oneof
       wrapper `{"task": ...}` | `{"message": ...}` (TCK validates the body
       against the SendMessageResponse schema, `additionalProperties: false`)
    2. Error bodies are the AIP-193 envelope `{"error": {"code": <HTTP
       status>, "status": <gRPC name>, "message", "details"}}` with
       `error.code == HTTP status` (TCK HTTP_JSON-ERR-001/002, AIP-193)
    3. The §3.6 `A2A-Version` gate: unsupported -> 400 `-32009`
       (VERSION_NOT_SUPPORTED ErrorInfo) with the rejected version echoed;
       absent/supported -> dispatch with the negotiated version echoed
       (mirrors `AshA2A.Transport.Plug.handle_json_rpc/2`)
    4. `POST /tasks/{id}:subscribe` on an unknown task -> 404 TaskNotFound
       (TCK STREAM-SUB-004, §5.4); on an owned task -> 400
       UnsupportedOperation (mirrors `AshA2A.Transport.Plug.resubscribe/4`)
    5. `POST /message:stream` streams SSE (`text/event-stream`), one
       StreamResponse JSON object per `data:` frame (TCK CORE-STREAM-*,
       HTTP_JSON-SSE-001)
    6. The push-config CRUD answers the §5.3 collection path
       `pushNotificationConfigs` (plural) identically to the singular alias;
       when push is disabled every verb is the 400 `-32003` envelope (TCK
       CORE-CAP-001, HTTP_JSON-STATUS-001)

  Request-side unknown members stay inert (tolerant proto3-JSON input,
  strict SendMessageResponse output shape) -- the TCK's "additional
  properties" class was response-side only.
  """

  use ExUnit.Case, async: false

  @moduletag :serial_shard

  alias AshA2A.Test.EphemeralHttp

  alias AshA2A.Transport.HTTPJSON, as: Binding

  @error_info "type.googleapis.com/google.rpc.ErrorInfo"

  setup do
    agent = AshA2A.Transport.HTTPJSON.TCKClosuresTest.EchoAgent

    {_sup, _registry} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [agent])

    plug_opts = Binding.init(agent: agent, base_url: "http://127.0.0.1/fixture")

    %{server: EphemeralHttp.start!({Binding, plug_opts})}
  end

  # -- helpers ----------------------------------------------------------------

  defp message_map(text) do
    AshA2A.Protocol.JSON.encode!(AshA2A.Protocol.Message.new_user(text))
  end

  defp post_json!(server, path, body, headers \\ []) do
    Req.post!(url: server.base_url <> path, json: body, headers: headers)
  end

  defp get!(server, path) do
    Req.get!(url: server.base_url <> path)
  end

  defp send_message!(server, text) do
    resp = post_json!(server, "/message:send", %{"message" => message_map(text)})
    assert resp.status == 200
    resp
  end

  defp new_task_id(server) do
    %{"task" => %{"id" => id}} = send_message!(server, "go").body
    id
  end

  # -- (1) the SendMessageResponse oneof wrapper -------------------------------

  test "message:send wraps the task in the v1.0 SendMessageResponse oneof", %{server: server} do
    resp = send_message!(server, "go")

    assert %{"task" => %{"id" => "tsk-" <> _, "status" => %{"state" => "TASK_STATE_COMPLETED"}}} =
             resp.body

    # The wrapper carries no other members (the schema is
    # additionalProperties: false over task|message).
    assert Map.keys(resp.body) == ["task"]
  end

  # -- (2) the AIP-193 error envelope -------------------------------------------

  test "error bodies are the AIP-193 envelope with error.code == HTTP status", %{server: server} do
    resp = get!(server, "/tasks/tsk-does-not-exist")

    assert resp.status == 404

    assert %{
             "error" => %{
               "code" => 404,
               "status" => "NOT_FOUND",
               "message" => "Task not found",
               "details" => [%{"@type" => @error_info, "domain" => "a2a-protocol.org", "reason" => "TASK_NOT_FOUND"}]
             }
           } = resp.body
  end

  # -- (3) the A2A-Version gate -------------------------------------------------

  test "a supported A2A-Version dispatches and is echoed back", %{server: server} do
    for version <- [nil, "0.3", "1.0"] do
      resp =
        case version do
          nil -> post_json!(server, "/message:send", %{"message" => message_map("v-gate nil")})
          v -> post_json!(server, "/message:send", %{"message" => message_map("v-gate " <> v)}, [{"a2a-version", v}])
        end

      assert resp.status == 200
      assert %{"task" => %{"id" => _}} = resp.body
      assert Enum.join(resp.headers["a2a-version"], "") == (version || "0.3")
    end
  end

  test "an unsupported A2A-Version answers 400 -32009 with the rejected version echoed", %{
    server: server
  } do
    resp = post_json!(server, "/message:send", %{"message" => message_map("v-gate bad")}, [{"a2a-version", "99.0"}])

    assert resp.status == 400
    assert Enum.join(resp.headers["a2a-version"], "") == "99.0"

    assert %{
             "error" => %{
               "code" => 400,
               "status" => "INVALID_ARGUMENT",
               "message" => "Version not supported",
               "details" => [
                 %{
                   "@type" => @error_info,
                   "domain" => "a2a-protocol.org",
                   "reason" => "VERSION_NOT_SUPPORTED",
                   "metadata" => %{"detail" => "99.0"}
                 }
               ]
             }
           } = resp.body
  end

  # -- (4) tasks/{id}:subscribe status mapping -----------------------------------

  test "subscribe on an unknown task is 404 TaskNotFound (STREAM-SUB-004)", %{server: server} do
    resp = post_json!(server, "/tasks/tsk-does-not-exist:subscribe", %{})

    assert resp.status == 404

    assert %{
             "error" => %{
               "code" => 404,
               "status" => "NOT_FOUND",
               "details" => [%{"@type" => @error_info, "reason" => "TASK_NOT_FOUND"}]
             }
           } = resp.body
  end

  test "subscribe on an owned task is 400 UnsupportedOperation", %{server: server} do
    task_id = new_task_id(server)

    resp = post_json!(server, "/tasks/#{task_id}:subscribe", %{})

    assert resp.status == 400

    assert %{
             "error" => %{
               "code" => 400,
               "details" => [%{"@type" => @error_info, "reason" => "UNSUPPORTED_OPERATION"}]
             }
           } = resp.body
  end

  # -- (5) message:stream SSE ----------------------------------------------------

  test "message:stream answers SSE with StreamResponse data frames", %{server: server} do
    resp =
      Req.post!(url: server.base_url <> "/message:stream",
        json: %{"message" => message_map("stream me")},
        headers: [{"accept", "text/event-stream"}],
        decode_body: false
      )

    assert resp.status == 200

    [content_type] = Enum.map(resp.headers["content-type"], &String.downcase/1)
    assert content_type =~ "text/event-stream"

    frames =
      resp.body
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "data:"))
      |> Enum.map(&(&1 |> String.slice(5..-1//1) |> String.trim()))
      |> Enum.map(&Jason.decode!/1)

    assert length(frames) >= 2

    # Every frame is a single-member StreamResponse wrapper.
    for frame <- frames do
      assert Map.keys(frame) -- ["task", "message", "statusUpdate", "artifactUpdate"] == []
      assert Map.keys(frame) != []
    end

    # First frame carries the task, the final frame is the terminal status.
    assert %{"task" => %{"id" => task_id}} = hd(frames)

    last = List.last(frames)
    # v1.0: finality is the terminal TASK_STATE_* on the final statusUpdate,
    # not a "final" boolean (same wire shape as the JSON-RPC SSE frames).
    assert %{"statusUpdate" => %{"status" => %{"state" => "TASK_STATE_COMPLETED"}}} = last

    # The task from the stream is really readable back.
    fetched = get!(server, "/tasks/#{task_id}")
    assert fetched.status == 200
    assert fetched.body["id"] == task_id
  end

  # -- (6) the plural pushNotificationConfigs collection path --------------------

  test "pushNotificationConfigs (plural) routes like the singular alias", %{server: server} do
    # Push notifications are disabled on this binding: every verb on the
    # plural collection path must answer the same fail-closed -32003
    # envelope as the singular alias (routing parity, CORE-CAP-001).
    for {method, path} <- [
          {:post, "/tasks/tsk-x/pushNotificationConfigs"},
          {:get, "/tasks/tsk-x/pushNotificationConfigs"},
          {:get, "/tasks/tsk-x/pushNotificationConfigs/cfg-1"},
          {:delete, "/tasks/tsk-x/pushNotificationConfigs/cfg-1"}
        ] do
      resp =
        case method do
          :post -> post_json!(server, path, %{"url" => "https://example.com"})
          :get -> get!(server, path)
          :delete -> Req.delete!(url: server.base_url <> path)
        end

      assert resp.status == 400, "#{method} #{path}"

      assert %{
               "error" => %{
                 "code" => 400,
                 "details" => [%{"@type" => @error_info, "reason" => "PUSH_NOTIFICATION_NOT_SUPPORTED"}]
               }
             } = resp.body, "#{method} #{path}"
    end
  end
end
