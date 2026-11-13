defmodule AshA2A.GenerationPlugWiringTest do
  use ExUnit.Case, async: false

  alias AshA2A.Protocol.JSONRPC.Error
  alias AshA2A.Transport.Plug, as: TransportPlug

  defmodule OpenAgent do
    use AshA2A.Protocol.Agent,
      name: "v12-open",
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

  defmodule ClosedAgent do
    use AshA2A.Protocol.Agent, name: "v12-closed", description: "no client artifacts"

    @impl AshA2A.Protocol.Agent
    def handle_message(message, _ctx) do
      case AshA2A.Protocol.Message.text(message) do
        "ask" -> {:input_required, [AshA2A.Protocol.Part.Text.new("more?")]}
        _ -> {:reply, [AshA2A.Protocol.Part.Text.new("ok")]}
      end
    end
  end

  setup do
    start_supervised!({OpenAgent, []})
    start_supervised!({ClosedAgent, []})
    :ok
  end

  defp rpc(agent, method, params) do
    opts = AshA2A.Protocol.Plug.init(agent: agent, base_url: "http://x/a2a")
    envelope = %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}

    conn =
      :post
      |> Plug.Test.conn("/", Jason.encode!(envelope))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> AshA2A.Protocol.Plug.call(opts)

    Jason.decode!(conn.resp_body)
  end

  defp wire_message(text, extra \\ %{}) do
    Map.merge(
      %{
        "messageId" => "m-#{System.unique_integer([:positive])}",
        "role" => "ROLE_USER",
        "parts" => [%{"text" => text}]
      },
      extra
    )
  end

  defp new_task(agent) do
    %{"result" => %{"task" => task}} =
      rpc(agent, "SendMessage", %{"message" => wire_message("ask")})

    task
  end

  test "ifGenerationMatch mismatch answers -32010 with ErrorInfo through the plug" do
    task = new_task(OpenAgent)
    current = task["generation"] |> to_string() |> String.to_integer()

    resp =
      rpc(OpenAgent, "SendMessage", %{
        "message" => wire_message("again", %{"taskId" => task["id"]}),
        "configuration" => %{"ifGenerationMatch" => current + 5}
      })

    assert resp["error"]["code"] == -32_010
    assert [%{"reason" => "TASK_GENERATION_MISMATCH"}] = resp["error"]["data"]
  end

  test "artifactUpdates on an agent without user_artifacts answers -32004" do
    task = new_task(ClosedAgent)

    resp =
      rpc(ClosedAgent, "SendMessage", %{
        "artifactUpdates" => [
          %{
            "taskId" => task["id"],
            "artifact" => %{"artifactId" => "a1", "parts" => [%{"text" => "x"}]}
          }
        ]
      })

    assert resp["error"]["code"] == -32_004
  end

  test "contextId that does not match the task answers -32602" do
    # A context-less task (nil context) may be bound by a follow-up; the
    # mismatch law applies once the task carries a context.
    %{"result" => %{"task" => task}} =
      rpc(OpenAgent, "SendMessage", %{
        "message" => wire_message("ask", %{"contextId" => "ctx-original"})
      })

    resp =
      rpc(OpenAgent, "SendMessage", %{
        "message" => wire_message("again", %{"taskId" => task["id"], "contextId" => "other-ctx"})
      })

    assert resp["error"]["code"] == -32_602
  end

  test "build_call_opts forwards ifGenerationMatch so the agent's atomic check runs" do
    task = new_task(OpenAgent)
    current = task["generation"] |> to_string() |> String.to_integer()

    # No pre-check path: the plug's call options carry :if_generation_match to
    # the agent, which refuses atomically.
    resp =
      rpc(OpenAgent, "message/send", %{
        "message" => wire_message("again", %{"taskId" => task["id"]}),
        "configuration" => %{"ifGenerationMatch" => current + 9}
      })

    assert resp["error"]["code"] == -32_010
  end

  describe "Transport.Plug reason table" do
    test "wire_error and reason_error agree on typed send refusals" do
      assert %Error{code: -32_010} = TransportPlug.wire_error(:generation_mismatch)

      assert %Error{code: -32_004} =
               TransportPlug.wire_error({:unsupported_operation, :user_artifacts})

      assert %Error{code: -32_602} = TransportPlug.wire_error(:context_mismatch)
      assert %Error{code: -32_004} = TransportPlug.wire_error(:not_continuable)

      assert %Error{code: -32_005} =
               TransportPlug.wire_error(
                 {:content_type_not_supported, %{acceptedOutputModes: ["x/y"]}}
               )

      assert TransportPlug.reason_error(:something_else) == nil
    end
  end
end
