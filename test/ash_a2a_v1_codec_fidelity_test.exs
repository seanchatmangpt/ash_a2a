defmodule AshA2A.V1CodecFidelityTest.RaisingStreamAgent do
  @moduledoc "Real agent whose `{:stream, enum}` reply raises mid-stream with secret detail."

  use AshA2A.Agent,
    resource_or_domain: AshA2A.Test.Fixture.Echo,
    name: "v1_codec_fidelity_raising_stream_agent"

  @impl AshA2A.Protocol.Agent
  def handle_message(_message, _context) do
    {:stream,
     Stream.map(1..2, fn _ -> raise "SECRET-SQL-DETAIL select * from users /etc/passwd" end)}
  end
end

defmodule AshA2A.V1CodecFidelityTest do
  @moduledoc """
  Lane 10 fidelity court for the A2A v1 wire codec, JSON-RPC param validation,
  the client's `SendMessageConfiguration` encoding and SSE error redaction.
  Real `Plug.Test` conns against the real `AshA2A.Protocol.Plug` fronting a real
  agent GenServer; the codec is exercised through real encode/decode round trips.
  Reference: priv/a2a_v1_spec_corpus/a2a.proto.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Protocol.{Artifact, JSON, Message, Part}
  alias AshA2A.Protocol.SecurityScheme
  alias AshA2A.V1CodecFidelityTest.RaisingStreamAgent

  # -- harness -----------------------------------------------------------------

  defp start_plug!(agent_module, card_opts \\ []) do
    name = :"v1_codec_fidelity_#{System.unique_integer([:positive])}"
    start_supervised!(Supervisor.child_spec({agent_module, name: name}, id: name))

    AshA2A.Protocol.Plug.init(
      agent: name,
      base_url: "http://localhost:4000/a2a",
      agent_card_opts: card_opts
    )
  end

  defp rpc(plug_opts, method, params) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => System.unique_integer([:positive]),
        "method" => method,
        "params" => params
      })

    :post
    |> Plug.Test.conn("/", body)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> AshA2A.Protocol.Plug.call(plug_opts)
  end

  defp rpc_body(plug_opts, method, params),
    do: plug_opts |> rpc(method, params) |> Map.fetch!(:resp_body) |> Jason.decode!()

  defp wire_message(text \\ "hello") do
    {:ok, encoded} = JSON.encode(Message.new_user(text))
    encoded
  end

  defp roundtrip(struct, type) do
    {:ok, wire} = JSON.encode(struct)
    wire |> Jason.encode!() |> Jason.decode!() |> JSON.decode(type)
  end

  defp card(overrides \\ %{}) do
    wire =
      Map.merge(
        %{
          "name" => "a",
          "description" => "d",
          "version" => "1",
          "skills" => [%{"id" => "s", "name" => "S", "description" => "d", "tags" => []}],
          "supportedInterfaces" => [],
          "capabilities" => %{},
          "defaultInputModes" => ["text/plain"],
          "defaultOutputModes" => ["text/plain"]
        },
        overrides
      )

    JSON.decode_agent_card(wire)
  end

  # -- SSE redaction -------------------------------------------------------------

  test "SSE final failed status never carries Exception.message detail" do
    opts = start_plug!(RaisingStreamAgent, capabilities: %{streaming: true})

    conn = rpc(opts, "message/stream", %{"message" => wire_message()})

    assert conn.status == 200
    refute conn.resp_body =~ "SECRET-SQL-DETAIL"
    refute conn.resp_body =~ "/etc/passwd"
    assert conn.resp_body =~ "TASK_STATE_FAILED"
    assert conn.resp_body =~ "Internal error (ref: "
  end

  # -- parts ---------------------------------------------------------------------

  test "Text and Data parts round-trip filename and mediaType" do
    text = %Part.Text{text: "hi", filename: "a.txt", media_type: "text/plain"}
    assert {:ok, ^text} = roundtrip(text, :part)

    data = %Part.Data{data: %{"k" => 1}, filename: "d.json", media_type: "application/json"}
    assert {:ok, ^data} = roundtrip(data, :part)
  end

  test "Data part accepts any JSON value and round-trips it" do
    for value <- [[1, "two", %{"three" => 3}], "str", 42, 1.5, true, nil, %{"a" => %{}}] do
      part = Part.Data.new(value)
      assert {:ok, %Part.Data{data: ^value}} = roundtrip(part, :part)
    end
  end

  # -- message / artifact / task -------------------------------------------------

  test "Message.extensions as a list round-trips as a list" do
    msg = %{Message.new_user("x") | extensions: ["https://ext.example/a", "https://ext.example/b"]}
    {:ok, wire} = JSON.encode(msg)
    assert wire["extensions"] == ["https://ext.example/a", "https://ext.example/b"]
    assert {:ok, %Message{extensions: ["https://ext.example/a", "https://ext.example/b"]}} =
             roundtrip(msg, :message)
  end

  test "messageId is a required non-empty strings on decode" do
    base = %{"role" => "ROLE_USER", "parts" => [%{"text" => "x"}]}
    assert {:error, {:missing_field, "messageId"}} = JSON.decode(base, :message)
    assert {:error, {:invalid_field, "messageId"}} = JSON.decode(Map.put(base, "messageId", ""), :message)
    assert {:ok, %Message{message_id: "m1"}} = JSON.decode(Map.put(base, "messageId", "m1"), :message)
  end

  test "Task contextId nil encodes as proto default \"\" and a real id round-trips" do
    task = %AshA2A.Protocol.Task{
      id: "t1",
      context_id: nil,
      status: AshA2A.Protocol.Task.Status.new(:working)
    }

    {:ok, wire} = JSON.encode(task)
    assert wire["contextId"] == ""
    assert {:ok, %AshA2A.Protocol.Task{context_id: "c1"}} = JSON.decode(%{wire | "contextId" => "c1"}, :task)
  end

  # -- agent card ----------------------------------------------------------------

  test "AgentSkill examples and AgentInterface tenant round-trip through the card codec" do
    {:ok, decoded} =
      card(%{
        "skills" => [
          %{"id" => "s", "name" => "S", "description" => "d", "tags" => [], "examples" => ["do x", "do y"]}
        ],
        "supportedInterfaces" => [
          %{
            "url" => "https://a.example/rpc",
            "protocolBinding" => "JSONRPC",
            "protocolVersion" => "1.0",
            "tenant" => "acme"
          }
        ]
      })

    assert [%{examples: ["do x", "do y"]}] = decoded.skills
    assert [%{tenant: "acme"}] = decoded.supported_interfaces

    wire = JSON.encode_agent_card(decoded, url: "https://a.example/rpc")
    assert [%{"examples" => ["do x", "do y"]}] = wire["skills"]
    assert [%{"tenant" => "acme"}] = wire["supportedInterfaces"]
  end

  test "security scheme description and bearerFormat round-trip" do
    {:ok, decoded} =
      card(%{
        "securitySchemes" => %{
          "b" => %{"httpAuthSecurityScheme" => %{"scheme" => "Bearer", "bearerFormat" => "JWT", "description" => "tok"}},
          "k" => %{"apiKeySecurityScheme" => %{"name" => "X-Key", "location" => "header", "description" => "key"}},
          "o" => %{"openIdConnectSecurityScheme" => %{"openIdConnectUrl" => "https://i/.well-known", "description" => "oidc"}},
          "m" => %{"mtlsSecurityScheme" => %{"description" => "mtls"}}
        }
      })

    assert %SecurityScheme.HTTPAuth{bearer_format: "JWT", description: "tok"} = decoded.security_schemes["b"]
    assert %SecurityScheme.APIKey{description: "key"} = decoded.security_schemes["k"]
    assert %SecurityScheme.OpenIDConnect{description: "oidc"} = decoded.security_schemes["o"]
    assert %SecurityScheme.MutualTLS{description: "mtls"} = decoded.security_schemes["m"]

    wire = JSON.encode_agent_card(decoded, url: "https://a.example/rpc")

    assert %{"httpAuthSecurityScheme" => %{"bearerFormat" => "JWT", "description" => "tok"}} =
             wire["securitySchemes"]["b"]

    assert %{"mtlsSecurityScheme" => %{"description" => "mtls"}} = wire["securitySchemes"]["m"]
  end

  test "malformed security scheme or extension decodes to {:error, _}, never raises" do
    assert {:error, {:missing_field, _}} =
             card(%{"securitySchemes" => %{"b" => %{"httpAuthSecurityScheme" => %{}}}})

    assert {:error, {:missing_field, _}} =
             card(%{"securitySchemes" => %{"k" => %{"apiKeySecurityScheme" => %{"name" => "n"}}}})

    assert {:error, {:invalid_field, "securitySchemes"}} =
             card(%{"securitySchemes" => %{"x" => %{"nonsense" => %{}}}})

    assert {:error, {:missing_field, _}} =
             card(%{"capabilities" => %{"extensions" => [%{"description" => "no uri"}]}})
  end

  test "card decode keeps the protocol_version default when the member is absent or null" do
    default = AshA2A.Protocol.Version.protocol_version()
    assert {:ok, %{protocol_version: ^default}} = card()
    assert {:ok, %{protocol_version: ^default}} = card(%{"protocolVersion" => nil})
    assert {:ok, %{protocol_version: "0.3"}} = card(%{"protocolVersion" => "0.3"})
  end

  # -- JSON-RPC param validation ---------------------------------------------------

  test "push config methods without taskId answer -32602" do
    opts = start_plug!(AshA2A.Test.PlugFixture.GreeterAgent, capabilities: %{push_notifications: true})

    for {method, params} <- [
          {"tasks/pushNotificationConfig/set", %{"url" => "https://h.example/w"}},
          {"tasks/pushNotificationConfig/get", %{}},
          {"tasks/pushNotificationConfig/list", %{}},
          {"tasks/pushNotificationConfig/delete", %{"pushNotificationConfigId" => "c1"}}
        ] do
      assert %{"error" => %{"code" => -32_602}} = rpc_body(opts, method, params), method
    end
  end

  test "nested configuration.historyLength is validated" do
    opts = start_plug!(AshA2A.Test.PlugFixture.GreeterAgent)

    for bad <- [-1, "3", 1.5] do
      params = %{"message" => wire_message(), "configuration" => %{"historyLength" => bad}}
      assert %{"error" => %{"code" => -32_602}} = rpc_body(opts, "message/send", params)
    end

    ok = %{"message" => wire_message(), "configuration" => %{"historyLength" => 0}}
    assert %{"result" => %{"task" => _}} = rpc_body(opts, "message/send", ok)
  end

  test "extended card with no provider answers -32007 (ExtendedAgentCardNotConfigured)" do
    opts = start_plug!(AshA2A.Test.PlugFixture.GreeterAgent)
    assert %{"error" => %{"code" => -32_007}} = rpc_body(opts, "agent/getAuthenticatedExtendedCard", %{})
  end

  test "push config list paginates with pageSize/pageToken/nextPageToken" do
    opts = start_plug!(AshA2A.Test.PlugFixture.GreeterAgent, capabilities: %{push_notifications: true})

    %{"result" => %{"task" => %{"id" => task_id}}} =
      rpc_body(opts, "message/send", %{"message" => wire_message()})

    for n <- 1..3 do
      assert %{"result" => %{"id" => _}} =
               rpc_body(opts, "tasks/pushNotificationConfig/set", %{
                 "taskId" => task_id,
                 "id" => "cfg-#{n}",
                 "url" => "https://h.example/w#{n}"
               })
    end

    %{"result" => page1} =
      rpc_body(opts, "tasks/pushNotificationConfig/list", %{"taskId" => task_id, "pageSize" => 2})

    assert length(page1["configs"]) == 2
    assert is_binary(page1["nextPageToken"])

    %{"result" => page2} =
      rpc_body(opts, "tasks/pushNotificationConfig/list", %{
        "taskId" => task_id,
        "pageSize" => 2,
        "pageToken" => page1["nextPageToken"]
      })

    assert length(page2["configs"]) == 1
    refute Map.has_key?(page2, "nextPageToken")

    ids = Enum.map(page1["configs"] ++ page2["configs"], & &1["id"]) |> Enum.sort()
    assert ids == ["cfg-1", "cfg-2", "cfg-3"]

    assert %{"error" => %{"code" => -32_602}} =
             rpc_body(opts, "tasks/pushNotificationConfig/list", %{
               "taskId" => task_id,
               "pageToken" => "!!not-a-token"
             })

    assert %{"error" => %{"code" => -32_602}} =
             rpc_body(opts, "tasks/pushNotificationConfig/list", %{"taskId" => task_id, "pageSize" => 0})
  end

  # -- client ----------------------------------------------------------------------

  test "client send encodes returnImmediately (not blocking) and taskPushNotificationConfig" do
    test_pid = self()
    plug_opts = start_plug!(AshA2A.Test.PlugFixture.GreeterAgent)

    recording_plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request_body, Jason.decode!(body)})
      served = replay(conn, body, plug_opts)
      Plug.Conn.send_resp(conn, served.status, served.resp_body)
    end

    client = AshA2A.Protocol.Client.new("http://localhost:4000/a2a")

    push = %AshA2A.Protocol.PushNotificationConfig{url: "https://h.example/w", task_id: "ignored"}

    AshA2A.Protocol.Client.send_message(client, "hi",
      plug: recording_plug,
      configuration: %{blocking: true, history_length: 2, task_push_notification_config: push}
    )

    assert_receive {:request_body, %{"params" => %{"configuration" => config}}}
    assert config["returnImmediately"] == false
    refute Map.has_key?(config, "blocking")
    assert config["historyLength"] == 2
    assert config["taskPushNotificationConfig"] == %{"url" => "https://h.example/w"}

    AshA2A.Protocol.Client.send_message(client, "hi",
      plug: recording_plug,
      configuration: %{return_immediately: true}
    )

    assert_receive {:request_body, %{"params" => %{"configuration" => %{"returnImmediately" => true}}}}
  end

  defp replay(conn, body, plug_opts) do
    :post
    |> Plug.Test.conn(conn.request_path, body)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> AshA2A.Protocol.Plug.call(plug_opts)
  end
end
