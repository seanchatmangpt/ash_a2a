# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

if Code.ensure_loaded?(Bandit) do
  defmodule AshA2A.Sim.MCP.Stdio do
    @moduledoc """
    The MCP stdio transport of `AshA2A.Sim.MCP.Server`: one JSON-RPC message
    per line on standard input, one per line on the output.

    `run/2` reads until end of input, then waits for the tool calls still in
    flight and returns. `tools/call` and `resources/read` run concurrently, so
    a `ping` is answered while a long tool call runs, and a
    `notifications/cancelled` stops the call it names.

    ## Options

      * `:out_fd` - write the MCP messages to this file descriptor instead of
        standard output. `bin/a2a-sim-mcp` passes `3` after pointing
        descriptor 3 at the real standard output and descriptor 1 at standard
        error, so nothing else the VM prints can reach the MCP client.
    """

    alias AshA2A.Sim.MCP.Server

    @doc "Serves MCP on standard input and output until end of input."
    @spec run(map(), keyword()) :: :ok
    def run(info, opts \\ []) do
      writer = spawn_link(fn -> writer(open(opts[:out_fd])) end)
      write = fn message -> send(writer, {:write, Jason.encode!(message)}) end
      ctx = %{info: info, notify: write}
      inflight = loop(Server.new_session(), ctx, write, %{})

      for {_id, pid} <- inflight do
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, _pid, _reason} -> :ok
        after
          60_000 -> :ok
        end
      end

      send(writer, {:stop, self()})

      receive do
        :stopped -> :ok
      after
        5_000 -> :ok
      end
    end

    defp open(nil), do: :stdio
    defp open(fd) when is_integer(fd), do: Port.open({:fd, fd, fd}, [:out, :binary])

    defp writer(out) do
      receive do
        {:write, line} ->
          put(out, [line, ?\n])
          writer(out)

        {:stop, from} ->
          send(from, :stopped)
      end
    end

    defp put(:stdio, data), do: IO.binwrite(:stdio, data)
    defp put(port, data) when is_port(port), do: Port.command(port, data)

    defp loop(session, ctx, write, inflight) do
      case IO.binread(:stdio, :line) do
        line when is_binary(line) ->
          case String.trim(line) do
            "" ->
              loop(session, ctx, write, inflight)

            text ->
              {session, inflight} = dispatch(Jason.decode(text), session, ctx, write, inflight)
              loop(session, ctx, write, inflight)
          end

        _eof_or_error ->
          inflight
      end
    end

    defp dispatch({:error, _}, session, _ctx, write, inflight) do
      write.(Server.parse_error())
      {session, inflight}
    end

    defp dispatch(
           {:ok, %{"method" => "notifications/cancelled"} = message},
           session,
           _ctx,
           _write,
           inflight
         ) do
      id = get_in(message, ["params", "requestId"])

      case Map.pop(inflight, id) do
        {nil, inflight} ->
          {session, inflight}

        {pid, inflight} ->
          Process.exit(pid, :kill)
          {session, inflight}
      end
    end

    defp dispatch(
           {:ok, %{"method" => method, "id" => id} = message},
           session,
           ctx,
           write,
           inflight
         )
         when method in ["tools/call", "resources/read"] do
      {:ok, pid} =
        Task.start(fn ->
          {reply, _session} = Server.handle(message, session, ctx)
          if reply, do: write.(reply)
        end)

      alive = Map.filter(inflight, fn {_id, running} -> Process.alive?(running) end)
      {session, Map.put(alive, id, pid)}
    end

    defp dispatch({:ok, message}, session, ctx, write, inflight) do
      {reply, session} = Server.handle(message, session, ctx)
      if reply, do: write.(reply)
      {session, inflight}
    end
  end
end
