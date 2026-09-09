# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

# Igniter installer for AshA2A, following the ash-extension-core-pack
# `install.ex.tmpl` pattern (~/ggen-marketplace/packs/ash-extension-core-pack/
# templates/install.ex.tmpl) -- whole file gated by `Code.ensure_loaded?(Igniter)`
# per v26.9.10, mirroring ash_r2rml/lib/mix/tasks/ash_r2rml.install.ex's real
# dual-branch shape (an Igniter.Mix.Task branch plus a plain Mix.Task fallback that
# prints manual instructions when Igniter isn't a project dependency).
#
# Deviation from the bare template (per the PRD/ARD, §3.6/FR6):
#   - Adds `{:a2a, "~> 0.2"}` as a project dependency via
#     `Igniter.Project.Deps.add_dep/2` -- ash_a2a wraps the real `:a2a` runtime
#     (~/xaas/deps/a2a), so installing ash_a2a must also wire in its own real
#     dependency, not just the formatter plugin. Neither the bare template nor
#     ash_r2rml's own installer does this (ash_r2rml has no runtime dep to add).
#   - Supports both `Ash.Resource` and `Ash.Domain` targets (FR1: `skill :name,
#     :action` on a Resource vs. `skill :name, Resource, :action` on a Domain) via
#     a `--type` option (`resource` | `domain`, default `resource`), since AshA2A
#     is usable as an extension on either -- the bare template assumes one fixed
#     `extension_target`.
if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.AshA2a.Install do
    @moduledoc """
    Installs `ash_a2a` into the current project: adds `{:a2a, "~> 0.2"}` as a
    dependency, wires up the `AshA2A.Formatter` formatter plugin, and -- when
    `--target` is given -- patches the target module's `extensions:` list to
    include `AshA2A` (for an `Ash.Resource`) or `AshA2A.Domain` (for an
    `Ash.Domain`, via `--type domain`), plus a starter `a2a do end` block.

    ## Usage

        mix igniter.install ash_a2a
        mix ash_a2a.install --target MyApp.SomeResource
        mix ash_a2a.install --target MyApp.SomeDomain --type domain
    """
    use Igniter.Mix.Task

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :ash_a2a,
        example: "mix ash_a2a.install --target MyApp.SomeResource",
        positional: [],
        schema: [target: :string, type: :string],
        defaults: [type: "resource"],
        required: []
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      base =
        igniter
        |> Igniter.Project.Deps.add_dep({:a2a, "~> 0.2"})
        |> Igniter.Project.Formatter.import_dep(:ash_a2a)
        |> Igniter.Project.Formatter.add_formatter_plugin(AshA2A.Formatter)

      case igniter.args.options[:target] do
        nil ->
          # No --target given (e.g. plain `mix igniter.install ash_a2a`) -- the
          # dependency and formatter are still wired up automatically; the
          # resource/domain patch needs a target module, so fall back to a real,
          # disclosed manual-instructions notice rather than guessing which
          # module to patch (same disclosed-fallback shape as the bare template
          # and ash_r2rml.install.ex -- never claimed as "one command" for every
          # invocation).
          Igniter.add_notice(base, """
          AshA2A installed successfully!

          Add `extensions: [AshA2A]` to your Ash.Resource modules (or
          `extensions: [AshA2A.Domain]` to your Ash.Domain modules):

              use Ash.Resource,
                extensions: [AshA2A]

              a2a do
              end

          Or re-run with `--target MyApp.SomeResource` (or `--target
          MyApp.SomeDomain --type domain`) to patch a specific module automatically.
          """)

        target ->
          target_module = Igniter.Project.Module.parse(target)
          extension_module = extension_module_for(igniter.args.options[:type])

          Igniter.Project.Module.find_and_update_module!(base, target_module, fn zipper ->
            {:ok,
             zipper
             |> add_extension(extension_module)
             |> add_starter_dsl_block()}
          end)
      end
    end

    defp extension_module_for("domain"), do: "AshA2A.Domain"
    defp extension_module_for(_resource), do: "AshA2A"

    # Inserts `extensions: [<extension_module>]` after the target module's `use
    # Ash.Resource` / `use Ash.Domain` call. This is a single unconditional
    # insert, not a detect-or-append merge -- it does not check whether an
    # `extensions:` option already exists on that `use` call, so running install
    # against a module that already has one will add a second `extensions:`
    # option rather than merging into the first (same disclosed limitation the
    # bare ash-extension-core-pack template carries; a real detect-and-merge is a
    # follow-up, not implemented here).
    defp add_extension(zipper, extension_module) do
      Igniter.Code.Common.add_code(zipper, "extensions: [#{extension_module}]", placement: :after)
    end

    # Adds a minimal, real starter `a2a do end` block so the target module
    # compiles immediately after install rather than needing hand-authored DSL
    # content.
    defp add_starter_dsl_block(zipper) do
      Igniter.Code.Common.add_code(
        zipper,
        """
        a2a do
        end
        """,
        placement: :after
      )
    end
  end
else
  defmodule Mix.Tasks.AshA2a.Install do
    @moduledoc "Installs `ash_a2a` -- Igniter is not a dependency of this project, so this task prints manual instructions instead of patching files."
    use Mix.Task

    @impl Mix.Task
    def run(_argv) do
      Mix.shell().info("""
      AshA2A: Igniter is not installed, so `ash_a2a.install` cannot patch files
      automatically. Install manually:

      1. Add `:a2a` and `:ash_a2a` to your `mix.exs` dependencies:

             {:a2a, "~> 0.2"},
             {:ash_a2a, "~> 0.1"}

      2. Add `import_deps: [:ash_a2a]` and `plugins: [AshA2A.Formatter]` to your
         `.formatter.exs`.

      3. Add `extensions: [AshA2A]` to your Ash.Resource modules (or
         `extensions: [AshA2A.Domain]` to your Ash.Domain modules):

             use Ash.Resource,
               extensions: [AshA2A]

             a2a do
             end
      """)
    end
  end
end
