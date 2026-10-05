# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.V1BindingMismatchTest.Resource do
  @moduledoc """
  Real fixture resource, private to this test file: a single real `:read`
  skill on a real ETS-backed Ash resource, so dispatch has exactly one skill
  and needs no `:skill` metadata.
  """

  use Ash.Resource,
    domain: AshA2A.V1BindingMismatchTest.Domain,
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

defmodule AshA2A.V1BindingMismatchTest.Domain do
  @moduledoc "Real fixture domain for the resource above."

  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.V1BindingMismatchTest.Resource)
  end
end

defmodule AshA2A.V1BindingMismatchTest.EchoAgent do
  @moduledoc "Real `AshA2A.Agent` GenServer over the fixture resource above."

  use AshA2A.Agent,
    resource_or_domain: AshA2A.V1BindingMismatchTest.Resource,
    name: "binding_mismatch_echo_agent"
end

defmodule AshA2A.V1BindingMismatchTest do
  @moduledoc """
  Cross-binding mismatch conformance court (lane Z3): what actually happens
  when a client speaks the WRONG binding dialect at a server.

  Two real Bandit servers over one real `AshA2A.Agent`:

    * `rpc`  -- `AshA2A.A2ATransport.Plug`, the JSON-RPC 2.0 binding
    * `rest` -- `AshA2A.Transport.HTTPJSON`, the A2A v1.0 REST binding

  Pinned mismatch matrix (all observed on the wire, zero mocks):

  | # | client speaks                | at server  | pinned outcome |
  |---|------------------------------|------------|----------------|
  | a1| REST MessageSendParams body  | JSON-RPC   | 200 + JSON-RPC error envelope -32600 ("jsonrpc" must be "2.0"), id null |
  | a2| REST route POST /message:send| JSON-RPC   | 404 "Not Found" (plain text, not an ErrorInfo body) |
  | b1| JSON-RPC envelope body       | HTTPJSON   | 400 + ErrorInfo INVALID_PARAMS (-32602), "message" is required |
  | b2| envelope member + top-level "message" | HTTPJSON | 200 task (unknown members are inert) |
  | c | JSON-RPC body, unknown path  | HTTPJSON   | 404 "Not Found" (consistent with W6's unknown-path pin) |
  | d1| no A2A-Version header        | both       | JSONRPC: 200, echoes `a2a-version: 0.3`; HTTPJSON: 200, no header |
  | d2| A2A-Version: 9.9             | JSON-RPC   | 200 + error envelope -32009 VERSION_NOT_SUPPORTED ErrorInfo |
  | d3| A2A-Version: 9.9             | HTTPJSON   | 200 success (headers accepted-and-ignored) |
  | e1| `Client` in :jsonrpc mode    | HTTPJSON   | `{:error, %Jason.DecodeError{}}` — the :jsonrpc decode ignores HTTP status, so a plain-text 404 is a decode refusal; typed, no hang |
  | e2| `Client` in :http_json mode  | JSON-RPC   | `{:error, {:http_error, 404, "Not Found"}}`, typed, no hang |

  Every mismatch case is followed by a well-formed request that succeeds, so
  "refused" is always distinguished from "crashed".
  """

  use ExUnit.Case, async: false

  @moduletag :serial_shard

  alias AshA2A.A2ATransport.Plug, as: TransportPlug
  alias AshA2A.Protocol.Client
  alias AshA2A.Test.EphemeralHttp
  alias AshA2A.Transport.HTTPJSON, as: RestBinding

  @error_info "type.googleapis.com/google.rpc.ErrorInfo"

  setup do
    uniq = System.unique_integer([:positive])
    agent = :"binding_mismatch_agent_#{uniq}"
    transport = :"a2a_transport_binding_mismatch_#{uniq}"

    start_supervised!({AshA2A.V1BindingMismatchTest.EchoAgent, name: agent})
    start_supervised!({AshA2A.A2ATransport, name: transport})

    rpc =
      EphemeralHttp.start!(
        {TransportPlug, agent: agent, base_url: "http://127.0.0.1/rpc", transport: transport}
      )

    rest =
      EphemeralHttp.start!(
        {RestBinding, RestBinding.init(agent: agent, base_url: "http://127.0.0.1/rest")}
      )

    %{rpc: rpc, rest: rest, uniq: uniq}
  end

  # -- helpers ----------------------------------------------------------------

  defp message_map(text) do
    AshA2A.Protocol.JSON.encode!(AshA2A.Protocol.Message.new_user(text))
  end

  defp rest_body(text), do: %{"message" => message_map(text)}

  defp rpc_envelope(method, params) do
    %{
      "jsonrpc" => "2.0",
      "id" => System.unique_integer([:positive]),
      "method" => method,
      "params" => params
    }
  end

  defp post_json!(server, path, body, headers \\ []) do
    server.base_url
    |> then(&Req.new(base_url: &1, headers: headers, retry: false))
    |> Req.post!(url: path, json: body)
  end

  # A valid request in each server's own dialect: liveness, not the mismatch.
  defp assert_server_alive({binding, server}, text) do
    resp =
      case binding do
        :rpc -> post_json!(server, "/", rpc_envelope("message/send", rest_body(text)))
        :rest -> post_json!(server, "/message:send", rest_body(text))
      end

    assert resp.status == 200

    task_id =
      case body!(resp) do
        %{"result" => %{"task" => %{"id" => id}}} -> id
        %{"task" => %{"id" => id}} -> id
        %{"id" => id} -> id
      end

    assert is_binary(task_id)
  end

  # The response body may arrive pre-decoded (Req JSON decode) or raw; the
  # plain-text "Not Found" bodies stay binary either way.
  defp body!(resp) do
    case resp.body do
      body when is_binary(body) -> body
      body -> body
    end
  end

  # ===========================================================================
  # (a) JSON-RPC server receives a REST-style request
  # ===========================================================================

  test "(a1) REST MessageSendParams body at the JSON-RPC endpoint answers -32600, never a crash", %{
    rpc: rpc
  } do
    resp = post_json!(rpc, "/", rest_body("wrong dialect"))

    assert resp.status == 200

    assert %{
             "jsonrpc" => "2.0",
             "id" => nil,
             "error" => %{
               "code" => -32_600,
               "message" => "Request payload validation error",
               "data" => "\"jsonrpc\" must be \"2.0\""
             }
           } = body!(resp)

    refute Map.has_key?(body!(resp), "result")

    # Refused, not crashed: a well-formed request still succeeds afterwards.
    assert_server_alive({:rpc, rpc}, "still alive after rest body")
  end

  test "(a2) REST verb-suffix route POST /message:send on the JSON-RPC server answers 404", %{
    rpc: rpc
  } do
    resp = post_json!(rpc, "/message:send", rest_body("wrong route"))

    assert resp.status == 404
    assert body!(resp) == "Not Found"

    assert_server_alive({:rpc, rpc}, "still alive after wrong route")
  end

  # ===========================================================================
  # (b) HTTPJSON server receives a JSON-RPC envelope
  # ===========================================================================

  test "(b1) JSON-RPC envelope body at POST /message:send answers 400 INVALID_PARAMS ErrorInfo", %{
    rest: rest
  } do
    resp = post_json!(rest, "/message:send", rpc_envelope("message/send", rest_body("envelope")))

    assert resp.status == 400

    assert %{
             "error" => %{
               "code" => 400,
               "message" => "Invalid parameters",
               "details" => [
                 %{
                   "@type" => @error_info,
                   "domain" => "a2a-protocol.org",
                   "reason" => "INVALID_PARAMS",
                   "metadata" => %{"detail" => "\"message\" is required"}
                 }
               ]
             }
           } = body!(resp)

    assert_server_alive({:rest, rest}, "still alive after envelope body")
  end

  test "(b2) an envelope member alongside a top-level message is inert: the send succeeds", %{
    rest: rest
  } do
    body =
      rpc_envelope("message/send", %{})
      |> Map.delete("params")
      |> Map.put("message", message_map("inert envelope member"))

    resp = post_json!(rest, "/message:send", body)

    assert resp.status == 200
    assert %{"task" => %{"id" => task_id, "status" => %{"state" => _}}} = body!(resp)
    assert is_binary(task_id)
  end

  # ===========================================================================
  # (c) JSON-RPC body at an unknown HTTPJSON path (consistency with W6)
  # ===========================================================================

  test "(c) JSON-RPC envelope at an unknown HTTPJSON path answers the same 404 W6 pins", %{
    rest: rest
  } do
    resp = post_json!(rest, "/nope", rpc_envelope("message/send", %{}))

    assert resp.status == 404
    assert body!(resp) == "Not Found"

    # Method-shape consistency: a JSON-RPC envelope is just an unknown-body
    # POST to an unrouted path; the 404 does not depend on the body dialect.
    assert %{status: 404} = Req.post!(url: rest.base_url <> "/nope", body: "garbage bytes")
  end

  # ===========================================================================
  # (d) A2A-Version header: absent and mismatched, both bindings
  # ===========================================================================

  test "(d1) a missing A2A-Version header succeeds on both bindings", %{rpc: rpc, rest: rest} do
    # JSONRPC: §3.6.2 interprets a missing version as "0.3" (supported) and
    # echoes the negotiated version back in the response header.
    resp = post_json!(rpc, "/", rpc_envelope("message/send", rest_body("no version header")))
    assert resp.status == 200
    assert %{"result" => %{"task" => %{"id" => _}}} = body!(resp)
    assert Enum.join(resp.headers["a2a-version"], "") == "0.3"

    # HTTPJSON: the version gate mirrors the JSONRPC plug -- a missing header
    # negotiates "0.3" and the negotiated version is echoed back.
    resp = post_json!(rest, "/message:send", rest_body("no version header"))
    assert resp.status == 200
    assert %{"task" => %{"id" => _}} = body!(resp)
    assert Enum.join(resp.headers["a2a-version"], "") == "0.3"
  end

  test "(d2) a mismatched A2A-Version on the JSON-RPC server answers -32009 VERSION_NOT_SUPPORTED", %{
    rpc: rpc
  } do
    resp =
      post_json!(rpc, "/", rpc_envelope("message/send", rest_body("bad version")), [
        {"a2a-version", "9.9"}
      ])

    assert resp.status == 200

    assert %{
             "jsonrpc" => "2.0",
             "id" => nil,
             "error" => %{
               "code" => -32_009,
               "message" => "Version not supported",
               "data" => [
                 %{
                   "@type" => @error_info,
                   "domain" => "a2a-protocol.org",
                   "reason" => "VERSION_NOT_SUPPORTED",
                   "metadata" => %{"detail" => "9.9"}
                 }
               ]
             }
           } = body!(resp)

    assert_server_alive({:rpc, rpc}, "still alive after bad version")
  end

  test "(d3) a mismatched A2A-Version on the HTTPJSON server answers -32009, mirroring the JSONRPC plug's gate", %{
    rest: rest
  } do
    resp =
      post_json!(rest, "/message:send", rest_body("mismatched version"), [
        {"a2a-version", "9.9"}
      ])

    assert resp.status == 400
    assert Enum.join(resp.headers["a2a-version"], "") == "9.9"

    assert %{
             "error" => %{
               "code" => 400,
               "message" => "Version not supported",
               "details" => [
                 %{
                   "@type" => @error_info,
                   "domain" => "a2a-protocol.org",
                   "reason" => "VERSION_NOT_SUPPORTED",
                   "metadata" => %{"detail" => "9.9"}
                 }
               ]
             }
           } = body!(resp)

    assert_server_alive({:rest, rest}, "still alive after bad version")
  end

  # ===========================================================================
  # (e) Client-side: `AshA2A.Protocol.Client` in the wrong transport mode
  # ===========================================================================

  test "(e0) control: each client in its correct mode succeeds against its matching server", %{
    rpc: rpc,
    rest: rest
  } do
    assert {:ok, %AshA2A.Protocol.Task{id: id}} =
             Client.new(rpc.base_url)
             |> Client.send_message("control rpc", timeout: 5_000)

    assert is_binary(id)

    assert {:ok, %AshA2A.Protocol.Task{id: id}} =
             Client.new(rest.base_url, transport: :http_json)
             |> Client.send_message("control rest", timeout: 5_000)

    assert is_binary(id)
  end

  test "(e1) a :jsonrpc-mode client pointed at the HTTPJSON server fails typed, never hangs", %{
    rest: rest
  } do
    client = Client.new(rest.base_url)

    # The envelope is POSTed at the bare base URL; the REST binding has no
    # route there. Fixed (coordinator): the :jsonrpc decode path now checks
    # the HTTP status first — a non-2xx surfaces as the typed
    # {:http_error, status, body}, never a Jason decode error, still
    # immediate and bounded by the 2s receive_timeout (never a hang).
    assert {:error, {:http_error, 404, "Not Found"}} =
             Client.send_message(client, "wrong mode", timeout: 2_000)

    assert {:error, {:http_error, 404, "Not Found"}} =
             Client.get_task(client, "tsk-x", timeout: 2_000)

    # Streaming refuses with its own typed shape, still no hang.
    assert {:error, {:unexpected_status, 404}} =
             Client.stream_message(client, "wrong mode", timeout: 2_000)

    # The failure is the client's dialect, not a dead server.
    assert_server_alive({:rest, rest}, "rest server fine after client mismatch")
  end

  test "(e2) an :http_json-mode client pointed at the JSON-RPC server fails typed, never hangs", %{
    rpc: rpc
  } do
    client = Client.new(rpc.base_url, transport: :http_json)

    assert {:error, {:http_error, 404, "Not Found"}} =
             Client.send_message(client, "wrong mode", timeout: 2_000)

    assert {:error, {:http_error, 404, "Not Found"}} =
             Client.get_task(client, "tsk-x", timeout: 2_000)

    assert {:error, {:http_error, 404, "Not Found"}} =
             Client.cancel_task(client, "tsk-x", timeout: 2_000)

    assert_server_alive({:rpc, rpc}, "rpc server fine after client mismatch")
  end
end
