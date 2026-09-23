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

    ## Explicit skill consequences (`--skill`)

        mix ash_a2a.install --target MyApp.SomeResource \\
          --skill advance_item:advance:external_do

    `--skill name:action[:consequence]` (repeatable) emits an explicit
    `skill :name, :action, consequence: :consequence` declaration inside the
    generated `a2a do` block instead of leaving the block empty. The
    consequence is one of `:observe`, `:change`, `:external_do`, `:unknown`
    (the same set `AshA2A.Dsl`'s `skill` entity accepts). Without it, a
    generic `:action` skill silently sits on the fail-closed `:unknown`
    default -- an explicit `:external_do` consequence is how a consumer
    (e.g. ggen_igniter's semantic-jira-pack, whose ontology records the
    absence of this capability as an UNSUPPORTED row) states, in the
    manufactured source itself, that a skill performs an external
    side-effecting actuation subject to the fail-closed `:broker` authority
    policy.

    The `a2a do` block is written idempotently: a block that already exists
    on the target is never duplicated. Requested skills whose `name` is
    already declared inside the existing block are left alone; missing ones
    are appended into the existing block (an empty `a2a do end` block is
    replaced in place), so re-running install against an already-patched
    module yields exactly one `a2a do` block.
    """
    use Igniter.Mix.Task

    @consequences [:observe, :change, :external_do, :unknown]

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :ash_a2a,
        example:
          "mix ash_a2a.install --target MyApp.SomeResource --skill advance_item:advance:external_do",
        positional: [],
        schema: [target: :string, type: :string, skill: :keep],
        defaults: [type: "resource", skill: []],
        required: []
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      skills = parse_skills!(igniter.args.options[:skill] || [])

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
          base
          |> maybe_warn_skill_needs_target(skills)
          |> Igniter.add_notice("""
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
          |> add_dsl_block(target_module, skills)
      end
    end

    # `--skill` declarations patch a specific target module's `a2a do` block;
    # with no --target there is nothing to attach them to, so say so instead
    # of silently dropping them (a dropped explicit consequence would leave
    # the skill on the fail-closed :unknown default -- exactly the defect
    # this option exists to prevent).
    defp maybe_warn_skill_needs_target(igniter, []), do: igniter

    defp maybe_warn_skill_needs_target(igniter, _skills) do
      Igniter.add_warning(
        igniter,
        "--skill was given without --target: no module was patched, so the " <>
          "skill declarations were NOT written anywhere. Re-run with " <>
          "--target MyApp.SomeResource to emit them."
      )
    end

    # Parses repeatable `--skill name:action[:consequence]` values into
    # `{name, action, consequence | nil}` tuples, refusing anything else with
    # a named, typed error (an unparseable skill spec must not become a
    # silently-dropped declaration).
    defp parse_skills!(specs) do
      Enum.map(specs, fn spec ->
        case String.split(spec, ":") do
          [name, action] ->
            {String.to_atom(name), String.to_atom(action), nil}

          [name, action, consequence] ->
            consequence = String.to_atom(consequence)

            unless consequence in @consequences do
              Mix.raise("""
              Invalid --skill consequence #{inspect(consequence)} in #{inspect(spec)}.
              Must be one of: #{inspect(@consequences)}.
              """)
            end

            {String.to_atom(name), String.to_atom(action), consequence}

          _ ->
            Mix.raise("""
            Invalid --skill #{inspect(spec)}: expected name:action or
            name:action:consequence (e.g. advance_item:advance:external_do).
            """)
        end
      end)
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

    # Writes the target module's `a2a do` block idempotently (ASH_A2A-26922-08):
    #
    #   - no block yet: insert one right after the `use Ash.Resource` /
    #     `use Ash.Domain` call (found fresh via `Igniter.Code.Module.move_to_use/
    #     2`), carrying the `--skill` declarations when given, empty otherwise;
    #   - a block already present: never insert a second one. Requested skills
    #     whose name is already declared inside it are left as-is; missing ones
    #     are appended into the block body. The prior implementation inserted
    #     unconditionally, so a second install run produced a second `a2a do`
    #     block -- a compile-legal but wrong, duplicated projection.
    defp add_dsl_block(igniter, target_module, skills) do
      Igniter.Project.Module.find_and_update_module!(igniter, target_module, fn zipper ->
        case Igniter.Code.Function.move_to_function_call(zipper, :a2a, 1) do
          {:ok, a2a_zipper} ->
            merge_skills_into_block(a2a_zipper, skills)

          :error ->
            case Igniter.Code.Module.move_to_use(zipper, [Ash.Resource, Ash.Domain]) do
              {:ok, use_zipper} ->
                {:ok,
                 Igniter.Code.Common.add_code(use_zipper, block_source(skills), placement: :after)}

              :error ->
                {:ok, zipper}
            end
        end
      end)
    end

    # Merges requested skill declarations into an existing `a2a do` block.
    # Idempotent by skill name: a name already declared in the block is never
    # written again, so two runs leave exactly one `a2a do` block with exactly
    # one declaration per requested skill.
    defp merge_skills_into_block(a2a_zipper, skills) do
      missing = Enum.reject(skills, fn {name, _, _} -> skill_declared?(a2a_zipper, name) end)

      case missing do
        [] ->
          {:ok, a2a_zipper}

        missing ->
          case Igniter.Code.Common.move_to_do_block(a2a_zipper) do
            {:ok, body} ->
              {:ok,
               Igniter.Code.Common.add_code(body, Enum.map_join(missing, "\n", &skill_line/1))}

            # An empty `a2a do end` block has no body zipper to append to
            # (`move_to_do_block/1` -> :error), so replace the whole call in
            # place with a regenerated block carrying the missing skills --
            # there is nothing in an empty block to preserve.
            :error ->
              {:ok, Igniter.Code.Common.replace_code(a2a_zipper, block_source(missing))}
          end
      end
    end

    # True when the block already declares `skill :name, ...` (any arity --
    # the DSL's resource/domain arg shapes and the keyword options make it
    # 2..4). Matched on the call's first positional argument, which is the
    # entity's identifier (`AshA2A.Dsl`'s `@skill`: `identifier: :name`).
    # Literal atoms arrive Sourceror-wrapped as `{:__block__, _, [:name]}`,
    # so unwrap before comparing -- a raw `{declared, _, _}` bind would see
    # `:__block__`, not the name.
    defp skill_declared?(a2a_zipper, name) do
      match?(
        {:ok, _},
        Igniter.Code.Function.move_to_function_call(a2a_zipper, :skill, [2, 3, 4], fn
          call_zipper ->
            case call_zipper.node do
              {:skill, _, [first | _]} ->
                unwrap_literal(first) == name

              _ ->
                false
            end
        end)
      )
    end

    defp unwrap_literal({:__block__, _, [value]}), do: value
    defp unwrap_literal(value), do: value

    defp block_source([]) do
      """
      a2a do
      end
      """
    end

    defp block_source(skills) do
      body = Enum.map_join(skills, "\n", &skill_line/1)

      "a2a do\n" <> body <> "end\n"
    end

    defp skill_line({name, action, nil}) do
      "  skill #{inspect(name)}, #{inspect(action)}\n"
    end

    defp skill_line({name, action, consequence}) do
      "  skill #{inspect(name)}, #{inspect(action)}, consequence: #{inspect(consequence)}\n"
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
