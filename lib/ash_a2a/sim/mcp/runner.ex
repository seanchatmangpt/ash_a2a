# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

if Code.ensure_loaded?(Bandit) do
  defmodule AshA2A.Sim.MCP.Runner do
    @moduledoc false
    # The body of `mix ash_a2a.sim.mcp`: boot the simulation server, then serve
    # MCP on stdio (until end of input) or on Streamable HTTP (until stopped).

    alias AshA2A.Sim.MCP.{HTTP, Stdio}
    alias AshA2A.Sim.Server

    @spec main(keyword()) :: :ok
    def main(opts) do
      {:ok, _pid} =
        Server.start_link(
          http_port: Keyword.get(opts, :sim_http_port, 0),
          grpc_port: Keyword.get(opts, :sim_grpc_port, 0),
          push_port: Keyword.get(opts, :sim_push_port, 0)
        )

      info = Server.info()

      case opts[:http] do
        nil ->
          IO.puts(:stderr, "ash_a2a sim MCP server: stdio, A2A at #{info.base_url}")
          Stdio.run(info, out_fd: opts[:out_fd])

        port ->
          {:ok, pid} = HTTP.start_link(info: info, port: port)

          IO.puts(
            :stderr,
            "ash_a2a sim MCP server: http://127.0.0.1:#{HTTP.port(pid)}/mcp, A2A at #{info.base_url}"
          )

          Process.sleep(:infinity)
      end
    end
  end
end
