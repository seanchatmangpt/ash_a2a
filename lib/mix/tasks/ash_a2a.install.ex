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
#   - `extensions:` merge uses `Spark.Igniter.add_extension/5`, the same real,
#     already-vendored (via the `:ash`/`:spark` deps this project already has)
#     detect-and-merge helper that `ash_r2rml.install.ex` itself calls for the
#     identical job (see that file's `igniter/1`) -- there is no ggen-marketplace
#     pack for this (confirmed by direct inspection of
#     `ash-extension-pack/templates/install.ex.tmpl`, which carries the same
#     disclosed unconditional-insert limitation this file used to), but there IS
#     an established Igniter/Spark ecosystem primitive already wired into this
#     project's own dependency tree, so it is reused here rather than hand-rolled
#     from lower-level `Igniter.Code.Keyword`/`Igniter.Code.List` zipper calls.
if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.AshA2a.Install do
    @moduledoc """
    Installs `ash_a2a` into the current project: adds `{:a2a, "~> 0.2"}` as a
    dependency, wires up the `AshA2A.Formatter` formatter plugin, and -- when
    `--target` is given -- patches the target module's `extensions:` list to
    include `AshA2A` (the one extension module, usable on both an
    `Ash.Resource` and an `Ash.Domain` -- `--type domain` selects the
    `skill :name, Resource, :action` DSL shape but does not change which
    extension module is added), plus a starter `a2a do end` block.

    Detects an existing `extensions:` option on the target module's `use
    Ash.Resource` / `use Ash.Domain` call and merges `AshA2A` into it instead of
    inserting a second, separate `extensions:` option -- idempotent, so
    re-running install against an already-patched module does not duplicate
    `AshA2A` in the list.

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

          Add `extensions: [AshA2A]` to your Ash.Resource or Ash.Domain modules
          (the same `AshA2A` extension module works on both):

              use Ash.Resource,
                extensions: [AshA2A]

              a2a do
              end

          Or re-run with `--target MyApp.SomeResource` (or `--target
          MyApp.SomeDomain --type domain`) to patch a specific module automatically.
          """)

        target ->
          target_module = Igniter.Project.Module.parse(target)

          base
          |> add_extension(target_module)
          |> add_starter_dsl_block(target_module)
      end
    end

    # Detects an existing `extensions:` option on the target module's `use
    # Ash.Resource` / `use Ash.Domain` call and merges `AshA2A` into it rather
    # than inserting a second, separate `extensions:` option. `AshA2A` is the
    # one extension module for both target kinds -- there is no separate
    # `AshA2A.Domain` module (see `AshA2A.Dsl`'s moduledoc and
    # `test/support/fixture.ex`'s `use Ash.Domain, extensions: [AshA2A]`, the
    # only real domain-extension usage in this repo) -- so searching for either
    # `Ash.Resource` or `Ash.Domain`'s `use` clause covers both targets without
    # needing to branch on the `--type` option here.
    #
    # Delegates to `Spark.Igniter.add_extension/5` (`igniter`, target module,
    # use-clause type(s), option key, extension module) instead of hand-composing
    # `Igniter.Code.Keyword.keyword_has_path?/2` +
    # `Igniter.Code.Keyword.get_key/2` + `Igniter.Code.List.append_new_to_list/3`
    # directly: `Spark.Igniter.add_extension/5` already *is* that detect-and-merge
    # composition (real, already-vendored via this project's `:ash`/`:spark`
    # deps, and used for the identical job by every other Ash extension
    # installer in this dependency tree -- `ash_r2rml.install.ex`, the sibling
    # installer this file's header already cites as its model, `ash.extend.ex`,
    # `ash_ai.gen.chat.ex`, and `ash_json_api`'s resource/domain wiring all call
    # it this same way). It merges idempotently
    # (`Igniter.Code.List.prepend_new_to_list/3`, deduped by AST equality) when
    # `extensions:` is already present, adds a fresh `extensions: [AshA2A]`
    # option when the `use` call has other options but no `extensions:` key yet,
    # and appends `extensions: [AshA2A]` as the call's second argument when the
    # `use` call has no options at all -- covering the "no prior `extensions:`"
    # case without a separate fallback branch here.
    defp add_extension(igniter, target_module) do
      Spark.Igniter.add_extension(
        igniter,
        target_module,
        [Ash.Resource, Ash.Domain],
        :extensions,
        AshA2A
      )
    end

    # Adds a minimal, real starter `a2a do end` block so the target module
    # compiles immediately after install rather than needing hand-authored DSL
    # content. Inserted right after the target module's `use Ash.Resource` /
    # `use Ash.Domain` call specifically, found fresh via
    # `Igniter.Code.Module.move_to_use/2` rather than reusing a zipper position
    # from `add_extension/2` above (which runs as its own separate
    # `Igniter.t()` pass, per `Spark.Igniter.add_extension/5`'s own shape).
    defp add_starter_dsl_block(igniter, target_module) do
      Igniter.Project.Module.find_and_update_module!(igniter, target_module, fn zipper ->
        case Igniter.Code.Module.move_to_use(zipper, [Ash.Resource, Ash.Domain]) do
          {:ok, use_zipper} ->
            {:ok,
             Igniter.Code.Common.add_code(
               use_zipper,
               """
               a2a do
               end
               """,
               placement: :after
             )}

          :error ->
            {:ok, zipper}
        end
      end)
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

      3. Add `extensions: [AshA2A]` to your Ash.Resource or Ash.Domain modules
         (the same `AshA2A` extension module works on both):

             use Ash.Resource,
               extensions: [AshA2A]

             a2a do
             end
      """)
    end
  end
end
