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
      mix ash_a2a.sim --parity         # compare the wire with the upstream A2A v1.1 reference

  ## Options

    * `--prove` - run `AshA2A.Sim.Prover` against the booted server, print one
      row per probe (surface, probe, status, detail), then exit. The exit
      status is `1` when any probe fails or any served surface item has no
      probe, else `0`.
    * `--parity` - run the A2A v1.1 parity script
      (`scripts/a2a_v1_1_parity/parity.py`, see `AshA2A.Sim.Parity`) against the
      booted server and print its matrix. The exit status is `1` when a row
      fails, and `0` when every row passes or the only failing rows are the
      known defects listed in `docs/reference/a2a-v1-1-parity-findings.md`.
      Add `--strict` to exit `1` for known defects too, and `--json` to print
      the report as JSON. Needs the Python virtual environment that
      `scripts/a2a_v1_1_parity/setup.sh` creates; without it the task says so
      and exits `2`.
    * `--json` - with `--prove`, print a JSON object with `summary`,
      `uncovered` and `results` instead of the table.
    * `--http-port`, `--grpc-port`, `--push-port` - listen ports. Each
      defaults to `0`, which picks a free port.

  Without `--prove` the task prints the URL of each mount and the bearer
  tokens, then serves until the VM is stopped (Ctrl-C twice).

  The simulation server needs Bandit (its HTTP listener), an optional
  dependency of ash_a2a. In this repository the task defaults to the `test`
  Mix environment and also runs with `MIX_ENV=dev`. Its resource uses Ash
  policies, which need a SAT solver (`simple_sat`, also optional). In another
  project, add `{:bandit, "~> 1.5"}` and `{:simple_sat, "~> 0.1"}` to that
  project's dependencies.
  """

  use Mix.Task

  @requirements ["app.start"]

  @switches [
    prove: :boolean,
    parity: :boolean,
    strict: :boolean,
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

    # The simulation resource carries Ash policies, which need a SAT solver.
    unless Code.ensure_loaded?(Module.concat([SimpleSat])) or
             Code.ensure_loaded?(Module.concat([Picosat])) do
      Mix.raise(
        "the simulation server's resource uses Ash policies, which need a SAT solver. " <>
          "Add {:simple_sat, \"~> 0.1\"} or {:picosat_elixir, \"~> 0.2\"} to your " <>
          "dependencies and recompile ash_a2a (mix deps.compile ash_a2a --force)."
      )
    end

    if opts[:prove] || opts[:parity], do: Logger.configure(level: :error)

    {:ok, _pid} = server.start_link(Keyword.take(opts, [:http_port, :grpc_port, :push_port]))
    info = server.info()

    cond do
      opts[:parity] -> parity(info, opts[:json] == true, opts[:strict] == true)
      opts[:prove] -> prove(info, opts[:json] == true)
      true -> serve(info)
    end
  end

  defp parity(info, json?, strict?) do
    parity = Module.concat(AshA2A.Sim, Parity)

    case parity.run(info) do
      {:ok, report} ->
        {matrix, report} = Map.pop(report, "matrix")
        summary = report["summary"]
        Mix.shell().info(if json?, do: Jason.encode!(report, pretty: true), else: matrix)

        unless json? do
          Mix.shell().info(
            "\n#{summary["pass"]} pass, #{summary["fail"]} fail, #{summary["known"]} known " <>
              "(#{Enum.join(report["known_defects"], ", ")}), #{summary["skip"]} skip"
          )
        end

        if summary["fail"] > 0 or (strict? and summary["known"] > 0), do: exit({:shutdown, 1})

      {:skip, reason} ->
        Mix.shell().error("parity not run: " <> reason)
        exit({:shutdown, 2})

      {:error, reason} ->
        Mix.shell().error(reason)
        exit({:shutdown, 1})
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
      required ext.  #{info.required_a2a_url}, #{info.required_rest_url}, gRPC #{info.required_grpc_target}   (A2A-Extensions: #{info.required_extension})
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
    surface = Module.concat(AshA2A.Sim, Surface)
    results = prover.run(info)
    summary = prover.summary(results)
    uncovered = surface.uncovered(prover.probes())

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
        "\n#{length(results)} probes over #{length(surface.items())} surface items: " <>
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
