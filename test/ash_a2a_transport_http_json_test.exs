# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Transport.HTTPJSONTest.Resource do
  @moduledoc """
  Real fixture resource, private to this test file: a single real `:read`
  skill on a real ETS-backed Ash resource, so dispatch has exactly one skill
  and needs no `:skill` metadata.
  """

  use Ash.Resource,
    domain: AshA2A.Transport.HTTPJSONTest.Domain,
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

defmodule AshA2A.Transport.HTTPJSONTest.Domain do
  @moduledoc "Real fixture domain for the resource above."

  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.Transport.HTTPJSONTest.Resource)
  end
end

defmodule AshA2A.Transport.HTTPJSONTest.EchoAgent do
  @moduledoc "Real `AshA2A.Agent` GenServer over the fixture resource above."

  use AshA2A.Agent,
    resource_or_domain: AshA2A.Transport.HTTPJSONTest.Resource,
    name: "http_json_echo_agent"
end

defmodule AshA2A.Transport.HTTPJSONTest do
  @moduledoc """
  End-to-end court for the A2A v1.0 HTTP+JSON/REST transport binding
  (`AshA2A.Transport.HTTPJSON`).

  A real Bandit server on a loopback ephemeral port, a real supervised
  `use AshA2A.Agent` GenServer over a real ETS Ash resource, real `Req`
  HTTP calls for the full round trip: card fetch -> `message:send` ->
  `tasks/get` -> error cases. No mocks.
  """

  use ExUnit.Case, async: false

  @moduletag :serial_shard

  alias AshA2A.Test.EphemeralHttp

  alias AshA2A.Transport.HTTPJSON, as: Binding

  @error_info "type.googleapis.com/google.rpc.ErrorInfo"

  setup do
    agent = AshA2A.Transport.HTTPJSONTest.EchoAgent

    {_sup, _registry} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [agent])

    plug_opts =
      Binding.init(agent: agent, base_url: "http://127.0.0.1/fixture")

    %{server: EphemeralHttp.start!({Binding, plug_opts})}
  end

  # -- helpers ----------------------------------------------------------------

  defp message_map(text) do
    AshA2A.Protocol.JSON.encode!(AshA2A.Protocol.Message.new_user(text))
  end

  defp get!(server, path) do
    Req.get!(url: server.base_url <> path)
  end

  defp post_json!(server, path, body) do
    Req.post!(url: server.base_url <> path, json: body)
  end

  defp send_message!(server, text) do
    resp = post_json!(server, "/message:send", %{"message" => message_map(text)})
    assert resp.status == 200
    resp
  end

  defp assert_json_content_type(resp) do
    [content_type] = Enum.map(resp.headers["content-type"], &String.downcase/1)
    assert String.starts_with?(content_type, "application/json")
  end

  # -- agent card ---------------------------------------------------------------

  test "serves the agent card at the spec's well-known path", %{server: server} do
    resp = get!(server, "/.well-known/agent-card.json")

    assert resp.status == 200
    assert_json_content_type(resp)

    assert %{
             "capabilities" => %{"streaming" => true} = capabilities,
             "supportedInterfaces" => [%{"url" => url, "protocolBinding" => _} | _]
           } = resp.body

    assert is_binary(url)
    assert is_binary(resp.body["name"])
    assert Map.has_key?(capabilities, "pushNotifications")
  end

  # -- the happy path: card -> message:send -> tasks/get -----------------------

  test "end-to-end: message:send creates a completed task, tasks/get reads it back", %{
    server: server
  } do
    resp = send_message!(server, "go")

    assert_json_content_type(resp)

    assert %{"task" => task} = resp.body

    assert %{
             "id" => "tsk-" <> _,
             "contextId" => context_id,
             "status" => %{"state" => "TASK_STATE_COMPLETED"}
           } = task

    assert is_binary(context_id)
    assert [%{"parts" => _}] = task["artifacts"]

    # The wire task carries no transport-internal metadata.
    refute Map.has_key?(task["metadata"] || %{}, "a2a.auth")

    fetched = get!(server, "/tasks/#{task["id"]}")
    assert fetched.status == 200
    assert fetched.body["id"] == task["id"]
    assert fetched.body["status"]["state"] == "TASK_STATE_COMPLETED"
    assert fetched.body["contextId"] == context_id
  end

  test "message:send with a terminal task's taskId is 400 task-is-terminal", %{server: server} do
    %{"task" => %{"id" => task_id}} = send_message!(server, "first").body

    continuation = message_map("second") |> Map.put("taskId", task_id)
    resp = post_json!(server, "/message:send", %{"message" => continuation})

    assert resp.status == 400
    assert %{
             "error" => %{
               "code" => 400,
               "details" => [%{"@type" => @error_info, "reason" => "INVALID_PARAMS"}]
             }
           } = resp.body
  end

  test "historyLength parses, truncates, and rejects non-integer query values", %{
    server: server
  } do
    %{"task" => %{"id" => task_id}} = send_message!(server, "go").body

    resp = get!(server, "/tasks/#{task_id}?historyLength=1")
    assert resp.status == 200
    assert length(resp.body["history"]) <= 1

    resp = get!(server, "/tasks/#{task_id}?historyLength=bogus")
    assert resp.status == 400
    assert %{"error" => %{"code" => 400, "status" => "INVALID_ARGUMENT"}} = resp.body
  end

  # -- error cases (status codes + google.rpc ErrorInfo bodies) ----------------

  test "tasks/get on an unknown task is 404 with a TASK_NOT_FOUND ErrorInfo", %{server: server} do
    resp = get!(server, "/tasks/tsk-does-not-exist")

    assert resp.status == 404
    assert_json_content_type(resp)

    assert %{
             "error" => %{
               "code" => 404,
               "status" => "NOT_FOUND",
               "message" => "Task not found",
               "details" => [
                 %{
                   "@type" => @error_info,
                   "domain" => "a2a-protocol.org",
                   "reason" => "TASK_NOT_FOUND"
                 }
               ]
             }
           } = resp.body
  end

  test "cancelling a terminal task is 409 with TASK_NOT_CANCELABLE ErrorInfo", %{server: server} do
    %{"task" => %{"id" => task_id}} = send_message!(server, "go").body

    resp = post_json!(server, "/tasks/#{task_id}:cancel", %{})

    assert resp.status == 409
    assert %{
             "error" => %{
               "code" => 409,
               "status" => "ABORTED",
               "details" => [%{"@type" => @error_info, "reason" => "TASK_NOT_CANCELABLE"}]
             }
           } = resp.body
  end

  test "cancel on an unknown task is 404", %{server: server} do
    resp = post_json!(server, "/tasks/tsk-nope:cancel", %{})
    assert resp.status == 404
    assert %{"error" => %{"code" => 404}} = resp.body
  end

  test "malformed JSON body is 400 parse error", %{server: server} do
    resp =
      Req.post!(url: server.base_url <> "/message:send",
        headers: [{"content-type", "application/json"}],
        body: "definitely not json"
      )

    assert resp.status == 400
    assert %{"error" => %{"code" => 400, "status" => "INVALID_ARGUMENT", "message" => "Invalid JSON payload"}} =
             resp.body
  end

  test "missing message is 400 invalid params with INVALID_PARAMS ErrorInfo", %{server: server} do
    resp = post_json!(server, "/message:send", %{"configuration" => %{}})

    assert resp.status == 400
    assert %{
             "error" => %{
               "code" => 400,
               "details" => [%{"@type" => @error_info, "reason" => "INVALID_PARAMS"}]
             }
           } = resp.body
  end

  test "an over-cap body is refused 400 before parse", %{server: _server} do
    # A second real server, same binding, tiny body cap.
    small =
      EphemeralHttp.start!(
        {Binding,
         Binding.init(
           agent: AshA2A.Transport.HTTPJSONTest.EchoAgent,
           base_url: "http://127.0.0.1/fixture",
           max_body_bytes: 16
         )}
      )

    resp = post_json!(small, "/message:send", %{"message" => message_map("this is much longer than sixteen bytes")})

    assert resp.status == 400
    assert %{"error" => %{"code" => 400, "details" => "Body too large"}} = resp.body
  end

  test "recognized-but-unsupported REST ops answer 400 UNSUPPORTED_OPERATION", %{server: server} do
    # message:stream streams (see the SSE court in the TCK-closure file); an
    # OWNED task's :subscribe has no resubscribe stream to attach and answers
    # the -32004 envelope, mirroring AshA2A.Transport.Plug.resubscribe/4.
    %{"task" => %{"id" => task_id}} = send_message!(server, "go").body

    resp = post_json!(server, "/tasks/#{task_id}:subscribe", %{})

    assert resp.status == 400
    assert %{
             "error" => %{
               "code" => 400,
               "details" => [%{"@type" => @error_info, "reason" => "UNSUPPORTED_OPERATION"}]
             }
           } = resp.body
  end

  # -- routing -------------------------------------------------------------------

  test "known paths with the wrong method answer 405 with an allow header", %{server: server} do
    resp =
      Req.post!(url: server.base_url <> "/.well-known/agent-card.json",
        json: %{},
        decode_body: false
      )

    assert resp.status == 405
    assert resp.headers["allow"] == ["GET"]

    resp = Req.get!(url: server.base_url <> "/message:send", decode_body: false)
    assert resp.status == 405
    assert resp.headers["allow"] == ["POST"]

    resp = Req.delete!(url: server.base_url <> "/tasks/tsk-x", decode_body: false)
    assert resp.status == 405
  end

  test "unknown paths answer 404", %{server: server} do
    assert %{status: 404} = get!(server, "/nope")
    assert %{status: 404} = get!(server, "/tasks/tsk-x/extra-segment")
  end

  test "GET /tasks/tsk-x:cancel (cancel verb with wrong method) answers 405", %{server: server} do
    resp = Req.get!(url: server.base_url <> "/tasks/tsk-x:cancel")
    assert resp.status == 405
    assert resp.headers["allow"] == ["POST"]
  end
end
