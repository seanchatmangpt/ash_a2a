defmodule AshA2A.TaskGenerationGuardsTest do
  use ExUnit.Case, async: false

  alias AshA2A.Protocol.JSONRPC
  alias AshA2A.Protocol.JSONRPC.Error
  alias AshA2A.Protocol.Task.Generation

  # Bare agents (real GenServers). `ask` pauses on :input_required so the
  # task stays continuable; everything else completes.
  defmodule OpenAgent do
    use AshA2A.Protocol.Agent,
      name: "v6-open",
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
    use AshA2A.Protocol.Agent, name: "v6-closed", description: "no client artifacts"

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
    start_supervised!({ClosedAgent, []})
    :ok
  end

  defp rpc(agent, method, params, extra_ctx \\ %{}) do
    raw = %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}
    {:reply, resp} = JSONRPC.handle(raw, Handler, Map.merge(%{agent: agent}, extra_ctx))
    resp
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

  defp gen(task), do: task["generation"] |> to_int()
  defp to_int(v) when is_binary(v), do: String.to_integer(v)
  defp to_int(v), do: v

  test "error table: -32010 TASK_GENERATION_MISMATCH / 409 / ABORTED" do
    err = Error.task_generation_mismatch(nil, task_id: "t", expected: 1, actual: 3)
    assert err.code == -32_010
    map = Error.to_map(err)

    assert [%{"reason" => "TASK_GENERATION_MISMATCH", "domain" => "a2a-protocol.org"} = info] =
             map["data"]

    assert info["metadata"]["expectedGeneration"] == "1"
    assert Error.spec_http_status(-32_010) == 409
    assert Error.grpc_status(-32_010) == 10
    assert Error.status_name_for_code(-32_010) == "ABORTED"

    env = AshA2A.ToA2AError.to_a2a_error(%AshA2A.TaskGenerationMismatchError{task_id: "t"}, 9)
    assert env["error"]["code"] == -32_010
  end

  test "ifGenerationMatch mismatch -> -32010; match proceeds; ignored for new task" do
    task = new_task(OpenAgent)
    current = gen(task)

    resp =
      rpc(OpenAgent, "SendMessage", %{
        "message" => wire_message("again", %{"taskId" => task["id"]}),
        "configuration" => %{"ifGenerationMatch" => current + 5}
      })

    assert resp["error"]["code"] == -32_010
    assert [%{"reason" => "TASK_GENERATION_MISMATCH"}] = resp["error"]["data"]

    ok =
      rpc(OpenAgent, "SendMessage", %{
        "message" => wire_message("again", %{"taskId" => task["id"]}),
        "configuration" => %{"ifGenerationMatch" => current}
      })

    assert %{"result" => %{"task" => _}} = ok

    fresh =
      rpc(OpenAgent, "SendMessage", %{
        "message" => wire_message("hello"),
        "configuration" => %{"ifGenerationMatch" => 99}
      })

    assert %{"result" => %{"task" => _}} = fresh
  end

  test "artifactUpdates refused (-32004) when user_artifacts is off" do
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

  test "artifactUpdates accepted when on: role user, start_generation set, client generation ignored" do
    task = new_task(OpenAgent)

    resp =
      rpc(OpenAgent, "SendMessage", %{
        "artifactUpdates" => [
          %{
            "taskId" => task["id"],
            "generation" => "777",
            "artifact" => %{
              "artifactId" => "a1",
              "parts" => [%{"text" => "x"}],
              "startGeneration" => "777",
              "role" => "ROLE_AGENT"
            }
          }
        ]
      })

    assert %{"result" => %{"task" => out}} = resp
    [artifact] = Enum.filter(out["artifacts"], &(&1["artifactId"] == "a1"))
    assert artifact["role"] in ["ROLE_USER", "user"]
    assert to_int(artifact["startGeneration"]) == gen(task) + 1
    assert gen(out) == gen(task) + 1
  end

  test "ifGenerationMatch helper and message-less send validation" do
    resp = rpc(OpenAgent, "SendMessage", %{})
    assert resp["error"]["code"] == -32_602
  end

  test "timelineLength truncation on GetTask and SendMessage; bad value -> -32602" do
    task = new_task(OpenAgent)
    assert length(task["timeline"] || []) >= 1

    %{"result" => got} = rpc(OpenAgent, "GetTask", %{"id" => task["id"], "timelineLength" => 1})
    assert length(got["timeline"]) == 1

    %{"result" => zero} = rpc(OpenAgent, "GetTask", %{"id" => task["id"], "timelineLength" => 0})
    assert (zero["timeline"] || []) == []

    sent =
      rpc(OpenAgent, "SendMessage", %{
        "message" => wire_message("hi"),
        "configuration" => %{"timelineLength" => 0}
      })

    assert %{"result" => %{"task" => t}} = sent
    assert (t["timeline"] || []) == []

    bad = rpc(OpenAgent, "GetTask", %{"id" => task["id"], "timelineLength" => -1})
    assert bad["error"]["code"] == -32_602
  end

  test "currentGeneration returns immediately when generation already greater" do
    task = new_task(OpenAgent)
    started = System.monotonic_time(:millisecond)

    %{"result" => got} =
      rpc(OpenAgent, "GetTask", %{"id" => task["id"], "currentGeneration" => 0}, %{
        long_poll_timeout_ms: 5_000
      })

    assert System.monotonic_time(:millisecond) - started < 2_000
    assert gen(got) == gen(task)
  end

  test "currentGeneration blocks, then returns after a transition in another process" do
    task = new_task(OpenAgent)
    current = gen(task)
    parent = self()

    poller =
      Task.async(fn ->
        send(parent, :polling)

        rpc(OpenAgent, "GetTask", %{"id" => task["id"], "currentGeneration" => current}, %{
          long_poll_timeout_ms: 10_000
        })
      end)

    assert_receive :polling, 2_000
    # not answered yet: the task has not advanced
    assert Task.yield(poller, 100) == nil

    # advance the generation via a real follow-up message in this process
    %{"result" => %{"task" => _}} =
      rpc(OpenAgent, "SendMessage", %{"message" => wire_message("go", %{"taskId" => task["id"]})})

    %{"result" => got} = Task.await(poller, 10_000)
    assert gen(got) > current
  end

  test "long-poll honors the server timeout when nothing advances" do
    task = new_task(OpenAgent)
    started = System.monotonic_time(:millisecond)

    %{"result" => got} =
      rpc(OpenAgent, "GetTask", %{"id" => task["id"], "currentGeneration" => gen(task)}, %{
        long_poll_timeout_ms: 150
      })

    assert System.monotonic_time(:millisecond) - started >= 100
    assert gen(got) == gen(task)
  end

  test "pure helpers return tagged errors" do
    t =
      Generation.append_message(AshA2A.Protocol.Task.new(), AshA2A.Protocol.Message.new_user("x"))

    assert {:error, :generation_mismatch} =
             AshA2A.Protocol.ClientArtifacts.check_generation(t, 99)

    assert :ok = AshA2A.Protocol.ClientArtifacts.check_generation(nil, 99)

    assert {:error, {:unsupported_operation, :user_artifacts}} =
             AshA2A.Protocol.ClientArtifacts.check_user_artifacts(%{capabilities: %{}}, [:x])
  end
end
