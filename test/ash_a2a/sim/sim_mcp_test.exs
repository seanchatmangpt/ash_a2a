# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Sim.McpTest do
  @moduledoc """
  The MCP server in front of the simulation server reaches the whole served
  surface, and a real MCP client proves it.

    * MIRROR: every item `AshA2A.Sim.Surface` derives from the library has a
      plan of MCP tool calls in `AshA2A.Sim.MCP.Coverage`. A method, route or
      RPC the library gains without a tool path fails here.
    * STDIO: `bin/a2a-sim-mcp` runs as its own OS process. This test speaks
      MCP to it over its standard input and output and runs the plan of every
      surface item through `tools/call`.
    * STREAMABLE HTTP: a second OS process serves `/mcp`; the same handshake,
      catalog and calls go over HTTP, a stream included.
    * SCHEMAS: every `inputSchema` and `outputSchema` is a valid JSON Schema,
      and every tool result matches its `outputSchema`.

  Nothing is mocked: the MCP servers are real OS processes, and their tools
  call real listeners.
  """

  use ExUnit.Case, async: false

  alias AshA2A.Sim.MCP.{Coverage, Server, Tools}
  alias AshA2A.Sim.Surface

  @moduletag timeout: 420_000

  @root Path.expand("../../..", __DIR__)
  @launcher Path.join(@root, "bin/a2a-sim-mcp")
  @version Server.protocol_version()

  # -- a real MCP stdio client --------------------------------------------------

  defmodule StdioClient do
    @moduledoc false
    # Owns the OS process of the MCP server and speaks newline-delimited
    # JSON-RPC to it. Every line the server writes to its standard output that
    # is not JSON is kept in `noise`.
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    def request(client, method, params \\ nil, timeout \\ 180_000),
      do: GenServer.call(client, {:request, method, params}, timeout)

    def notify(client, method, params \\ nil),
      do: GenServer.call(client, {:notify, method, params})

    def send_line(client, line, timeout \\ 30_000),
      do: GenServer.call(client, {:line, line}, timeout)

    def notifications(client), do: GenServer.call(client, :notifications)
    def noise(client), do: GenServer.call(client, :noise)

    @impl true
    def init(opts) do
      port =
        Port.open({:spawn_executable, Keyword.fetch!(opts, :launcher)}, [
          :binary,
          :exit_status,
          {:line, 16_000_000},
          {:args, Keyword.get(opts, :args, [])},
          {:env, [{~c"A2A_SIM_MCP_LOG", String.to_charlist(Keyword.fetch!(opts, :log))}]}
        ])

      {:ok,
       %{port: port, next: 1, waiting: %{}, partial: "", notes: [], noise: [], raw_waiter: nil}}
    end

    @impl true
    def handle_call({:request, method, params}, from, state) do
      id = state.next
      message = %{"jsonrpc" => "2.0", "id" => id, "method" => method}
      message = if params, do: Map.put(message, "params", params), else: message
      Port.command(state.port, [Jason.encode!(message), ?\n])
      {:noreply, %{state | next: id + 1, waiting: Map.put(state.waiting, id, from)}}
    end

    def handle_call({:notify, method, params}, _from, state) do
      message = %{"jsonrpc" => "2.0", "method" => method}
      message = if params, do: Map.put(message, "params", params), else: message
      Port.command(state.port, [Jason.encode!(message), ?\n])
      {:reply, :ok, state}
    end

    # A line the caller wrote byte for byte; the next reply with no known id
    # answers it.
    def handle_call({:line, line}, from, state) do
      Port.command(state.port, [line, ?\n])
      {:noreply, %{state | raw_waiter: from}}
    end

    def handle_call(:notifications, _from, state),
      do: {:reply, Enum.reverse(state.notes), state}

    def handle_call(:noise, _from, state), do: {:reply, Enum.reverse(state.noise), state}

    @impl true
    def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = state),
      do: {:noreply, %{state | partial: state.partial <> chunk}}

    def handle_info({port, {:data, {:eol, chunk}}}, %{port: port} = state) do
      line = state.partial <> chunk
      state = %{state | partial: ""}

      case Jason.decode(line) do
        {:ok, %{"id" => id} = reply} when is_map_key(state.waiting, id) ->
          GenServer.reply(Map.fetch!(state.waiting, id), reply)
          {:noreply, %{state | waiting: Map.delete(state.waiting, id)}}

        {:ok, %{"method" => _} = note} ->
          {:noreply, %{state | notes: [note | state.notes]}}

        {:ok, reply} when not is_nil(state.raw_waiter) ->
          GenServer.reply(state.raw_waiter, reply)
          {:noreply, %{state | raw_waiter: nil}}

        _other ->
          {:noreply, %{state | noise: [line | state.noise]}}
      end
    end

    def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
      for {_id, from} <- state.waiting, do: GenServer.reply(from, {:exited, status})
      {:noreply, %{state | waiting: %{}}}
    end

    def handle_info(_other, state), do: {:noreply, state}

    @impl true
    def terminate(_reason, state) do
      if Port.info(state.port), do: Port.close(state.port)
      :ok
    end
  end

  # -- the plan interpreter -------------------------------------------------------
  #
  # `AshA2A.Sim.MCP.Coverage.plan/0` is data. This interpreter knows nothing
  # about A2A: it substitutes variables, calls the tool, and checks paths.

  defp substitute(value, vars) when is_binary(value) do
    case Regex.run(~r/\A\{\{(\w+)\}\}\z/, value) do
      [_, name] when is_map_key(vars, name) ->
        Map.fetch!(vars, name)

      _ ->
        Regex.replace(~r/\{\{(\w+)\}\}/, value, fn whole, name ->
          case Map.fetch(vars, name) do
            {:ok, found} -> to_string(found)
            :error -> whole
          end
        end)
    end
  end

  defp substitute(value, vars) when is_list(value), do: Enum.map(value, &substitute(&1, vars))

  defp substitute(value, vars) when is_map(value),
    do: Map.new(value, fn {key, item} -> {key, substitute(item, vars)} end)

  defp substitute(value, _vars), do: value

  defp lookup(value, path) do
    path
    |> String.split(".")
    |> Enum.reduce_while(value, fn segment, current ->
      cond do
        is_map(current) and Map.has_key?(current, segment) ->
          {:cont, Map.fetch!(current, segment)}

        is_list(current) and match?({_, ""}, Integer.parse(segment)) ->
          case Enum.fetch(current, String.to_integer(segment)) do
            {:ok, item} -> {:cont, item}
            :error -> {:halt, nil}
          end

        true ->
          {:halt, nil}
      end
    end)
  end

  defp text_of(value) when is_binary(value), do: value
  defp text_of(value), do: Jason.encode!(value)

  defp holds?(actual, "eq", expected), do: actual == expected
  defp holds?(actual, "ne", expected), do: actual != expected
  defp holds?(actual, "in", expected), do: actual in expected
  defp holds?(nil, "contains", _expected), do: false
  defp holds?(actual, "contains", expected), do: text_of(actual) =~ to_string(expected)
  defp holds?(nil, "not_contains", _expected), do: true
  defp holds?(actual, "not_contains", expected), do: not (text_of(actual) =~ to_string(expected))
  defp holds?(actual, "exists", _expected), do: not is_nil(actual)
  defp holds?(actual, "absent", _expected), do: is_nil(actual)
  defp holds?(actual, "gte", expected), do: is_number(actual) and actual >= expected

  # One `tools/call`. Answers `{:ok, structured}` or `{:error, text}`, and
  # checks the result against the tool's outputSchema.
  defp call_tool(ctx, name, arguments, meta \\ nil) do
    params = %{"name" => name, "arguments" => arguments}
    params = if meta, do: Map.put(params, "_meta", meta), else: params

    case ctx.call.("tools/call", params) do
      %{"result" => %{"isError" => true, "content" => content}} ->
        {:error, "tool error: " <> Enum.map_join(content, " ", & &1["text"])}

      %{"result" => %{"structuredContent" => structured, "content" => [%{"text" => text}]}} ->
        cond do
          Jason.decode!(text) != structured ->
            {:error, "content text and structuredContent differ"}

          match?({:error, _}, JSV.validate(structured, Map.fetch!(ctx.output_roots, name))) ->
            {:error, error} = JSV.validate(structured, Map.fetch!(ctx.output_roots, name))
            {:error, "result does not match outputSchema: #{inspect(error, limit: 20)}"}

          true ->
            {:ok, structured}
        end

      other ->
        {:error, "unexpected reply #{inspect(other, limit: 12, printable_limit: 300)}"}
    end
  end

  defp run_step(ctx, step, vars) do
    arguments = substitute(step["arguments"], vars)
    deadline = System.monotonic_time(:millisecond) + Map.get(step, "retry_ms", 0)
    attempt(ctx, step, arguments, vars, deadline)
  end

  defp attempt(ctx, step, arguments, vars, deadline) do
    outcome =
      with {:ok, structured} <- call_tool(ctx, step["tool"], arguments) do
        failed =
          Enum.find(Map.get(step, "expect", []), fn expectation ->
            wanted = substitute(expectation["value"], vars)
            not holds?(lookup(structured, expectation["path"]), expectation["op"], wanted)
          end)

        case failed do
          nil ->
            {:ok, structured}

          %{"path" => path, "op" => op, "value" => value} ->
            {:error,
             "#{path}: expected #{op} #{inspect(substitute(value, vars))}, got " <>
               inspect(lookup(structured, path), limit: 12, printable_limit: 300)}
        end
      end

    case outcome do
      {:ok, structured} ->
        captured =
          for {name, path} <- Map.get(step, "capture", %{}), into: %{} do
            {name, lookup(structured, path)}
          end

        if Enum.any?(captured, fn {_name, value} -> is_nil(value) end),
          do: {:error, "nothing to capture: #{inspect(captured)}"},
          else: {:ok, Map.merge(vars, captured)}

      {:error, reason} ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(100)
          attempt(ctx, step, arguments, vars, deadline)
        else
          {:error, reason}
        end
    end
  end

  # Runs one surface item's plan; answers `:ok` or `{:error, text}`.
  defp run_entry(ctx, entry, info) do
    vars = Map.put(info, "uniq", Base.encode16(:crypto.strong_rand_bytes(5), case: :lower))
    steps = entry["steps"]

    {_vars, failure} =
      steps
      |> Enum.with_index(1)
      |> Enum.reduce({vars, nil}, fn {step, index}, {vars, failure} ->
        if failure && !step["always"] do
          {vars, failure}
        else
          case run_step(ctx, step, vars) do
            {:ok, vars} ->
              {vars, failure}

            {:error, reason} ->
              {vars, failure || "step #{index}/#{length(steps)} (#{step["label"]}): #{reason}"}
          end
        end
      end)

    cond do
      failure -> {:error, failure}
      not Enum.any?(steps, & &1["tested"]) -> {:error, "no step reaches the item"}
      true -> :ok
    end
  end

  # -- shared setup ----------------------------------------------------------------

  setup_all do
    log =
      Path.join(System.tmp_dir!(), "a2a-sim-mcp-test-#{System.unique_integer([:positive])}.log")

    client = start_supervised!({StdioClient, launcher: @launcher, log: log})

    init =
      StdioClient.request(client, "initialize", %{
        "protocolVersion" => @version,
        "capabilities" => %{},
        "clientInfo" => %{"name" => "sim_mcp_test", "version" => "1"}
      })

    :ok = StdioClient.notify(client, "notifications/initialized")
    %{"result" => %{"tools" => tools}} = StdioClient.request(client, "tools/list")

    ctx = %{
      call: fn method, params -> StdioClient.request(client, method, params) end,
      output_roots: Map.new(tools, &{&1["name"], JSV.build!(&1["outputSchema"])})
    }

    {:ok, info} = call_tool(ctx, "sim_info", %{})

    {:ok, client: client, init: init, tools: tools, ctx: ctx, info: info, log: log}
  end

  # == MIRROR ========================================================================

  describe "mirror" do
    test "every surface item has an MCP tool path" do
      uncovered = Coverage.uncovered()

      assert uncovered == [],
             "served surface items MCP cannot reach:\n" <>
               Enum.map_join(uncovered, "\n", &"  #{&1.id} (from #{&1.source})")

      plan = Coverage.plan()

      assert Enum.map(plan, & &1["surface"]) ==
               Surface.ids() ++ Enum.map(Surface.parity(), & &1.id)

      for entry <- plan do
        assert Enum.any?(entry["steps"], & &1["tested"]), "#{entry["surface"]} has no tested step"
        assert is_binary(entry["tool"])
      end
    end

    test "every step calls a tool the catalog has" do
      names = MapSet.new(Tools.names())

      strays =
        for entry <- Coverage.plan(), step <- entry["steps"], step["tool"] not in names do
          {entry["surface"], step["tool"]}
        end

      assert strays == []
    end

    test "a served item with no tool path is reported" do
      new_rpc = %{id: "grpc_rpc:BrandNewRpc", kind: :grpc_rpc, name: "BrandNewRpc", source: "x"}

      new_method = %{
        id: "jsonrpc_method:x/new",
        kind: :jsonrpc_method,
        name: "x/new",
        source: "x"
      }

      new_route = %{id: "http_route:PUT /new", kind: :http_route, name: "PUT /new", source: "x"}
      new_skill = %{id: "skill:New.skill", kind: :skill, name: "New.skill", source: "x"}
      new_kind = %{id: "widget:w", kind: :widget, name: "w", source: "x"}
      known = hd(Surface.items())

      added = [new_rpc, new_method, new_route, new_skill, new_kind]
      assert Coverage.uncovered([known | added]) == added
      assert Coverage.entry(new_rpc)["steps"] == []
    end

    test "each served method, route and RPC has a tool of its own, and its plan calls it", %{
      tools: tools
    } do
      listed = MapSet.new(tools, & &1["name"])

      for kind <- [:jsonrpc_method, :http_route, :grpc_rpc], item <- Surface.items(kind) do
        tool = Tools.operation_tool(item)
        assert tool in listed, "#{item.id} has no tool in tools/list"
        tested = Enum.find(Coverage.entry(item)["steps"], & &1["tested"])
        assert tested["tool"] == tool, "the plan of #{item.id} tests #{tested["tool"]}"
      end

      for item <- Surface.items(:jsonrpc_alias) do
        tested = Enum.find(Coverage.entry(item)["steps"], & &1["tested"])
        assert tested["arguments"]["method_spelling"] == item.name
      end
    end

    test "tool names are unique and fit the MCP name rules", %{tools: tools} do
      names = Enum.map(tools, & &1["name"])
      assert names == Enum.uniq(names)
      for name <- names, do: assert(name =~ ~r/\A[A-Za-z0-9_-]{1,64}\z/)
    end
  end

  # == STDIO ========================================================================

  describe "stdio" do
    test "initialize negotiates the revision and declares tools and resources", %{init: init} do
      assert %{"jsonrpc" => "2.0", "result" => result} = init
      assert result["protocolVersion"] == @version
      # The stdio launcher (scripts/mcp_shim.py) declares `listChanged` so it can
      # send notifications/tools/list_changed once the real server is up.
      assert result["capabilities"]["tools"] == %{"listChanged" => true}
      assert %{"subscribe" => false} = result["capabilities"]["resources"]
      assert result["serverInfo"]["name"] == "ash-a2a-sim-mcp"
      assert is_binary(result["serverInfo"]["version"])
      assert result["instructions"] =~ "A2A v1.1"
    end

    test "tools/list is the catalog, with the convenience and sim tools", %{tools: tools} do
      names = Enum.map(tools, & &1["name"])
      assert names == Tools.names()

      for name <-
            ~w(a2a_send_message a2a_stream_message a2a_live_message a2a_get_task a2a_list_tasks
               a2a_cancel_task a2a_subscribe_task a2a_create_push_config a2a_get_push_config
               a2a_list_push_configs a2a_delete_push_config a2a_get_agent_card
               a2a_get_extended_agent_card a2a_raw_request sim_grant_authority
               sim_revoke_authority sim_read_rows sim_push_deliveries sim_surface sim_prove) do
        assert name in names
      end

      send_tool = Enum.find(tools, &(&1["name"] == "a2a_send_message"))
      props = send_tool["inputSchema"]["properties"]
      assert props["binding"]["enum"] == ["jsonrpc", "http_json", "grpc"]
      assert props["a2a_version"]["default"] == "1.1"
      assert "binding" in send_tool["inputSchema"]["required"]
      assert "create_note" in props["skill"]["enum"]
    end

    test "every surface item is reached through tools/call", %{ctx: ctx, info: info} do
      # The parity plans need the Python reference; without it they are run
      # (and reported) by "the parity check is reached through sim_parity".
      failures =
        for entry <- Coverage.plan(),
            entry["kind"] != "parity",
            {:error, reason} <- [run_entry(ctx, entry, info)] do
          "  #{entry["surface"]} [#{entry["tool"]}]: #{reason}"
        end

      assert failures == [],
             "surface items that failed through MCP:\n" <> Enum.join(failures, "\n")
    end

    test "the parity check is reached through sim_parity", %{ctx: ctx, info: info} do
      entries = Enum.filter(Coverage.plan(), &(&1["kind"] == "parity"))
      assert Enum.map(entries, & &1["name"]) == AshA2A.Sim.Parity.bindings()
      assert Enum.all?(entries, &(&1["tool"] == "sim_parity"))

      case AshA2A.Sim.Parity.check() do
        {:ok, _python} ->
          failures =
            for entry <- entries, {:error, reason} <- [run_entry(ctx, entry, info)] do
              "  #{entry["surface"]}: #{reason}"
            end

          assert failures == [],
                 "parity surfaces that failed through MCP:\n" <> Enum.join(failures, "\n")

          assert {:ok, strict} =
                   call_tool(ctx, "sim_parity", %{"strict" => true, "statuses" => ["fail"]})

          assert strict["ran"]
          assert strict["summary"]["fail"] == 0
          assert strict["rows"] == []
          assert length(strict["verdicts"]) == length(entries)
          assert strict["ok"] == (strict["summary"]["known"] == 0)

        {:skip, reason} ->
          # Without the reference the tool says so instead of answering a verdict.
          assert {:ok, %{"ran" => false, "ok" => false, "reason" => ^reason, "verdicts" => []}} =
                   call_tool(ctx, "sim_parity", %{})
      end
    end

    test "create, update and destroy change the Ash rows, read back with sim_read_rows", %{
      ctx: ctx
    } do
      title = "explicit-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

      send = fn binding, skill, data ->
        %{"binding" => binding, "skill" => skill, "data" => data}
      end

      assert {:ok, created} =
               call_tool(
                 ctx,
                 "a2a_send_message",
                 send.("jsonrpc", "create_note", %{"title" => title})
               )

      assert created["status"] == 200
      assert created["state"] == "TASK_STATE_COMPLETED"
      assert created["request"]["headers"]["a2a-version"] == "1.1"
      assert Jason.decode!(created["body"])["result"]["task"]["id"] == created["task"]["id"]
      id = created["data"]["id"]

      assert {:ok, %{"count" => 1, "rows" => [%{"id" => ^id, "title" => ^title, "body" => nil}]}} =
               call_tool(ctx, "sim_read_rows", %{"title" => title})

      assert {:ok, %{"state" => "TASK_STATE_COMPLETED"}} =
               call_tool(
                 ctx,
                 "a2a_send_message",
                 send.("http_json", "update_note", %{"id" => id, "body" => "changed"})
               )

      assert {:ok, %{"rows" => [%{"body" => "changed", "title" => ^title}]}} =
               call_tool(ctx, "sim_read_rows", %{"id" => id})

      assert {:ok, %{"state" => "TASK_STATE_COMPLETED", "status" => 0}} =
               call_tool(ctx, "a2a_send_message", send.("grpc", "delete_note", %{"id" => id}))

      assert {:ok, %{"count" => 0, "rows" => []}} = call_tool(ctx, "sim_read_rows", %{"id" => id})
    end

    test "a mutation without authority is refused on every binding and writes nothing", %{
      ctx: ctx
    } do
      for binding <- ["jsonrpc", "http_json", "grpc"] do
        title = "refused-#{binding}-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

        assert {:ok, refused} =
                 call_tool(ctx, "a2a_send_message", %{
                   "binding" => binding,
                   "skill" => "create_note",
                   "data" => %{"title" => title},
                   "token" => "reader"
                 })

        assert refused["state"] == "TASK_STATE_REJECTED"
        assert Jason.encode!(refused["task"]) =~ "authority_required"
        assert {:ok, %{"count" => 0}} = call_tool(ctx, "sim_read_rows", %{"title" => title})
      end
    end

    test "a grant issued through MCP admits the caller, a revoke refuses it, a re-grant admits it again",
         %{ctx: ctx} do
      agent = "sim-agent-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
      grant = %{"identity" => agent, "skill" => "create_note"}

      create = fn title ->
        call_tool(ctx, "a2a_send_message", %{
          "binding" => "jsonrpc",
          "skill" => "create_note",
          "data" => %{"title" => title},
          "token" => agent
        })
      end

      assert {:ok, %{"state" => "TASK_STATE_REJECTED"}} = create.(agent <> "-before")

      assert {:ok,
              %{"grants" => [%{"granted" => true, "capability_id" => "AshA2A.Sim.Note.create"}]}} =
               call_tool(ctx, "sim_grant_authority", grant)

      assert {:ok, %{"state" => "TASK_STATE_COMPLETED"}} = create.(agent <> "-granted")

      assert {:ok, %{"grants" => [%{"granted" => false}]}} =
               call_tool(ctx, "sim_revoke_authority", grant)

      assert {:ok, %{"state" => "TASK_STATE_REJECTED"}} = create.(agent <> "-after")

      # A revoked grant can be issued again, and the mutation is admitted again.
      assert {:ok, %{"grants" => [%{"granted" => true, "outcome" => "granted"}]}} =
               call_tool(ctx, "sim_grant_authority", grant)

      for binding <- ["jsonrpc", "http_json", "grpc"] do
        assert {:ok, %{"state" => "TASK_STATE_COMPLETED"}} =
                 call_tool(ctx, "a2a_send_message", %{
                   "binding" => binding,
                   "skill" => "create_note",
                   "data" => %{"title" => agent <> "-regranted-" <> binding},
                   "token" => agent
                 })
      end

      assert {:ok, %{"grants" => [%{"granted" => false}]}} =
               call_tool(ctx, "sim_revoke_authority", grant)

      assert {:ok, %{"state" => "TASK_STATE_REJECTED"}} = create.(agent <> "-revoked-twice")

      assert {:ok, %{"rows" => rows}} =
               call_tool(ctx, "sim_read_rows", %{"title_prefix" => agent})

      assert Enum.sort(Enum.map(rows, & &1["title"])) ==
               Enum.sort([
                 agent <> "-granted"
                 | for(b <- ~w(jsonrpc http_json grpc), do: agent <> "-regranted-" <> b)
               ])
    end

    test "a stream is collected, and each frame is a progress notification", %{
      ctx: ctx,
      client: client
    } do
      token = "progress-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

      assert {:ok, stream} =
               call_tool(
                 ctx,
                 "a2a_stream_message",
                 %{
                   "binding" => "http_json",
                   "skill" => "list_notes",
                   "data" => %{"stream" => true}
                 },
                 %{"progressToken" => token}
               )

      assert stream["headers"]["content-type"] =~ "text/event-stream"
      assert stream["body"] =~ "data: "
      assert hd(stream["frame_kinds"]) == "task"
      assert stream["final_state"] == "TASK_STATE_COMPLETED"
      assert "TASK_STATE_WORKING" in stream["states"]

      progress =
        for %{"method" => "notifications/progress", "params" => %{"progressToken" => ^token} = p} <-
              StdioClient.notifications(client),
            do: p

      assert length(progress) == length(stream["frames"])
      assert Enum.map(progress, & &1["progress"]) == Enum.to_list(1..length(progress))
      assert Enum.map(progress, &Jason.decode!(&1["message"])) == stream["frames"]
    end

    test "a running task is canceled", %{ctx: ctx} do
      for binding <- ["jsonrpc", "http_json", "grpc"] do
        assert {:ok, started} =
                 call_tool(ctx, "a2a_send_message", %{
                   "binding" => binding,
                   "skill" => "slow_count",
                   "data" => %{"delay_ms" => 30_000},
                   "return_immediately" => true
                 })

        id = started["task"]["id"]
        cancel = %{"binding" => binding, "task_id" => id}

        assert {:ok, %{"state" => "TASK_STATE_CANCELED"}} =
                 call_tool(ctx, "a2a_cancel_task", cancel)

        assert {:ok, %{"state" => "TASK_STATE_CANCELED"}} = call_tool(ctx, "a2a_get_task", cancel)
      end
    end

    test "a push config delivers a real webhook, read back with sim_push_deliveries", %{
      ctx: ctx,
      info: info
    } do
      for binding <- ["jsonrpc", "http_json", "grpc"] do
        suffix =
          "/explicit-#{binding}-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

        parked = %{"binding" => binding, "skill" => "create_note", "data" => %{}}

        assert {:ok, %{"state" => "TASK_STATE_INPUT_REQUIRED"} = task} =
                 call_tool(ctx, "a2a_send_message", parked)

        id = task["task"]["id"]

        assert {:ok, %{"config" => %{"id" => config_id}}} =
                 call_tool(ctx, "a2a_create_push_config", %{
                   "binding" => binding,
                   "task_id" => id,
                   "url" => info["push_url"] <> suffix,
                   "push_token" => "secret-" <> binding
                 })

        assert is_binary(config_id)

        assert {:ok, %{"state" => "TASK_STATE_COMPLETED"}} =
                 call_tool(ctx, "a2a_send_message", %{
                   "binding" => binding,
                   "skill" => "create_note",
                   "data" => %{"title" => "pushed" <> suffix},
                   "task_id" => id
                 })

        assert {:ok, %{"deliveries" => [_ | _] = deliveries}} =
                 call_tool(ctx, "sim_push_deliveries", %{
                   "path_suffix" => suffix,
                   "wait_ms" => 8_000
                 })

        last = List.last(deliveries)
        assert last["headers"]["x-a2a-notification-token"] == "secret-" <> binding
        assert last["raw"] =~ id
        assert last["raw"] =~ "TASK_STATE_COMPLETED"
      end
    end

    test "a subscription resumes after lastSeenGeneration", %{ctx: ctx} do
      for binding <- ["jsonrpc", "http_json", "grpc"] do
        assert {:ok, started} =
                 call_tool(ctx, "a2a_send_message", %{
                   "binding" => binding,
                   "skill" => "slow_count",
                   "data" => %{"delay_ms" => 1_000},
                   "return_immediately" => true
                 })

        assert {:ok, resumed} =
                 call_tool(ctx, "a2a_subscribe_task", %{
                   "binding" => binding,
                   "task_id" => started["task"]["id"],
                   "last_seen_generation" => 1
                 })

        assert resumed["ok"], inspect(resumed["error"])
        assert resumed["final_state"] == "TASK_STATE_COMPLETED"
        sent = Jason.encode!(resumed["request"])
        assert sent =~ "lastSeenGeneration"
      end
    end

    test "malformed requests reach the server byte for byte through a2a_raw_request", %{ctx: ctx} do
      assert {:ok, bad_json} =
               call_tool(ctx, "a2a_raw_request", %{"binding" => "jsonrpc", "body" => "{not json"})

      assert bad_json["request"]["body"] == "{not json"
      assert bad_json["error"]["code"] == -32_700
      assert Jason.decode!(bad_json["body"])["id"] == nil

      assert {:ok, %{"status" => 400, "ok" => false} = rest} =
               call_tool(ctx, "a2a_raw_request", %{
                 "binding" => "http_json",
                 "path" => "/message:send",
                 "body" => "{not json"
               })

      assert rest["body"] =~ "INVALID_ARGUMENT"

      # A well-formed envelope whose params are the wrong shape.
      assert {:ok, wrong_shape} =
               call_tool(ctx, "a2a_raw_request", %{
                 "binding" => "jsonrpc",
                 "json" => %{
                   "jsonrpc" => "2.0",
                   "id" => 7,
                   "method" => "message/send",
                   "params" => %{}
                 }
               })

      assert wrong_shape["error"]["code"] == -32_602
      assert wrong_shape["json"]["id"] == 7

      # Bytes that are not UTF-8, as a gRPC message.
      garbage = Base.encode64(<<255, 255, 255, 1, 2>>)

      assert {:ok, grpc} =
               call_tool(ctx, "a2a_raw_request", %{"binding" => "grpc", "body_base64" => garbage})

      assert grpc["request"]["body_base64"] == garbage
      assert grpc["ok"] == false
      assert grpc["status"] != 0
      assert is_binary(grpc["trailers"]["grpc-status"])

      # Bytes that are not HTTP, on the socket.
      assert {:ok, %{"status" => 400, "ok" => false}} =
               call_tool(ctx, "a2a_raw_request", %{
                 "binding" => "jsonrpc",
                 "transport" => "tcp",
                 "body" => "NOT HTTP AT ALL\r\n\r\n"
               })
    end

    test "sim_prove runs the prover and the matrix becomes a resource", %{ctx: ctx} do
      assert {:ok, matrix} = call_tool(ctx, "sim_prove", %{"surface_prefix" => "consequence:"})
      assert matrix["summary"]["fail"] == 0
      assert matrix["summary"]["pass"] == length(matrix["results"])
      assert matrix["uncovered"] == []
      assert Enum.all?(matrix["results"], &String.starts_with?(&1["surface"], "consequence:"))
      assert length(matrix["results"]) >= length(Surface.items(:consequence))

      assert %{"result" => %{"contents" => [%{"uri" => "sim://prover/matrix", "text" => text}]}} =
               ctx.call.("resources/read", %{"uri" => "sim://prover/matrix"})

      assert Jason.decode!(text)["results"] == matrix["results"]
    end

    test "resources: the agent card, the surface, the coverage plan", %{ctx: ctx} do
      assert %{"result" => %{"resources" => resources}} = ctx.call.("resources/list", nil)
      uris = Enum.map(resources, & &1["uri"])

      for uri <- ~w(a2a://agent-card sim://surface sim://prover/matrix sim://coverage sim://info) do
        assert uri in uris

        assert %{
                 "result" => %{
                   "contents" => [
                     %{"uri" => ^uri, "mimeType" => "application/json", "text" => text}
                   ]
                 }
               } =
                 ctx.call.("resources/read", %{"uri" => uri})

        assert is_map(Jason.decode!(text))
      end

      read = fn uri ->
        %{"result" => %{"contents" => [%{"text" => text}]}} =
          ctx.call.("resources/read", %{"uri" => uri})

        Jason.decode!(text)
      end

      card = read.("a2a://agent-card")
      assert card["name"] == "ash-a2a-sim"
      assert Map.has_key?(card["securitySchemes"], "bearer_auth")

      surface = read.("sim://surface")
      assert Enum.map(surface["items"], & &1["id"]) == Enum.map(Coverage.items(), & &1.id)
      assert surface["uncovered"] == []
      assert Enum.all?(surface["items"], &(&1["tools"] != []))

      assert read.("sim://coverage")["items"] == Jason.decode!(Jason.encode!(Coverage.plan()))

      assert %{"error" => %{"code" => -32_002}} =
               ctx.call.("resources/read", %{"uri" => "sim://nope"})
    end

    test "protocol errors are JSON-RPC errors; tool failures are isError results", %{
      ctx: ctx,
      client: client
    } do
      assert %{"result" => %{}} = ctx.call.("ping", nil)
      assert %{"error" => %{"code" => -32_601}} = ctx.call.("no/such/method", nil)

      assert %{"error" => %{"code" => -32_602, "message" => "Unknown tool: nope"}} =
               ctx.call.("tools/call", %{"name" => "nope", "arguments" => %{}})

      assert %{"result" => %{"isError" => true, "content" => [%{"text" => text}]}} =
               ctx.call.("tools/call", %{
                 "name" => "a2a_send_message",
                 "arguments" => %{"binding" => "carrier-pigeon", "bogus" => 1}
               })

      assert text =~ "arguments.binding must be one of"
      assert text =~ "arguments.bogus is not a known argument"

      assert %{"result" => %{"isError" => true, "content" => [%{"text" => live}]}} =
               ctx.call.("tools/call", %{
                 "name" => "a2a_get_task",
                 "arguments" => %{"binding" => "grpc"}
               })

      assert live =~ "arguments.task_id is required"

      assert %{"error" => %{"code" => -32_700}, "id" => nil} =
               StdioClient.send_line(client, "{this is not json")

      assert %{"error" => %{"code" => -32_600}, "id" => nil} =
               StdioClient.send_line(client, ~s([{"jsonrpc":"2.0","id":1,"method":"ping"}]))
    end

    test "standard output carried MCP messages and nothing else", %{client: client, ctx: ctx} do
      # A log line is certain to have been written by now: the server logs
      # every refusal the tests above provoked.
      assert %{"result" => %{}} = ctx.call.("ping", nil)
      assert StdioClient.noise(client) == []
    end
  end

  # == SCHEMAS =========================================================================

  describe "schemas" do
    test "every inputSchema and outputSchema is a valid JSON Schema", %{tools: tools} do
      for tool <- tools, key <- ["inputSchema", "outputSchema"] do
        schema = tool[key]
        assert schema["type"] == "object", "#{tool["name"]} #{key} is not an object schema"
        assert well_formed(schema, "#{tool["name"]}.#{key}") == []
        assert %JSV.Root{} = JSV.build!(schema)
      end

      for tool <- tools do
        input = tool["inputSchema"]
        assert input["additionalProperties"] == false
        assert input["required"] -- Map.keys(input["properties"]) == []
        assert is_binary(tool["description"]) and tool["description"] != ""
      end
    end

    test "the schema check itself rejects a malformed schema" do
      assert well_formed(%{"type" => "strnig"}, "x") != []
      assert well_formed(%{"type" => "object", "required" => "id"}, "x") != []
      assert well_formed(%{"type" => "object", "properties" => %{"a" => 1}}, "x") != []
      assert well_formed(%{"type" => "array", "items" => %{"enum" => "a"}}, "x") != []
    end

    test "a result that breaks its outputSchema is caught", %{ctx: ctx} do
      root = Map.fetch!(ctx.output_roots, "sim_read_rows")

      assert {:ok, _} =
               JSV.validate(
                 %{"count" => 0, "total" => 0, "rows" => [], "publications" => []},
                 root
               )

      assert {:error, _} =
               JSV.validate(
                 %{"count" => "0", "total" => 0, "rows" => [], "publications" => []},
                 root
               )

      assert {:error, _} = JSV.validate(%{"count" => 0, "rows" => []}, root)
    end
  end

  @types ~w(object array string integer number boolean null)

  # The keywords the catalog uses, each checked for its own shape.
  defp well_formed(schema, path) when is_map(schema) do
    type =
      case schema["type"] do
        nil ->
          []

        type when is_binary(type) ->
          if type in @types, do: [], else: ["#{path}: type #{type}"]

        types when is_list(types) ->
          for t <- types, t not in @types, do: "#{path}: type #{inspect(t)}"

        other ->
          ["#{path}: type #{inspect(other)}"]
      end

    enum = if is_nil(schema["enum"]) or is_list(schema["enum"]), do: [], else: ["#{path}: enum"]

    required =
      case schema["required"] do
        nil ->
          []

        list when is_list(list) ->
          if Enum.all?(list, &is_binary/1), do: [], else: ["#{path}: required"]

        _ ->
          ["#{path}: required"]
      end

    props =
      case schema["properties"] do
        nil ->
          []

        %{} = props ->
          Enum.flat_map(props, fn {key, sub} -> well_formed(sub, "#{path}.#{key}") end)

        _ ->
          ["#{path}: properties"]
      end

    items = if is_nil(schema["items"]), do: [], else: well_formed(schema["items"], path <> "[]")

    extra =
      case schema["additionalProperties"] do
        %{} = sub -> well_formed(sub, path <> ".*")
        other when is_nil(other) or is_boolean(other) -> []
        _ -> ["#{path}: additionalProperties"]
      end

    type ++ enum ++ required ++ props ++ items ++ extra
  end

  defp well_formed(_schema, path), do: ["#{path}: not a schema object"]
end

defmodule AshA2A.Sim.McpHttpTest do
  @moduledoc """
  The same MCP server over Streamable HTTP: a second OS process
  (`bin/a2a-sim-mcp --http PORT`) serves `/mcp`, and this test speaks MCP to
  it with a real HTTP client.
  """

  use ExUnit.Case, async: false

  alias AshA2A.Sim.MCP.{Server, Tools}

  @moduletag timeout: 240_000

  @root Path.expand("../../..", __DIR__)
  @launcher Path.join(@root, "bin/a2a-sim-mcp")
  @version Server.protocol_version()

  setup_all do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)

    log = Path.join(System.tmp_dir!(), "a2a-sim-mcp-http-#{port}.log")

    server =
      Port.open({:spawn_executable, @launcher}, [
        :binary,
        :exit_status,
        {:args, ["--http", Integer.to_string(port)]},
        {:env, [{~c"A2A_SIM_MCP_LOG", String.to_charlist(log)}]}
      ])

    {:os_pid, os_pid} = Port.info(server, :os_pid)
    on_exit(fn -> System.cmd("kill", [Integer.to_string(os_pid)], stderr_to_stdout: true) end)

    url = "http://127.0.0.1:#{port}/mcp"

    init = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => @version,
        "capabilities" => %{},
        "clientInfo" => %{"name" => "sim_mcp_test_http", "version" => "1"}
      }
    }

    response = await_http(url, init, System.monotonic_time(:millisecond) + 90_000, log)
    [session] = Req.Response.get_header(response, "mcp-session-id")

    {:ok, url: url, session: session, http_init: response}
  end

  defp post(url, message, headers) do
    Req.post!(url,
      json: message,
      headers: [{"accept", "application/json, text/event-stream"} | headers],
      retry: false,
      decode_body: false,
      receive_timeout: 60_000
    )
  end

  defp await_http(url, init, deadline, log) do
    case Req.post(url, json: init, retry: false, decode_body: false, receive_timeout: 10_000) do
      {:ok, %{status: 200} = response} ->
        response

      other ->
        if System.monotonic_time(:millisecond) > deadline do
          flunk("no MCP server at #{url}: #{inspect(other)}; server log: #{log}")
        else
          Process.sleep(250)
          await_http(url, init, deadline, log)
        end
    end
  end

  defp rpc(context, method, params, id \\ System.unique_integer([:positive])) do
    message = %{"jsonrpc" => "2.0", "id" => id, "method" => method}
    message = if params, do: Map.put(message, "params", params), else: message

    post(context.url, message, [
      {"mcp-session-id", context.session},
      {"mcp-protocol-version", @version}
    ])
  end

  defp events(body) do
    for block <- String.split(body, "\n\n", trim: true) do
      lines = String.split(block, "\n")
      assert "event: message" in lines
      "data: " <> data = Enum.find(lines, &String.starts_with?(&1, "data: "))
      Jason.decode!(data)
    end
  end

  test "initialize answers JSON and issues a session", %{http_init: response, session: session} do
    assert Req.Response.get_header(response, "content-type") == ["application/json"]
    assert %{"result" => result, "id" => 1} = Jason.decode!(response.body)
    assert result["protocolVersion"] == @version
    assert result["capabilities"]["tools"]
    assert byte_size(session) >= 32
  end

  test "tools/list over HTTP is the catalog", context do
    response = rpc(context, "tools/list", nil)
    assert response.status == 200
    assert Req.Response.get_header(response, "content-type") == ["application/json"]

    assert Jason.decode!(response.body)["result"]["tools"] ==
             Jason.decode!(Jason.encode!(Tools.list()))
  end

  test "a notification is accepted with 202 and no body", context do
    response =
      post(context.url, %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}, [
        {"mcp-session-id", context.session}
      ])

    assert response.status == 202
    assert response.body == ""
  end

  test "tools/call answers a server-sent event stream; a mutation lands and is read back",
       context do
    title = "http-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

    created =
      rpc(context, "tools/call", %{
        "name" => "a2a_send_message",
        "arguments" => %{
          "binding" => "grpc",
          "skill" => "create_note",
          "data" => %{"title" => title}
        }
      })

    assert created.status == 200
    assert Req.Response.get_header(created, "content-type") == ["text/event-stream"]

    assert [%{"result" => %{"isError" => false, "structuredContent" => structured}}] =
             events(created.body)

    assert structured["state"] == "TASK_STATE_COMPLETED"
    assert structured["status"] == 0

    rows =
      rpc(context, "tools/call", %{"name" => "sim_read_rows", "arguments" => %{"title" => title}})

    assert [%{"result" => %{"structuredContent" => %{"count" => 1}}}] = events(rows.body)
  end

  test "a stream's frames arrive as progress events before the response", context do
    response =
      rpc(
        context,
        "tools/call",
        %{
          "name" => "a2a_stream_message",
          "arguments" => %{
            "binding" => "jsonrpc",
            "skill" => "list_notes",
            "data" => %{"stream" => true}
          },
          "_meta" => %{"progressToken" => "http-progress"}
        },
        77
      )

    messages = events(response.body)
    {progress, [final]} = Enum.split(messages, -1)
    assert %{"id" => 77, "result" => %{"structuredContent" => structured}} = final
    assert structured["final_state"] == "TASK_STATE_COMPLETED"
    assert length(progress) == length(structured["frames"])
    assert length(progress) >= 2

    for {message, index} <- Enum.with_index(progress, 1) do
      assert message["method"] == "notifications/progress"
      assert message["params"]["progressToken"] == "http-progress"
      assert message["params"]["progress"] == index
    end

    assert Enum.map(progress, &Jason.decode!(&1["params"]["message"])) == structured["frames"]
  end

  test "a client that accepts only JSON gets JSON", context do
    response =
      Req.post!(context.url,
        json: %{
          "jsonrpc" => "2.0",
          "id" => 5,
          "method" => "tools/call",
          "params" => %{
            "name" => "a2a_get_agent_card",
            "arguments" => %{"binding" => "http_json"}
          }
        },
        headers: [{"accept", "application/json"}, {"mcp-session-id", context.session}],
        retry: false,
        decode_body: false
      )

    assert Req.Response.get_header(response, "content-type") == ["application/json"]
    assert %{"id" => 5, "result" => %{"structuredContent" => card}} = Jason.decode!(response.body)
    assert card["status"] == 200
    assert card["json"]["name"] == "ash-a2a-sim"
  end

  test "requests without a session, with an unknown one, or a foreign origin are refused",
       context do
    ping = %{"jsonrpc" => "2.0", "id" => 9, "method" => "ping"}
    assert post(context.url, ping, []).status == 400
    assert post(context.url, ping, [{"mcp-session-id", "no-such-session"}]).status == 404

    assert post(context.url, ping, [
             {"mcp-session-id", context.session},
             {"mcp-protocol-version", "1999-01-01"}
           ]).status == 400

    assert post(context.url, ping, [
             {"mcp-session-id", context.session},
             {"origin", "http://evil.example"}
           ]).status == 403

    assert post(context.url, ping, [
             {"mcp-session-id", context.session},
             {"origin", "http://localhost:3000"}
           ]).status == 200

    get = Req.get!(context.url, headers: [{"mcp-session-id", context.session}], retry: false)
    assert get.status == 405

    bad =
      Req.post!(context.url,
        body: "{nope",
        headers: [{"content-type", "application/json"}],
        retry: false,
        decode_body: false
      )

    assert bad.status == 400
    assert Jason.decode!(bad.body)["error"]["code"] == -32_700
  end

  test "DELETE ends a session", context do
    init = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-06-18",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "x", "version" => "1"}
      }
    }

    response = post(context.url, init, [])
    assert Jason.decode!(response.body)["result"]["protocolVersion"] == "2025-06-18"
    [session] = Req.Response.get_header(response, "mcp-session-id")
    ping = %{"jsonrpc" => "2.0", "id" => 2, "method" => "ping"}
    assert post(context.url, ping, [{"mcp-session-id", session}]).status == 200

    assert Req.delete!(context.url, headers: [{"mcp-session-id", session}], retry: false).status ==
             200

    assert post(context.url, ping, [{"mcp-session-id", session}]).status == 404
  end
end
