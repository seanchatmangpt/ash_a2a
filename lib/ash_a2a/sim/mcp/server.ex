# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

if Code.ensure_loaded?(Bandit) do
  defmodule AshA2A.Sim.MCP.Server do
    @moduledoc """
    A Model Context Protocol server in front of `AshA2A.Sim.Server`: an MCP
    client drives every A2A operation of the simulation server through
    `tools/call`.

    It implements MCP revision `2025-11-25` and also negotiates `2025-06-18`
    and `2025-03-26`. `handle/3` takes one decoded JSON-RPC message and
    answers the reply; the transports (`AshA2A.Sim.MCP.Stdio`,
    `AshA2A.Sim.MCP.HTTP`) carry the bytes.

    | Method | Answer |
    |---|---|
    | `initialize` | the negotiated revision, the `tools` and `resources` capabilities, the server info and instructions |
    | `notifications/initialized` | nothing (a notification) |
    | `ping` | `{}` |
    | `tools/list` | the catalog of `AshA2A.Sim.MCP.Tools` |
    | `tools/call` | `content` (the result as JSON text), `structuredContent` (the same result as JSON) and `isError` |
    | `resources/list`, `resources/read` | the agent card, the surface inventory, the coverage plan, the server facts and the last prover matrix |
    | `resources/templates/list` | an empty list |

    A tool that ran answers `isError: false` even when the A2A server refused
    the call; the refusal is in the result. `isError: true` means the tool
    could not run: the arguments did not match its `inputSchema`, or no
    response arrived. An unknown tool is the JSON-RPC error `-32602`.

    When the `tools/call` request carries `_meta.progressToken`, each stream
    response a tool receives is sent as a `notifications/progress` message
    whose `message` is the frame as JSON.
    """

    alias AshA2A.Sim.MCP.{Coverage, Tools}

    @latest "2025-11-25"
    @supported [@latest, "2025-06-18", "2025-03-26"]

    @resources [
      {"a2a://agent-card", "agent-card", "Agent card",
       "The public agent card of the simulation server, fetched from /.well-known/agent-card.json."},
      {"sim://info", "sim-info", "Simulation server facts",
       "The bound URLs and ports, the fixture bearer tokens and the skills."},
      {"sim://surface", "surface", "Surface inventory",
       "Every served item AshA2A.Sim.Surface derives from the library, with the tools that reach it."},
      {"sim://coverage", "coverage", "Coverage plan",
       "For every surface item, the tool calls that reach it and what each must answer."},
      {"sim://prover/matrix", "prover-matrix", "Last prover matrix",
       "The result of the last sim_prove call: one row per probe."}
    ]

    @type session :: %{
            initialized: boolean(),
            ready: boolean(),
            protocol_version: String.t() | nil
          }

    @doc "The MCP revision this server implements."
    @spec protocol_version() :: String.t()
    def protocol_version, do: @latest

    @doc "The MCP revisions this server negotiates."
    @spec supported_versions() :: [String.t()]
    def supported_versions, do: @supported

    @doc "A session that has not been initialized."
    @spec new_session() :: session()
    def new_session, do: %{initialized: false, ready: false, protocol_version: nil}

    @doc """
    Handles one decoded JSON-RPC message.

    `ctx.info` is `AshA2A.Sim.Server.info/0`. `ctx.notify`, when set, is
    called with each server-to-client notification (a map).

    Answers `{reply, session}`; `reply` is `nil` for a notification.
    """
    @spec handle(term(), session(), map()) :: {map() | nil, session()}
    def handle(message, session, ctx)

    def handle(batch, session, _ctx) when is_list(batch),
      do: {error(nil, -32_600, "JSON-RPC batches are not part of MCP #{@latest}"), session}

    def handle(%{"jsonrpc" => "2.0", "method" => method} = message, session, ctx)
        when is_binary(method) do
      params = Map.get(message, "params", %{})

      case Map.fetch(message, "id") do
        {:ok, id} when is_binary(id) or is_integer(id) ->
          if is_map(params) do
            request(method, params, id, session, ctx)
          else
            {error(id, -32_602, "params must be an object"), session}
          end

        {:ok, _other} ->
          {error(nil, -32_600, "the request id must be a string or an integer"), session}

        :error ->
          {nil, notification(method, session)}
      end
    end

    # A response to a request this server never sends.
    def handle(%{"jsonrpc" => "2.0", "id" => _} = message, session, _ctx)
        when is_map_key(message, "result") or is_map_key(message, "error"),
        do: {nil, session}

    def handle(message, session, _ctx) do
      id = if is_map(message), do: Map.get(message, "id")
      id = if is_binary(id) or is_integer(id), do: id
      {error(id, -32_600, "not a JSON-RPC 2.0 request"), session}
    end

    @doc "The reply to bytes that are not JSON."
    @spec parse_error() :: map()
    def parse_error, do: error(nil, -32_700, "the message is not JSON")

    defp notification("notifications/initialized", session), do: %{session | ready: true}
    defp notification(_method, session), do: session

    defp request("initialize", params, id, session, _ctx) do
      case params["protocolVersion"] do
        requested when is_binary(requested) ->
          version = if requested in @supported, do: requested, else: @latest

          result = %{
            "protocolVersion" => version,
            "capabilities" => %{
              "tools" => %{"listChanged" => false},
              "resources" => %{"subscribe" => false, "listChanged" => false}
            },
            "serverInfo" => %{
              "name" => "ash-a2a-sim-mcp",
              "title" => "ash_a2a simulation server over MCP",
              "version" => to_string(Application.spec(:ash_a2a, :vsn) || "0.0.0")
            },
            "instructions" => instructions()
          }

          {result(id, result), %{session | initialized: true, protocol_version: version}}

        _other ->
          {error(id, -32_602, "initialize needs params.protocolVersion"), session}
      end
    end

    defp request("ping", _params, id, session, _ctx), do: {result(id, %{}), session}

    defp request(method, _params, id, %{initialized: false} = session, _ctx),
      do: {error(id, -32_600, "#{method} arrived before initialize"), session}

    defp request("tools/list", _params, id, session, _ctx),
      do: {result(id, %{"tools" => Tools.list()}), session}

    defp request("tools/call", params, id, session, ctx) do
      name = params["name"]
      arguments = Map.get(params, "arguments") || %{}

      cond do
        not is_binary(name) ->
          {error(id, -32_602, "tools/call needs params.name"), session}

        name not in Tools.names() ->
          {error(id, -32_602, "Unknown tool: #{name}"), session}

        not is_map(arguments) ->
          {error(id, -32_602, "params.arguments must be an object"), session}

        true ->
          {result(id, call_tool(name, arguments, params, ctx)), session}
      end
    end

    defp request("resources/list", _params, id, session, _ctx) do
      resources =
        for {uri, name, title, description} <- @resources do
          %{
            "uri" => uri,
            "name" => name,
            "title" => title,
            "description" => description,
            "mimeType" => "application/json"
          }
        end

      {result(id, %{"resources" => resources}), session}
    end

    defp request("resources/templates/list", _params, id, session, _ctx),
      do: {result(id, %{"resourceTemplates" => []}), session}

    defp request("resources/read", params, id, session, ctx) do
      uri = params["uri"]

      case read_resource(uri, ctx) do
        {:ok, text} ->
          contents = [%{"uri" => uri, "mimeType" => "application/json", "text" => text}]
          {result(id, %{"contents" => contents}), session}

        :error ->
          {error(id, -32_002, "Resource not found", %{"uri" => uri}), session}
      end
    end

    defp request(method, _params, id, session, _ctx),
      do: {error(id, -32_601, "Method not found: #{method}"), session}

    defp call_tool(name, arguments, params, ctx) do
      token = get_in(params, ["_meta", "progressToken"])
      notify = Map.get(ctx, :notify)
      counter = :counters.new(1, [])

      on_frame = fn frame ->
        if notify && (is_binary(token) or is_integer(token)) do
          :counters.add(counter, 1, 1)

          notify.(%{
            "jsonrpc" => "2.0",
            "method" => "notifications/progress",
            "params" => %{
              "progressToken" => token,
              "progress" => :counters.get(counter, 1),
              "message" => Jason.encode!(frame)
            }
          })
        end

        :ok
      end

      outcome =
        try do
          Tools.call(name, arguments, %{info: ctx.info, on_frame: on_frame})
        rescue
          e -> {:error, "#{name} raised: " <> Exception.message(e)}
        catch
          kind, reason -> {:error, "#{name} #{kind}: #{inspect(reason)}"}
        end

      case outcome do
        {:ok, structured} ->
          %{
            "content" => [%{"type" => "text", "text" => Jason.encode!(structured)}],
            "structuredContent" => structured,
            "isError" => false
          }

        {:error, text} ->
          %{"content" => [%{"type" => "text", "text" => text}], "isError" => true}
      end
    end

    defp read_resource("a2a://agent-card", ctx) do
      case Tools.call("a2a_get_agent_card", %{"binding" => "jsonrpc", "mount" => "root"}, ctx) do
        {:ok, %{"body" => body}} when is_binary(body) -> {:ok, body}
        _other -> :error
      end
    end

    defp read_resource("sim://info", ctx), do: tool_resource("sim_info", %{}, ctx)
    defp read_resource("sim://surface", ctx), do: tool_resource("sim_surface", %{}, ctx)

    defp read_resource("sim://coverage", _ctx) do
      plan = Coverage.plan()
      uncovered = Enum.map(Coverage.uncovered(), & &1.id)
      {:ok, Jason.encode!(%{"count" => length(plan), "items" => plan, "uncovered" => uncovered})}
    end

    defp read_resource("sim://prover/matrix", _ctx) do
      matrix =
        Tools.last_matrix() ||
          %{"note" => "sim_prove has not run in this server yet; call the sim_prove tool."}

      {:ok, Jason.encode!(matrix)}
    end

    defp read_resource(_uri, _ctx), do: :error

    defp tool_resource(tool, arguments, ctx) do
      case Tools.call(tool, arguments, ctx) do
        {:ok, structured} -> {:ok, Jason.encode!(structured)}
        {:error, _text} -> :error
      end
    end

    defp instructions do
      """
      This server controls the ash_a2a simulation server: a real A2A v1.1 agent \
      (an ETS note store) served over JSON-RPC, HTTP+JSON and gRPC. Every wire tool \
      sends a real request and answers the status, headers and exact body. \
      Start with sim_info (URLs, tokens, skills) and sim_surface (everything served). \
      a2a_* tools take `binding` (jsonrpc, http_json, grpc); jsonrpc_*, http_* and \
      grpc_* tools take one binding's own request shape; a2a_raw_request sends bytes \
      you choose. sim_read_rows reads the Ash rows to confirm a mutation; \
      sim_grant_authority and sim_revoke_authority change the standing grants the \
      mutating skills need; sim_push_deliveries shows the webhooks received; \
      sim_coverage is a runnable plan that reaches every surface item; sim_prove \
      runs the library's own prover.
      """
    end

    defp result(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

    defp error(id, code, message, data \\ nil) do
      error = %{"code" => code, "message" => message}
      error = if data, do: Map.put(error, "data", data), else: error
      %{"jsonrpc" => "2.0", "id" => id, "error" => error}
    end
  end
end
