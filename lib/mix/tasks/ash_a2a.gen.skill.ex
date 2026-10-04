# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.AshA2a.Gen.Skill do
    @shortdoc "Generates an AshA2A skill declaration inside an Ash.Resource"

    @moduledoc """
    Generates an `AshA2A` skill declaration within an existing resource.

    ## Usage

        mix ash_a2a.gen.skill MyApp.Support.Ticket create_ticket create --consequence external_do

    Options:
      * `--consequence` - One of `observe`, `change`, `external_do` (default: `observe`)
      * `--description` - Optional human-readable description for the skill
    """

    use Igniter.Mix.Task

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        positional: [:resource, :skill_name, :action_name],
        schema: [
          consequence: :string,
          description: :string
        ],
        aliases: [
          c: :consequence,
          d: :description
        ]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      options = igniter.args.options
      positional = igniter.args.positional

      resource = Igniter.Project.Module.parse(positional[:resource])
      skill_name = String.to_atom(positional[:skill_name])
      action_name = String.to_atom(positional[:action_name])
      consequence = String.to_atom(Keyword.get(options, :consequence, "observe"))
      description = Keyword.get(options, :description, "A2A skill for #{action_name}")

      case Igniter.Project.Module.find_module(igniter, resource) do
        {:ok, {igniter, _source, _path}} ->
          patch_skill(igniter, resource, skill_name, action_name, consequence, description)

        {:error, igniter} ->
          Igniter.add_issue(igniter, "Could not find resource module #{inspect(resource)}")
      end
    end

    defp patch_skill(igniter, resource, skill_name, action_name, consequence, description) do
      # Make sure AshA2A extension is included
      igniter =
        Spark.Igniter.add_extension(
          igniter,
          resource,
          [Ash.Resource, Ash.Domain],
          :extensions,
          AshA2A
        )

      # Insert the skill DSL block
      skill_code = """
      skill #{inspect(skill_name)}, #{inspect(action_name)} do
        description #{inspect(description)}
        consequence #{inspect(consequence)}
      end
      """

      Spark.Igniter.set_option(
        igniter,
        resource,
        [:a2a, skill_name],
        Sourceror.parse_string!(skill_code)
      )
    end
  end
else
  defmodule Mix.Tasks.AshA2a.Gen.Skill do
    use Mix.Task

    @shortdoc "Generates an AshA2A skill declaration (requires Igniter)"

    def run(_args) do
      Mix.shell().error("mix ash_a2a.gen.skill requires Igniter to be installed and loaded.")
    end
  end
end
