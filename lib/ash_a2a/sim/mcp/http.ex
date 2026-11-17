# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

if Code.ensure_loaded?(Bandit) do
  defmodule AshA2A.Sim.MCP.HTTP do
    @moduledoc """
    The MCP Streamable HTTP transport of `AshA2A.Sim.MCP.Server`, served at
    `/mcp` on a loopback listener.

        {:ok, pid} = AshA2A.Sim.MCP.HTTP.start_link(info: AshA2A.Sim.Server.info(), port: 0)
        AshA2A.Sim.MCP.HTTP.port(pid)

    | Request | Answer |
    |---|---|
    | `POST /mcp` with `initialize` | `200` JSON and a fresh `Mcp-Session-Id` header |
    | `POST /mcp` with a request | `200` JSON; for `tools/call` from a client that accepts `text/event-stream`, a server-sent event stream: one `message` event per `notifications/progress`, then the response |
    | `POST /mcp` with a notification or a response | `202`, no body |
    | `DELETE /mcp` | ends the session named by `Mcp-Session-Id` |
    | `GET /mcp` | `405`: the server opens no stream of its own |

    Every request after `initialize` must carry the `Mcp-Session-Id` it was
    given: `400` without one, `404` for a session that does not exist. A
    request whose `MCP-Protocol-Version` header names a revision the server
    does not support is refused `400`. A request whose `Origin` or `Host`
    is not a loopback name is refused `403` (DNS-rebinding defence, per the
    MCP Streamable HTTP transport). When an auth token is configured (the
    `:auth_token` option, default the `ASH_A2A_MCP_TOKEN` environment
    variable) every request must carry `Authorization: Bearer <token>`,
    else `401`. A body over 16 MB is refused `413`; at most 256 sessions
    are kept (`429` beyond).
    """

    @behaviour Plug

    import Plug.Conn

    alias AshA2A.Sim.MCP.Server

    @sessions __MODULE__.Sessions
    @max_sessions 256
    @max_body 16_000_000

    @doc """
    Starts the listener. Options: `:info` (required, `AshA2A.Sim.Server.info/0`)
    and `:port` (default `0`, a free port).
    """
    @spec start_link(keyword()) :: Supervisor.on_start()
    def start_link(opts) do
      info = Keyword.fetch!(opts, :info)

      children = [
        %{id: @sessions, start: {Agent, :start_link, [fn -> %{} end, [name: @sessions]]}},
        Supervisor.child_spec(
          {Bandit,
           plug: {__MODULE__, %{info: info, token: token(opts)}},
           port: Keyword.get(opts, :port, 0),
           ip: {127, 0, 0, 1},
           startup_log: false,
           thousand_island_options: [read_timeout: 120_000]},
          id: :mcp_http
        )
      ]

      Supervisor.start_link(children, strategy: :one_for_one)
    end

    defp token(opts) do
      case Keyword.get(opts, :auth_token, System.get_env("ASH_A2A_MCP_TOKEN")) do
        t when is_binary(t) and t != "" -> t
        _ -> nil
      end
    end

    @doc "The port the listener bound."
    @spec port(Supervisor.supervisor()) :: :inet.port_number()
    def port(supervisor) do
      {_, pid, _, _} =
        supervisor |> Supervisor.which_children() |> List.keyfind(:mcp_http, 0)

      {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
      port
    end

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(%{path_info: ["mcp"]} = conn, opts) do
      cond do
        not loopback_origin?(conn) ->
          text(conn, 403, "Origin not allowed")

        not loopback_host?(conn) ->
          text(conn, 403, "Host not allowed")

        not authorized?(conn, opts) ->
          conn |> put_resp_header("www-authenticate", "Bearer") |> text(401, "Unauthorized")

        conn.method == "POST" ->
          post(conn, opts)

        conn.method == "DELETE" ->
          delete(conn)

        true ->
          conn |> put_resp_header("allow", "POST, DELETE") |> text(405, "Method Not Allowed")
      end
    end

    def call(conn, _opts), do: text(conn, 404, "Not Found")

    defp loopback_origin?(conn) do
      case get_req_header(conn, "origin") do
        [] -> true
        [origin | _] -> URI.parse(origin).host in ["localhost", "127.0.0.1", "::1"]
      end
    end

    defp loopback_host?(conn) do
      case get_req_header(conn, "host") do
        [host | _] -> host_name(host) in ["localhost", "127.0.0.1", "[::1]", "::1"]
        [] -> false
      end
    end

    defp host_name("[" <> _ = host), do: host |> String.split("]") |> hd() |> Kernel.<>("]")
    defp host_name(host), do: host |> String.split(":") |> hd() |> String.downcase()

    defp authorized?(_conn, %{token: nil}), do: true

    defp authorized?(conn, %{token: token}) do
      case get_req_header(conn, "authorization") do
        ["Bearer " <> given | _] -> Plug.Crypto.secure_compare(given, token)
        _ -> false
      end
    end

    defp post(conn, opts) do
      case read_body(conn, length: @max_body) do
        {:ok, body, conn} ->
          case Jason.decode(body) do
            {:ok, message} -> route(conn, message, opts)
            {:error, _} -> json(conn, 400, Server.parse_error())
          end

        _too_large_or_closed ->
          text(conn, 413, "request body too large")
      end
    end

    defp route(conn, %{"method" => "initialize"} = message, opts) do
      {reply, session} = Server.handle(message, Server.new_session(), ctx(opts, nil))

      if session.initialized and map_size(Agent.get(@sessions, & &1)) >= @max_sessions do
        text(conn, 429, "too many sessions")
      else
        route_initialized(conn, reply, session)
      end
    end

    defp route_initialized(conn, reply, session) do
      if session.initialized do
        id = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
        Agent.update(@sessions, &Map.put(&1, id, session))
        conn |> put_resp_header("mcp-session-id", id) |> json(200, reply)
      else
        json(conn, 200, reply)
      end
    end

    defp route(conn, message, opts) do
      with {:ok, id} <- session_id(conn),
           {:ok, session} <- lookup_session(id),
           :ok <- check_version(conn) do
        answer(conn, message, id, session, opts)
      else
        {:refuse, status, reason} -> text(conn, status, reason)
      end
    end

    defp session_id(conn) do
      case get_req_header(conn, "mcp-session-id") do
        [id | _] -> {:ok, id}
        [] -> {:refuse, 400, "Mcp-Session-Id header required; send initialize first"}
      end
    end

    defp lookup_session(id) do
      case Agent.get(@sessions, &Map.get(&1, id)) do
        nil -> {:refuse, 404, "no such session"}
        session -> {:ok, session}
      end
    end

    defp check_version(conn) do
      case get_req_header(conn, "mcp-protocol-version") do
        [] ->
          :ok

        [version | _] ->
          if version in Server.supported_versions(),
            do: :ok,
            else: {:refuse, 400, "unsupported MCP-Protocol-Version #{version}"}
      end
    end

    defp answer(conn, message, id, session, opts) do
      streaming? =
        is_map(message) and message["method"] == "tools/call" and Map.has_key?(message, "id") and
          accepts?(conn, "text/event-stream")

      if streaming? do
        stream(conn, message, session, opts)
      else
        {reply, session} = Server.handle(message, session, ctx(opts, nil))
        Agent.update(@sessions, &Map.put(&1, id, session))

        case reply do
          nil -> send_resp(conn, 202, "")
          reply -> json(conn, 200, reply)
        end
      end
    end

    # The tool runs in a task; this process owns the connection and writes one
    # server-sent event per notification, then the response.
    defp stream(conn, message, session, opts) do
      owner = self()
      ref = make_ref()

      task =
        Task.async(fn ->
          notify = fn notification -> send(owner, {ref, notification}) end
          {reply, _session} = Server.handle(message, session, ctx(opts, notify))
          reply
        end)

      conn =
        conn
        |> put_resp_header("content-type", "text/event-stream")
        |> put_resp_header("cache-control", "no-cache")
        |> send_chunked(200)

      forward(conn, ref, task)
    end

    defp forward(conn, ref, %Task{ref: task_ref} = task) do
      receive do
        {^ref, notification} ->
          case chunk(conn, event(notification)) do
            {:ok, conn} ->
              forward(conn, ref, task)

            {:error, _closed} ->
              Task.shutdown(task, :brutal_kill)
              conn
          end

        {^task_ref, reply} ->
          Process.demonitor(task_ref, [:flush])
          conn = drain(conn, ref)
          {:ok, conn} = chunk(conn, event(reply))
          conn

        {:DOWN, ^task_ref, :process, _pid, reason} ->
          reply = %{
            "jsonrpc" => "2.0",
            "id" => nil,
            "error" => %{"code" => -32_603, "message" => "tool call crashed: #{inspect(reason)}"}
          }

          {:ok, conn} = chunk(conn, event(reply))
          conn
      end
    end

    defp drain(conn, ref) do
      receive do
        {^ref, notification} ->
          case chunk(conn, event(notification)) do
            {:ok, conn} -> drain(conn, ref)
            {:error, _closed} -> conn
          end
      after
        0 -> conn
      end
    end

    defp event(message), do: ["event: message\ndata: ", Jason.encode!(message), "\n\n"]

    defp delete(conn) do
      with {:ok, id} <- session_id(conn),
           {:ok, _session} <- lookup_session(id) do
        Agent.update(@sessions, &Map.delete(&1, id))
        send_resp(conn, 200, "")
      else
        {:refuse, status, reason} -> text(conn, status, reason)
      end
    end

    defp accepts?(conn, type) do
      conn |> get_req_header("accept") |> Enum.any?(&String.contains?(&1, type))
    end

    defp ctx(%{info: info}, nil), do: %{info: info}
    defp ctx(%{info: info}, notify), do: %{info: info, notify: notify}

    defp json(conn, status, body) do
      conn
      |> put_resp_header("content-type", "application/json")
      |> send_resp(status, Jason.encode!(body))
    end

    defp text(conn, status, body) do
      conn
      |> put_resp_header("content-type", "text/plain; charset=utf-8")
      |> send_resp(status, body)
    end
  end
end
