# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.AgentStateLongPoll.Agent do
  @moduledoc false
  use AshA2A.Protocol.Agent,
    name: "x4-agent",
    description: "pauses on ask/auth, completes otherwise",
    capabilities: %{user_artifacts: true}

  alias AshA2A.Protocol.{Message, Part}

  @impl AshA2A.Protocol.Agent
  def handle_message(message, _ctx) do
    case Message.text(message) do
      "ask" -> {:input_required, [Part.Text.new("more?")]}
      "auth" -> {:error, {:auth_required, [Part.Text.new("login")]}}
      _ -> {:reply, [Part.Text.new("ok")]}
    end
  end
end

defmodule AshA2A.AgentStateLongPoll.Pipeline do
  @moduledoc "Stamps the identity named by the x-test-identity header (default alice)."

  @behaviour Plug

  def init(opts) when is_map(opts), do: opts
  def init(opts), do: AshA2A.Transport.HTTPJSON.init(opts)

  def call(conn, opts) do
    who =
      case Plug.Conn.get_req_header(conn, "x-test-identity") do
        [id | _] -> id
        [] -> "alice"
      end

    conn = AshA2A.Protocol.Plug.Auth.put_identity(conn, %{identity: who})
    AshA2A.Transport.HTTPJSON.call(conn, opts)
  end
end

defmodule AshA2A.AgentStateAndLongPollTest do
  @moduledoc """
  X4 court: long-poll cap and timeout, foreign-owner 404, paused-state stream
  lifetime, blocking send at input-required, cancel of a completed task,
  `lastChunk` -> `end_generation`, and the server artifact role default.
  Real Bandit, real agent, real `Req`; waits are deadline-bounded observations.
  """

  use ExUnit.Case, async: false

  @moduletag :serial_shard

  alias AshA2A.Protocol.{Artifact, ClientArtifacts, Message, Part}
  alias AshA2A.Test.EphemeralHttp
  alias AshA2A.AgentStateLongPoll.{Agent, Pipeline}

  @v11 [{"a2a-version", "1.1"}]
  @deadline_ms 5_000

  setup do
    start_supervised!({Agent, []})

    versions = Enum.uniq(AshA2A.Protocol.Version.supported_default() ++ ["1.0", "1.1"])
    opts = [agent: Agent, base_url: "http://127.0.0.1/x4", versions: versions]

    previous = Application.get_env(:ash_a2a, :long_poll_timeout_ms)
    Application.put_env(:ash_a2a, :long_poll_timeout_ms, 400)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:ash_a2a, :long_poll_timeout_ms, previous),
        else: Application.delete_env(:ash_a2a, :long_poll_timeout_ms)
    end)

    {:ok, server: EphemeralHttp.start!({Pipeline, Pipeline.init(opts)})}
  end

  # -- helpers -------------------------------------------------------------------

  defp wire(text), do: AshA2A.Protocol.JSON.encode!(Message.new_user([Part.Text.new(text)]))

  defp send_message(server, message, headers \\ @v11) do
    Req.post!(
      url: server.base_url <> "/message:send",
      json: %{"message" => message},
      headers: headers,
      retry: false
    )
  end

  defp new_task(server, text) do
    resp = send_message(server, wire(text))
    assert %{"task" => %{"id" => id} = task} = resp.body
    {id, task}
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

  defp open_sse(url, json) do
    parent = self()
    ref = make_ref()

    task =
      Task.async(fn ->
        Req.request!(
          method: :post,
          url: url,
          json: json,
          headers: @v11,
          retry: false,
          receive_timeout: 20_000,
          into: fn {:data, data}, {req, resp} ->
            send(parent, {:sse, ref, data})
            {:cont, {req, resp}}
          end
        )
      end)

    on_exit(fn -> Process.exit(task.pid, :kill) end)
    {ref, task}
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

  defp state_of(frame) do
    get_in(frame, ["statusUpdate", "status", "state"]) ||
      get_in(frame, ["task", "status", "state"])
  end

  defp has_state?(frames, state), do: Enum.any?(frames, &(state_of(&1) == state))

  # -- long-poll cap -----------------------------------------------------------------

  test "per-call long-poll wait is capped at the configured maximum" do
    assert ClientArtifacts.long_poll_timeout_ms(60_000) == 400
    assert ClientArtifacts.long_poll_timeout_ms(100) == 100
    assert ClientArtifacts.long_poll_timeout_ms(0) == 0
    assert ClientArtifacts.long_poll_timeout_ms(nil) == 400
    assert ClientArtifacts.long_poll_timeout_ms(-5) == 400
  end

  # -- HTTP long-poll timeout + foreign owner ------------------------------------------

  test "long-poll at the current generation returns the unchanged task at the timeout", %{
    server: server
  } do
    {id, task} = new_task(server, "ask")
    generation = gen(task)

    started = System.monotonic_time(:millisecond)

    resp =
      Req.get!(
        url: server.base_url <> "/tasks/#{id}?currentGeneration=#{generation}",
        headers: @v11,
        retry: false,
        receive_timeout: 15_000
      )

    elapsed = System.monotonic_time(:millisecond) - started

    assert resp.status == 200
    assert %{"id" => ^id} = resp.body
    assert gen(resp.body) == generation
    assert elapsed >= 300
    assert elapsed < @deadline_ms
  end

  test "a foreign owner gets 404 on GET, cancel and long-poll", %{server: server} do
    {id, task} = new_task(server, "ask")
    bob = @v11 ++ [{"x-test-identity", "bob"}]

    get = Req.get!(url: server.base_url <> "/tasks/#{id}", headers: bob, retry: false)
    assert get.status == 404

    poll =
      Req.get!(
        url: server.base_url <> "/tasks/#{id}?currentGeneration=#{gen(task)}",
        headers: bob,
        retry: false
      )

    assert poll.status == 404

    cancel = Req.post!(url: server.base_url <> "/tasks/#{id}:cancel", headers: bob, retry: false)
    assert cancel.status == 404

    # the owner still sees it
    own = Req.get!(url: server.base_url <> "/tasks/#{id}", headers: @v11, retry: false)
    assert own.status == 200
  end

  # -- stream lifetime across paused states ------------------------------------------------

  for {label, text, paused} <- [
        {"input-required", "ask", "TASK_STATE_INPUT_REQUIRED"},
        {"auth-required", "auth", "TASK_STATE_AUTH_REQUIRED"}
      ] do
    test "stream ends at #{label} (paused segment) and a follow-up completes the task", %{
      server: server
    } do
      {ref, sse} =
        open_sse(server.base_url <> "/message:stream", %{"message" => wire(unquote(text))})

      {frames0, _buffer} = collect_until(ref, "", &has_state?(&1, unquote(paused)))
      id = Enum.find_value(frames0, &get_in(&1, ["task", "id"]))
      assert is_binary(id)

      # interrupted state closes this stream segment; the task itself stays live
      assert %Req.Response{status: 200} = Task.await(sse, @deadline_ms)

      follow_up =
        AshA2A.Protocol.JSON.encode!(Message.new_user([Part.Text.new("done")]))
        |> Map.put("taskId", id)

      assert send_message(server, follow_up).status == 200
    end
  end

  # -- blocking send -------------------------------------------------------------------------

  test "blocking send returns at input-required", %{server: server} do
    resp =
      Req.post!(
        url: server.base_url <> "/message:send",
        json: %{"message" => wire("ask"), "configuration" => %{"returnImmediately" => false}},
        headers: @v11,
        retry: false,
        receive_timeout: @deadline_ms
      )

    assert resp.status == 200
    assert %{"task" => %{"status" => %{"state" => "TASK_STATE_INPUT_REQUIRED"}}} = resp.body
  end

  # -- cancel of a completed task ----------------------------------------------------------------

  test "cancel of a completed task is -32002 TASK_NOT_CANCELABLE", %{server: server} do
    {id, task} = new_task(server, "hello")
    assert get_in(task, ["status", "state"]) == "TASK_STATE_COMPLETED"

    assert AshA2A.Protocol.JSONRPC.Error.task_not_cancelable().code == -32_002

    resp = Req.post!(url: server.base_url <> "/tasks/#{id}:cancel", headers: @v11, retry: false)
    assert resp.status == 409
    assert %{"error" => %{"details" => details}} = resp.body
    assert Enum.any?(details, &(&1["reason"] == "TASK_NOT_CANCELABLE"))
  end

  # -- lastChunk -> end_generation ----------------------------------------------------------------

  defp client_update(artifact_id, last_chunk) do
    base = %{
      "artifact" => %{"artifactId" => artifact_id, "parts" => [%{"text" => "x"}]},
      "append" => true
    }

    if is_nil(last_chunk), do: base, else: Map.put(base, "lastChunk", last_chunk)
  end

  defp apply_update(update) do
    {:ok, decoded} = ClientArtifacts.decode_updates([update])
    task = ClientArtifacts.apply_updates(AshA2A.Protocol.Task.new([]), decoded)
    assert [%Artifact{} = artifact] = task.artifacts
    artifact
  end

  test "lastChunk true sets end_generation; false leaves it nil" do
    closed = apply_update(client_update("a-true", true))
    assert is_integer(closed.end_generation)
    assert closed.end_generation == closed.start_generation

    open = apply_update(client_update("a-false", false))
    assert open.end_generation == nil
    assert is_integer(open.start_generation)
  end

  # -- server artifact role --------------------------------------------------------------------------

  test "server-produced artifact role defaults to :agent" do
    {:ok, task} = AshA2A.Protocol.call(Agent, "hello")
    assert [_ | _] = task.artifacts
    # nil is the documented agent-originated default; :user marks client artifacts
    assert Enum.all?(task.artifacts, &(&1.role in [nil, :agent]))
  end
end
