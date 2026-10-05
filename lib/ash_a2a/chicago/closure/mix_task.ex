# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshA2a.Chicago.Closure do
  @shortdoc "Graph-derived architecture closure court (RFC-SA2A-006 s27)"

  @moduledoc """
  Derives the remote-call graph of the compiled `:ash_a2a` modules from BEAM
  abstract code and reports every edge into an effector that does not
  originate from the allowed caller set (ConsequenceKernel).

      mix ash_a2a.chicago.closure                 # report mode, always exit 0
      mix ash_a2a.chicago.closure --enforce       # exit non-zero on violations
      mix ash_a2a.chicago.closure --json path     # write the JSON report

  Options: `--enforce`, `--json PATH`, `--unresolved report|refuse`.
  """

  use Mix.Task

  alias AshA2A.Chicago.Closure

  @switches [enforce: :boolean, json: :string, unresolved: :string]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, invalid} = OptionParser.parse(argv, strict: @switches)
    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    Mix.Task.run("compile")

    unresolved =
      case opts[:unresolved] do
        nil -> :refuse
        "refuse" -> :refuse
        "report" -> :report
        other -> Mix.raise("--unresolved must be report|refuse, got #{other}")
      end

    mode = if opts[:enforce], do: :enforce, else: :report

    {status, report} =
      Closure.run(Closure.app_modules(), mode: mode, unresolved: unresolved)

    if path = opts[:json] do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, Closure.to_json(report))
      Mix.shell().info("closure report written to #{path}")
    end

    s = report.summary

    Mix.shell().info(
      "closure[#{report.mode}] verdict=#{report.verdict} modules=#{report.modules_analyzed} " <>
        "violating_edges=#{s.violating_edges} unresolved_edges=#{s.unresolved_edges}"
    )

    if status == :refused do
      Mix.raise(
        "closure court REFUSED: #{s.violating_edges} violating, #{s.unresolved_edges} unresolved edges"
      )
    end
  end
end
