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
    Installs `ash_a2a` into the current project: wires up the `Spark.Formatter`
    plugin and `import_deps: [:ash_a2a]`, and -- when
    `--target` is given -- patches the target module's `extensions:` list to
    include `AshA2A` on `use Ash.Resource` (or `AshA2A.Domain` on `use
    Ash.Domain` with `--type domain`; `AshA2A.Domain` is the domain-target
    extension module and, like the resource path, also provides the
    `skill :name, Resource, :action` DSL shape), plus a starter `a2a do end`
    block.

    ## Optional plan provider (`--with-pplan`)

        mix ash_a2a.install --with-pplan

    Also adds `{:ash_pplan, "~> 26.10"}` to the project's dependencies (the
    same constraint ash_a2a itself pins for integration testing) and prints
    the `AshA2A.Providers.PPlan` provider config snippet in the post-install
    notice. `AshA2A.Providers.PPlan` is referenced by name only; the
    provider integration lives in `AshA2A.Providers.PPlan`'s own docs.

    ## Generated files

    In addition to patching the target module, the installer appends (or
    creates, via `Igniter.create_new_file/4`) a versioned "AshA2A skills"
    section to `AGENTS.md` -- usage rules for writing skills: the
    `a2a do skill ... end` grammar, the consequence value set, and the
    authority gate semantics. Idempotent by a versioned marker comment;
    an existing section is never duplicated.

    The same run also emits a marker-checked `usage-rules.md` at the
    project root (the ash-ecosystem convention: packages ship
    `usage-rules.md` so `mix usage_rules.sync` can combine them into your
    own agent rules file). If the file already exists without the
    AshA2A marker, the section is appended rather than overwriting your
    content; an existing marked section is never duplicated.

    ## Router forward

    The post-install notice always carries the exact router snippet
    (`forward "/a2a", AshA2A.Transport.Plug, agent: MyApp.Agent`).
    When a Phoenix router is detectable, the notice names it; the snippet
    is disclosed as a manual step either way (the same honest fallback
    shape as the no-target notice -- router-body injection has no safe,
    non-interactive Igniter helper in this vendored version, so nothing is
    silently guessed at or half-patched).

    Detects an existing `extensions:` option on the target module's `use
    Ash.Resource` / `use Ash.Domain` call and merges `AshA2A` into it instead of
    inserting a second, separate `extensions:` option -- idempotent, so
    re-running install against an already-patched module does not duplicate
    `AshA2A` in the list.

    ## Usage

        mix igniter.install ash_a2a
        mix ash_a2a.install --target MyApp.SomeResource
        mix ash_a2a.install --target MyApp.SomeDomain --type domain
        mix ash_a2a.install --with-pplan

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

    # Version marker for the generated AGENTS.md section (bump to re-issue the
    # section after a content revision; see add_agents_md/1). v2 re-issues the
    # section onto installs still carrying the v1 text, documenting the `skill`
    # entity's `argument_mapping` / `get?` / `lease_required?` fields and the
    # compile-time VerifySkills refusals.
    @agents_md_marker "<!-- ash_a2a:agents:v2 -->"

    # Version marker for the generated usage-rules.md section (same convention
    # as the AGENTS.md marker: bump to re-issue after a content revision). The
    # emitted section condenses the package's own usage-rules.md (the repo-root
    # file that ships in the hex package and is combined into consumer rule
    # files via `mix usage_rules.sync`); the install court in
    # test/mix/tasks/ash_a2a_install_test.exs asserts that the invariant rule
    # lines appear in BOTH documents, so the two cannot silently drift apart.
    @usage_rules_marker "<!-- ash_a2a:usage-rules:v1 -->"

    # Usage rules emitted as a `usage-rules.md` section at the consumer
    # project root. Deliberately the same do/don't pairs as the package's
    # usage-rules.md, condensed: the consequence value set and fail-closed
    # defaults, the authentication-is-not-authority boundary, and the
    # compile-time refusals -- all quoted from AshA2A.Dsl,
    # AshA2A.Verifiers.VerifySkills and the security how-to, not invented.
    @usage_rules_md_section """
    #{@usage_rules_marker}
    <!-- ash_a2a:install-generated. Do not edit between the markers; bump the version marker to re-issue. -->

    # Rules for working with AshA2A

    Ash is the source of truth. `skill` declarations cannot create actions,
    change action arguments, or expose `public?: false` actions -- they only
    override A2A metadata or suppress exposure (`expose?: false`).

    ## Consequences

    `consequence` is one of `:observe`, `:change`, `:external_do`, `:unknown`.

    - `:observe` -- read-only; skips authority, admission and receipts.
      Declare it only on reads; on a mutating action it is a compile-time
      DslError (`observe_on_mutating_action`).
    - `:change` / `:external_do` -- require a valid authority grant for this
      exact `(principal, capability)`. Declare `consequence: :external_do`
      explicitly on external side-effecting skills; a generic `:action` skill
      defaults to the fail-closed `:unknown`.
    - `:unknown` -- refused at dispatch with `:consequence_unclassified`,
      regardless of authority.

    ## Authority is not authentication

    `AshA2A.Protocol.Plug.Auth` establishes who the caller is (and never
    trusts `actor`/`tenant` from message metadata). What the caller may do
    is a separate decision: per-`(principal, capability)` standing grants via
    `AshA2A.Authority.Grant`, checked fail-closed by the `:broker` authority
    policy (the default). An ungranted consequential call is refused with
    `:authority_required` before the Ash action runs. Re-verify grants live
    on async paths. The shipped brokers are reference implementations, not a
    production identity system.

    ## Compile-time enforcement

    `AshA2A.Verifiers.VerifySkills` refuses, at compile time: unknown or
    non-public actions (`REFUSED_ACTION_NOT_FOUND` /
    `REFUSED_ACTION_NOT_PUBLIC`), `argument_mapping` targets that are not
    real action arguments (`refused_argument_mapping_target`),
    non-JSON-serializable argument types
    (`refused_type_not_json_serializable`), and `lease_required?: true`
    without a lease-capable authorizer
    (`refused_lease_required_no_authorizer`).

    ## Syncing these rules

    Combine into your own agent rules file with the `usage_rules` package:

        mix usage_rules.sync AGENTS.md --all
    """

    # Usage rules for agents writing skills against ash_a2a: the `a2a do skill
    # ... end` grammar, the consequence value set, and the authority gate
    # semantics. Kept deliberately small and truthful to `AshA2A.Dsl` (the
    # consequence list and the fail-closed defaults are quoted from there, not
    # invented here).
    @agents_md_section """
    #{@agents_md_marker}
    <!-- ash_a2a:install-generated. Do not edit between the markers; bump the version marker to re-issue. -->

    ## AshA2A skills (usage rules)

    Declare an A2A skill inside `a2a do ... end` on an `Ash.Resource` (or an
    `Ash.Domain` extended with `AshA2A.Domain`):

        a2a do
          skill :name, :action                            # resource shape
          skill :name, SomeResource, :action              # domain shape
          skill :name, :action, consequence: :external_do
        end

    `consequence` is one of `:observe`, `:change`, `:external_do`, `:unknown`.
    A generic `:action` skill defaults to the fail-closed `:unknown`
    consequence. `consequence: :external_do` declares an external
    side-effecting actuation: dispatch under such a skill is subject to the
    fail-closed `:broker` authority policy (a valid authority lease is
    required). `consequence: :observe` marks a pure read -- :observe skills
    skip authority, admission and receipts, so declare it only on reads. A
    task refused at admission (an authority-gate denial or a
    capability-resolution refusal that fired before the handler had any
    effect) transitions to the terminal `REJECTED` task state
    (`TASK_STATE_REJECTED` on the wire).

    Every skill also accepts:

        skill :get_item, :get,
          get?: true,
          argument_mapping: %{"id" => :id},
          lease_required?: true

    - `argument_mapping` maps inbound A2A wire argument names (strings) onto
      the action's atom argument names; the default (`%{}`) passes wire names
      through unchanged.
    - `get?` marks a read skill as a single-record get (mirroring
      ash_json_api's `get?` semantic); consumers read it via the compiled
      capability index.
    - `lease_required?` requires a valid authority lease to dispatch under
      this skill.

    Declarations are enforced at compile time by
    `AshA2A.Verifiers.VerifySkills`: an unknown or non-public action fails
    with `REFUSED_ACTION_NOT_FOUND` / `REFUSED_ACTION_NOT_PUBLIC`; an
    `argument_mapping` target that is not a real argument on the action
    fails with `refused_argument_mapping_target`; a known non-JSON-
    serializable argument type fails with `refused_type_not_json_serializable`
    (unknown custom types warn instead); and `lease_required?: true` without
    a lease-capable authorizer on the subject fails with
    `refused_lease_required_no_authorizer`.
    """

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :ash_a2a,
        example:
          "mix ash_a2a.install --target MyApp.SomeResource --skill advance_item:advance:external_do",
        positional: [],
        schema: [target: :string, type: :string, skill: :keep, with_pplan: :boolean],
        defaults: [type: "resource", skill: [], with_pplan: false],
        required: []
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      skills = parse_skills!(igniter.args.options[:skill] || [])
      type = igniter.args.options[:type] || "resource"
      with_pplan? = igniter.args.options[:with_pplan] || false

      # Detect a Phoenix router up front (non-interactive: `list_routers/1`
      # scans, `select_router/2` prompts, so the latter is never called here).
      # The detected name personalizes the router snippet in the post-install
      # notice; the snippet stays a disclosed manual step either way.
      {igniter, routers} = Igniter.Libs.Phoenix.list_routers(igniter)

      base =
        igniter
        |> Igniter.Project.Formatter.import_dep(:ash_a2a)
        |> Igniter.Project.Formatter.add_formatter_plugin(Spark.Formatter)
        |> maybe_add_pplan_dep(with_pplan?)
        |> add_agents_md()
        |> add_usage_rules_md()

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
          |> Igniter.add_notice(install_notice(nil, type, with_pplan?, routers))

        target ->
          target_module = Igniter.Project.Module.parse(target)

          base
          |> add_extension(target_module, type)
          |> add_dsl_block(target_module, skills)
          |> Igniter.add_notice(install_notice(target, type, with_pplan?, routers))
      end
    end

    # `--with-pplan` adds the plan-provider dependency, mirroring ash_a2a's own
    # test-only pin (mix.exs: `{:ash_pplan, "~> 26.10", only: :test}`; ash_pplan
    # is at 26.10.3). Consumer projects get it as a real dependency (no `only:`,
    # since the AshA2A.Providers.PPlan provider is runtime, not test-only).
    defp maybe_add_pplan_dep(igniter, true) do
      Igniter.Project.Deps.add_dep(igniter, {:ash_pplan, "~> 26.10"})
    end

    defp maybe_add_pplan_dep(igniter, _with_pplan?), do: igniter

    # Appends (or creates) a versioned AshA2A skills section in AGENTS.md:
    # usage rules for writing skills. Idempotent by the marker comment -- an
    # existing section is never duplicated; a file without one gets it appended.
    defp add_agents_md(igniter) do
      if Igniter.exists?(igniter, "AGENTS.md") do
        Igniter.update_file(igniter, "AGENTS.md", fn source ->
          content = Rewrite.Source.get(source, :content)

          if String.contains?(content, @agents_md_marker) do
            source
          else
            Rewrite.Source.update(source, :content, content <> "\n" <> @agents_md_section)
          end
        end)
      else
        Igniter.create_new_file(igniter, "AGENTS.md", @agents_md_section)
      end
    end

    # Emits (or appends to) a marker-checked `usage-rules.md` at the consumer
    # project root -- the ash-ecosystem convention (`deps/ash/usage-rules.md`,
    # `deps/ash_ai/usage-rules.md`, ...): packages ship a rules file so AI
    # tools and newcomers get correct-usage guidance, combined into a project's
    # own rules file via `mix usage_rules.sync`. Idempotent by the version
    # marker, exactly like add_agents_md/1 above: an existing marked section
    # is never duplicated; a file without the marker keeps its content and
    # gets the AshA2A section appended.
    defp add_usage_rules_md(igniter) do
      if Igniter.exists?(igniter, "usage-rules.md") do
        Igniter.update_file(igniter, "usage-rules.md", fn source ->
          content = Rewrite.Source.get(source, :content)

          if String.contains?(content, @usage_rules_marker) do
            source
          else
            Rewrite.Source.update(source, :content, content <> "\n" <> @usage_rules_md_section)
          end
        end)
      else
        Igniter.create_new_file(igniter, "usage-rules.md", @usage_rules_md_section)
      end
    end

    # Post-install notice: one notice per run, carrying the manual steps that
    # are disclosed rather than guessed at (router forward snippet, provider
    # config snippet when --with-pplan was passed).
    defp install_notice(target, type, with_pplan?, routers) do
      Enum.join(
        [
          target_summary(target, type),
          router_section(routers),
          pplan_section(with_pplan?)
        ],
        "\n"
      )
    end

    defp target_summary(nil, _type), do: "AshA2A installed successfully!\n"

    defp target_summary(target, type) do
      "AshA2A installed into #{inspect(target)} (--type #{type}).\n"
    end

    # Honest fallback: this installer never patches router files -- the vendored
    # Igniter has no safe, non-interactive injection point for a top-level
    # `forward/3` in a router body -- so the exact snippet is disclosed in the
    # notice instead, naming the detected router when one was found.
    defp router_section([]) do
      """

      No Phoenix router was detected. To serve A2A over HTTP, add to your router:

          forward "/a2a", AshA2A.Transport.Plug, agent: MyApp.Agent
      """
    end

    defp router_section(routers) do
      router = routers |> Enum.sort() |> hd()

      """

      Phoenix router detected: #{inspect(router)}. To serve A2A over HTTP, add to it:

          forward "/a2a", AshA2A.Transport.Plug, agent: MyApp.Agent
      """
    end

    defp pplan_section(false), do: ""

    defp pplan_section(true) do
      """

      `ash_pplan` was added to your dependencies (`{:ash_pplan, "~> 26.10"}`).
      To enable the plan-provider integration, configure the provider by name:

          # config/config.exs
          config :ash_a2a, :providers, [AshA2A.Providers.PPlan]
      """
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
    # `--type domain` injects `AshA2A.Domain` (the domain-target extension,
    # being built in parallel -- referenced by name only) onto the target's
    # `use Ash.Domain` call. The default resource path is unchanged: `AshA2A`
    # is merged into the `use Ash.Resource` / `use Ash.Domain` call exactly as
    # before, keeping `Spark.Igniter.add_extension/5`'s idempotent
    # detect-and-merge behavior on both paths.
    defp add_extension(igniter, target_module, "domain") do
      Spark.Igniter.add_extension(
        igniter,
        target_module,
        [Ash.Domain],
        :extensions,
        AshA2A.Domain
      )
    end

    defp add_extension(igniter, target_module, _type) do
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

      1. Add `:ash_a2a` to your `mix.exs` dependencies:

             {:ash_a2a, "~> 0.1"}

      2. Add `import_deps: [:ash_a2a]` and `plugins: [Spark.Formatter]` to your
         `.formatter.exs`.

      3. Add `extensions: [AshA2A]` to your Ash.Resource or Ash.Domain modules
         (the same `AshA2A` extension module works on both):

             use Ash.Resource,
               extensions: [AshA2A]

             a2a do
             end

      4. Optional plan provider: add `{:ash_pplan, "~> 26.10"}` to your
         dependencies and `config :ash_a2a, :providers, [AshA2A.Providers.PPlan]`
         to your config (the same steps `--with-pplan` would automate).
      """)
    end
  end
end
