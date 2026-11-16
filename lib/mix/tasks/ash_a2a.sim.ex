# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshA2a.Sim do
  @shortdoc "Serve the simulation server, or prove every served surface over the wire"

  @moduledoc """
  Runs the ash_a2a simulation server (`AshA2A.Sim.Server`): every transport
  the library ships, mounted over one agent with real Ash mutations.

  ## Usage

      mix ash_a2a.sim                  # serve until stopped, print the URLs
      mix ash_a2a.sim --prove          # boot, run every probe, print the matrix
      mix ash_a2a.sim --prove --json   # the same matrix as JSON

  ## Options

    * `--prove` - run `AshA2A.Sim.Prover` against the booted server, print one
      row per probe (surface, probe, status, detail), then exit. The exit
      status is `1` when any probe fails or any served surface item has no
      probe, else `0`.
    * `--json` - with `--prove`, print a JSON object with `summary`,
      `uncovered` and `results` instead of the table.
    * `--http-port`, `--grpc-port`, `--push-port` - listen ports. Each
      defaults to `0`, which picks a free port.

  Without `--prove` the task prints the URL of each mount and the bearer
  tokens, then serves until the VM is stopped (Ctrl-C twice).

  The simulation server needs Bandit (its HTTP listener), an optional
  dependency of ash_a2a. In this repository the task defaults to the `test`
  Mix environment and also runs with `MIX_ENV=dev`. In another project, add
  `{:bandit, "~> 1.5"}` to that project's dependencies.
  """

  use Mix.Task

  @requirements ["app.start"]

  @switches [
    prove: :boolean,
    json: :boolean,
    http_port: :integer,
    grpc_port: :integer,
    push_port: :integer
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, rest, invalid} = OptionParser.parse(argv, strict: @switches)

    if invalid != [] or rest != [] do
      Mix.raise("invalid arguments: #{inspect(invalid ++ rest)}")
    end

    server = Module.concat(AshA2A.Sim, Server)

    unless Code.ensure_loaded?(server) do
      Mix.raise(
        "the simulation server needs Bandit, which is an optional dependency of ash_a2a. " <>
          "Add {:bandit, \"~> 1.5\"} to your dependencies and recompile ash_a2a " <>
          "(mix deps.compile ash_a2a --force)."
      )
    end

    if opts[:prove], do: Logger.configure(level: :error)

    {:ok, _pid} = server.start_link(Keyword.take(opts, [:http_port, :grpc_port, :push_port]))
    info = server.info()

    if opts[:prove] do
      prove(info, opts[:json] == true)
    else
      serve(info)
    end
  end

  defp serve(info) do
    Mix.shell().info("""
    ash_a2a simulation server

      agent card     #{info.card_url}
      JSON-RPC       #{info.jsonrpc_url}   (AshA2A.Transport.Plug)
      JSON-RPC       #{info.a2a_url}   (AshA2A.A2ATransport.Plug: push configs, extended card)
      HTTP+JSON      #{info.rest_url}   (AshA2A.Transport.HTTPJSON)
      gRPC           #{info.grpc_target}   (lf.a2a.v1.A2AService)
      push receiver  #{info.push_url}

    Bearer tokens

      writer    #{info.tokens.writer}   (holds the grants for the mutating skills)
      reader    #{info.tokens.reader}   (no grants)
      unscoped  #{info.tokens.unscoped}   (lacks the a2a:invoke scope)

    Serving until stopped.
    """)

    Process.sleep(:infinity)
  end

  defp prove(info, json?) do
    prover = Module.concat(AshA2A.Sim, Prover)
    results = prover.run(info)
    summary = prover.summary(results)
    uncovered = AshA2A.Sim.Surface.uncovered(prover.probes())

    if json? do
      Mix.shell().info(
        Jason.encode!(
          %{
            summary: summary,
            uncovered: Enum.map(uncovered, & &1.id),
            results: Enum.map(results, &Map.update!(&1, :status, fn s -> Atom.to_string(s) end))
          },
          pretty: true
        )
      )
    else
      Mix.shell().info(prover.format(results))

      Mix.shell().info(
        "\n#{length(results)} probes over #{length(AshA2A.Sim.Surface.items())} surface items: " <>
          "#{summary.pass} pass, #{summary.fail} fail, #{summary.skip} skip"
      )

      for item <- uncovered do
        Mix.shell().error("no probe for #{item.id} (#{item.source})")
      end
    end

    if summary.fail > 0 or uncovered != [] do
      exit({:shutdown, 1})
    end
  end
end
