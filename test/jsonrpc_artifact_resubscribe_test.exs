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
