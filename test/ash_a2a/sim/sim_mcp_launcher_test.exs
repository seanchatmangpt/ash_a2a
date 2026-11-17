# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Sim.McpLauncherTest do
  @moduledoc """
  `bin/a2a-sim-mcp` answers an MCP client's handshake inside the client's
  connect budget even when mix is slow or broken.

  The launcher runs as its own OS process (behind `scripts/mcp_shim.py`) and
  this test speaks MCP to it over standard input and output. A `mix` wrapper
  first on `PATH` stands in for a stale build (it sleeps before it runs the
  real mix) or a build that does not compile (it prints a compile error and
  exits 1). Nothing is mocked: the shim, the wrapper and the real server are
  real processes.
  """

  use ExUnit.Case, async: false

  @moduletag timeout: 300_000
  @root Path.expand("../../..", __DIR__)
  @launcher Path.join(@root, "bin/a2a-sim-mcp")

  setup do
    dir = Path.join(System.tmp_dir!(), "a2a_sim_launcher_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "bin"))
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  defp wrapper!(dir, body) do
    path = Path.join([dir, "bin", "mix"])
    File.write!(path, "#!/usr/bin/env bash\n" <> body)
    File.chmod!(path, 0o755)
  end

  defp slow_mix!(dir, seconds) do
    real = System.find_executable("mix") || flunk("mix is not on PATH")
    wrapper!(dir, "sleep #{seconds}\nexec #{real} \"$@\"\n")
  end

  defp launch(dir, extra_env \\ []) do
    env =
      [
        {~c"PATH", String.to_charlist(Path.join(dir, "bin") <> ":" <> System.get_env("PATH"))},
        {~c"A2A_SIM_MCP_CACHE", String.to_charlist(Path.join(dir, "cache.json"))},
        {~c"A2A_SIM_MCP_LOG", String.to_charlist(Path.join(dir, "server.log"))}
      ] ++ Enum.map(extra_env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    port =
      Port.open({:spawn_executable, @launcher}, [
        :binary,
        :exit_status,
        {:line, 4_000_000},
        {:env, env},
        {:cd, @root}
      ])

    %{port: port, id: 0, inbox: []}
  end

  defp send_frame(%{port: port}, message),
    do: Port.command(port, Jason.encode!(message) <> "\n")

  # Next frame (a request's answer or a notification), as decoded JSON.
  defp next_frame(client, timeout) do
    receive do
      {port, {:data, {:eol, line}}} when port == client.port ->
        case Jason.decode(line) do
          {:ok, frame} -> frame
          {:error, _} -> flunk("non-JSON on stdout: #{inspect(line)}")
        end

      {port, {:exit_status, status}} when port == client.port ->
        flunk("launcher exited with status #{status}")
    after
      timeout -> flunk("no frame within #{timeout} ms")
    end
  end

  defp request(client, method, params, timeout \\ 30_000) do
    id = client.id + 1
    send_frame(client, %{jsonrpc: "2.0", id: id, method: method, params: params})
    {answer, notes} = await(client, id, timeout, [])
    {answer, notes, %{client | id: id}}
  end

  defp await(client, id, timeout, notes) do
    case next_frame(client, timeout) do
      %{"id" => ^id} = answer -> {answer, Enum.reverse(notes)}
      other -> await(client, id, timeout, [other | notes])
    end
  end

  defp initialize(client) do
    request(client, "initialize", %{
      protocolVersion: "2025-11-25",
      capabilities: %{},
      clientInfo: %{name: "launcher_test", version: "1"}
    })
  end

  defp finish(%{port: port} = client) do
    send_frame(client, %{jsonrpc: "2.0", method: "notifications/initialized"})
    Port.close(port)
  end

  defp ms(fun) do
    started = System.monotonic_time(:millisecond)
    result = fun.()
    {System.monotonic_time(:millisecond) - started, result}
  end

  test "stale build, no cache: minimal handshake at once, real server later, list_changed sent",
       %{dir: dir} do
    slow_mix!(dir, 6)
    client = launch(dir, [{"A2A_SIM_MCP_INIT_WAIT", "1"}])

    {elapsed, {init, _, client}} = ms(fn -> initialize(client) end)
    assert elapsed < 5_000, "initialize took #{elapsed} ms"
    assert init["result"]["capabilities"]["tools"]["listChanged"] == true
    send_frame(client, %{jsonrpc: "2.0", method: "notifications/initialized"})

    {ping, _, client} = request(client, "ping", nil)
    assert ping["result"] == %{}
    {tools, _, client} = request(client, "tools/list", %{})
    assert tools["result"]["tools"] == []
    {resources, _, client} = request(client, "resources/list", %{})
    assert resources["result"]["resources"] == []

    # A tool call waits for the real server and then gets its real answer.
    {call, notes, client} =
      request(client, "tools/call", %{name: "sim_info", arguments: %{}}, 240_000)

    assert call["id"] == client.id
    assert %{"content" => [_ | _]} = call["result"]
    refute call["result"]["isError"]

    changed =
      notes ++
        if Enum.any?(notes, &(&1["method"] == "notifications/tools/list_changed")),
          do: [],
          else: [next_frame(client, 10_000)]

    assert Enum.any?(changed, &(&1["method"] == "notifications/tools/list_changed"))

    {tools, _, client} = request(client, "tools/list", %{})
    assert length(tools["result"]["tools"]) > 50

    assert %{"tools" => _} = File.read!(Path.join(dir, "cache.json")) |> Jason.decode!()
    finish(client)
  end

  test "stale build, warm cache: handshake and tool catalog answered from the cache", %{dir: dir} do
    # First run: healthy, no delay; writes the cache.
    first = launch(dir, [{"A2A_SIM_MCP_INIT_WAIT", "120"}])
    {init, _, first} = initialize(first)
    assert init["result"]["serverInfo"]["name"] == "ash-a2a-sim-mcp"
    {tools, _, first} = request(first, "tools/list", %{})
    real_tools = tools["result"]["tools"]
    assert length(real_tools) > 50
    finish(first)
    assert File.exists?(Path.join(dir, "cache.json"))

    # Second run: mix takes 8 s to start; the cache answers meanwhile.
    slow_mix!(dir, 8)
    second = launch(dir)

    {elapsed, {init, _, second}} = ms(fn -> initialize(second) end)
    assert elapsed < 3_000, "initialize took #{elapsed} ms"
    assert init["result"]["serverInfo"]["name"] == "ash-a2a-sim-mcp"
    {tools, _, second} = request(second, "tools/list", %{})
    assert tools["result"]["tools"] == real_tools

    {res, _, second} = request(second, "resources/list", %{})
    assert [_ | _] = res["result"]["resources"]

    {call, _, second} =
      request(second, "tools/call", %{name: "sim_info", arguments: %{}}, 240_000)

    assert %{"content" => [_ | _]} = call["result"]
    finish(second)
  end

  test "current build: the real server answers, stdout carries only MCP frames", %{dir: dir} do
    client = launch(dir, [{"A2A_SIM_MCP_INIT_WAIT", "120"}])
    {init, _, client} = initialize(client)
    assert init["result"]["protocolVersion"] == "2025-11-25"
    assert init["result"]["serverInfo"]["name"] == "ash-a2a-sim-mcp"

    {call, _, client} =
      request(client, "tools/call", %{name: "sim_info", arguments: %{}}, 120_000)

    assert call["id"] == client.id
    assert %{"structuredContent" => %{}} = call["result"]

    # An unknown tool is refused by the real server and the error reaches us unchanged.
    {unknown, _, client} =
      request(client, "tools/call", %{name: "no_such_tool", arguments: %{}})

    assert unknown["error"]["code"] == -32602
    finish(client)
  end

  test "a build that fails to compile: a JSON-RPC error names the failure and nothing hangs",
       %{dir: dir} do
    wrapper!(dir, """
    echo "Compiling 1 file (.ex)"
    echo "** (CompileError) lib/ash_a2a/broken.ex:3: undefined function boom_not_defined/0"
    exit 1
    """)

    client = launch(dir, [{"A2A_SIM_MCP_INIT_WAIT", "1"}])
    {elapsed, {init, _, client}} = ms(fn -> initialize(client) end)
    assert elapsed < 5_000
    assert init["result"]

    {call, _, client} =
      request(client, "tools/call", %{name: "sim_info", arguments: %{}}, 30_000)

    assert call["id"] == client.id
    assert call["error"]["code"] == -32603
    assert call["error"]["message"] =~ "CompileError"
    assert call["error"]["message"] =~ "boom_not_defined"

    # Later requests are refused at once too, ids preserved.
    {again, _, client} =
      request(client, "tools/call", %{name: "sim_info", arguments: %{}}, 5_000)

    assert again["error"]["message"] =~ "CompileError"
    finish(client)
  end
end
