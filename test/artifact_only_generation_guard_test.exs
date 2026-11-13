# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ArtifactOnlyGenerationGuardTest do
  @moduledoc """
  X1 court: an artifact-only `message:send` honours `ifGenerationMatch`
  atomically. The agent GenServer rechecks the generation inside its
  serialized handler, so two concurrent writers holding the same generation
  cannot both succeed. Real agent GenServer, real HTTP+JSON plug; no mocks.
  """

  use ExUnit.Case, async: false

  alias AshA2A.Transport.HTTPJSON

  defmodule Agent do
    use AshA2A.Protocol.Agent,
      name: "x1-open",
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

  setup do
    start_supervised!({Agent, []})

    versions = Enum.uniq(AshA2A.Protocol.Version.supported_default() ++ ["1.0", "1.1"])
    opts = HTTPJSON.init(agent: Agent, base_url: "http://127.0.0.1/x1", versions: versions)
    {:ok, opts: opts}
  end

  defp post(opts, path, body) do
    conn =
      :post
      |> Plug.Test.conn(path, Jason.encode!(body))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("a2a-version", "1.1")
      |> AshA2A.Protocol.Plug.Auth.put_identity(%{identity: "alice"})
      |> HTTPJSON.call(opts)

    {conn.status, Jason.decode!(conn.resp_body)}
  end

  defp new_task(opts) do
    message = %{
      "messageId" => "m-#{System.unique_integer([:positive])}",
      "role" => "ROLE_USER",
      "parts" => [%{"text" => "ask"}]
    }

    {200, %{"task" => task}} = post(opts, "/message:send", %{"message" => message})
    {task["id"], gen(task)}
  end

  defp gen(%{"generation" => g}) do
    {n, ""} = g |> to_string() |> Integer.parse()
    n
  end

  defp artifact_only(opts, id, expected) do
    artifact = %{
      "artifactId" => "a-#{System.unique_integer([:positive])}",
      "parts" => [%{"text" => "x"}]
    }

    post(opts, "/message:send", %{
      "artifactUpdates" => [%{"taskId" => id, "artifact" => artifact}],
      "configuration" => %{"ifGenerationMatch" => expected}
    })
  end

  test "stale ifGenerationMatch on an artifact-only send is 409 TASK_GENERATION_MISMATCH", %{
    opts: opts
  } do
    {id, generation} = new_task(opts)

    assert {409, %{"error" => %{"details" => details}}} = artifact_only(opts, id, generation + 5)
    assert Enum.any?(details, &(&1["reason"] == "TASK_GENERATION_MISMATCH"))

    # State unchanged: the refused write did not advance the generation.
    assert {:ok, task} = GenServer.call(Agent, {:get_task, id})
    assert AshA2A.Protocol.Task.Generation.generation_of(task) == generation
  end

  test "agent handler itself refuses a stale generation (-32010 source of truth)" do
    # Bypasses the HTTP pre-check entirely: the GenServer is the authority.
    opts = HTTPJSON.init(agent: Agent, base_url: "http://127.0.0.1/x1", versions: ["1.0", "1.1"])
    {id, generation} = new_task(opts)

    {:ok, decoded} =
      AshA2A.Protocol.ClientArtifacts.decode_updates([
        %{
          "taskId" => id,
          "artifact" => %{"artifactId" => "direct", "parts" => [%{"text" => "x"}]}
        }
      ])

    assert {:error, :generation_mismatch} =
             GenServer.call(Agent, {:apply_artifact_updates, id, decoded, generation + 5})

    assert {:ok, _task} =
             GenServer.call(Agent, {:apply_artifact_updates, id, decoded, generation})
  end

  test "matching ifGenerationMatch on an artifact-only send proceeds and advances generation", %{
    opts: opts
  } do
    {id, generation} = new_task(opts)

    assert {200, body} = artifact_only(opts, id, generation)
    task = body["task"] || body
    assert task["id"] == id
    assert gen(task) > generation
  end

  test "two concurrent artifact-only sends with the same ifGenerationMatch yield exactly one success",
       %{opts: opts} do
    for _round <- 1..10 do
      {id, generation} = new_task(opts)

      results =
        1..2
        |> Enum.map(fn _ -> Task.async(fn -> artifact_only(opts, id, generation) end) end)
        |> Task.await_many(5_000)

      statuses = results |> Enum.map(&elem(&1, 0)) |> Enum.sort()
      assert statuses == [200, 409]
    end
  end
end
