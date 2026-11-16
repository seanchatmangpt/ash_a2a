# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshA2a.Doctor do
  @shortdoc "Diagnoses the A2A wiring of this application"

  @moduledoc """
  Prints findings about how this application is wired for A2A and exits
  non-zero when any is an error.

      mix ash_a2a.doctor
      mix ash_a2a.doctor --strict
      mix ash_a2a.doctor --json
      mix ash_a2a.doctor --domain MyApp.Agents

  Domains come from `config :my_app, ash_domains: [...]` unless `--domain`
  (repeatable) is given. See `AshA2A.Doctor` for the checks and
  `docs/how-to/run-doctor.md`.

  ## Options

    * `--strict` -- warnings also produce a non-zero exit
    * `--json` -- print the findings as a JSON array
    * `--domain` -- a domain module to inspect (repeatable)
  """
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args, strict: [strict: :boolean, json: :boolean, domain: :keep])

    Mix.Task.run("app.config")

    domains =
      case Keyword.get_values(opts, :domain) do
        [] -> configured_domains()
        names -> Enum.map(names, &Module.concat([&1]))
      end

    findings = AshA2A.Doctor.diagnose(domains: domains)

    if opts[:json] do
      findings
      |> Enum.map(fn f -> %{f | severity: Atom.to_string(f.severity), code: Atom.to_string(f.code)} end)
      |> Jason.encode!(pretty: true)
      |> Mix.shell().info()
    else
      Enum.each(findings, fn f ->
        Mix.shell().info("[#{f.severity}] #{f.code}: #{f.message}\n        fix: #{f.fix}")
      end)
    end

    if AshA2A.Doctor.failing?(findings, opts[:strict] == true) do
      Mix.raise("ash_a2a.doctor found problems")
    end
  end

  defp configured_domains do
    app = Mix.Project.config()[:app]
    Application.get_env(app, :ash_domains, [])
  end
end
