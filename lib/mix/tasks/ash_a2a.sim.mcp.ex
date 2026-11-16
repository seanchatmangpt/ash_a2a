# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshA2a.Sim.Mcp do
  @shortdoc "Serve the simulation server to an MCP client over stdio or Streamable HTTP"

  @moduledoc """
  Boots the ash_a2a simulation server (`AshA2A.Sim.Server`) in this VM and
  serves it to a Model Context Protocol client, so the client drives every
  A2A operation through MCP tools (`AshA2A.Sim.MCP.Server`, MCP revision
  2025-11-25).

  ## Usage

      bin/a2a-sim-mcp                       # stdio, safe for any MCP client
      mix ash_a2a.sim.mcp                   # stdio
      mix ash_a2a.sim.mcp --http 4000       # Streamable HTTP at http://127.0.0.1:4000/mcp

  ## Options

    * `--http PORT` - serve Streamable HTTP on `127.0.0.1:PORT` (`0` picks a
      free port) instead of stdio, until the VM is stopped. The URL is
      printed on standard error.
    * `--out-fd N` - stdio only: write the MCP messages to file descriptor
      `N` instead of standard output.
    * `--sim-http-port`, `--sim-grpc-port`, `--sim-push-port` - the listen
      ports of the simulation server. Each defaults to `0`, a free port.

  ## Standard output in stdio mode

  An MCP client reads standard output as protocol, so nothing but MCP
  messages may be written there. The task sends the logger to standard error
  before it starts the application. Mix itself still prints to standard
  output when it has to compile, so compile first (`MIX_ENV=test mix
  compile`), or run `bin/a2a-sim-mcp`: it points standard output at standard
  error for the whole VM and gives the task the real standard output as
  descriptor 3 (`--out-fd 3`).

  The simulation server needs Bandit (its HTTP listener), an optional
  dependency of ash_a2a. In this repository it is available in the `test` and
  `dev` Mix environments.
  """

  use Mix.Task

  @switches [
    http: :integer,
    out_fd: :integer,
    sim_http_port: :integer,
    sim_grpc_port: :integer,
    sim_push_port: :integer
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, rest, invalid} = OptionParser.parse(argv, strict: @switches)

    if invalid != [] or rest != [] do
      Mix.raise("invalid arguments: #{inspect(invalid ++ rest)}")
    end

    logger_to_stderr()
    Mix.Task.run("app.start")
    Logger.configure(level: :warning)

    runner = Module.concat(AshA2A.Sim.MCP, Runner)

    unless Code.ensure_loaded?(runner) do
      Mix.raise(
        "the simulation server needs Bandit, which is an optional dependency of ash_a2a. " <>
          "Add {:bandit, \"~> 1.5\"} to your dependencies and recompile ash_a2a " <>
          "(mix deps.compile ash_a2a --force)."
      )
    end

    runner.main(opts)
  end

  # The default handler writes to standard output; an MCP client reads that
  # stream as protocol.
  defp logger_to_stderr do
    with {:ok, %{module: module} = handler} <- :logger.get_handler_config(:default),
         :ok <- :logger.remove_handler(:default) do
      config = handler |> Map.get(:config, %{}) |> Map.put(:type, :standard_error)

      :logger.add_handler(
        :default,
        module,
        handler |> Map.drop([:id, :module]) |> Map.put(:config, config)
      )
    end

    :ok
  end
end
