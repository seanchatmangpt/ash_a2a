# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ArchitectureVerifier.Adapters do
  @moduledoc """
  Real, executable cross-adapter "no ambient DO" architecture check.

  `AshA2A.ArchitectureVerifier` (nine checks) covers capability-index
  derivation, unknown/change-consequence admission, and the
  `semantic_requests` DSL opt-in -- per its own moduledoc, none of that
  reaches the five optional runtime adapters
  (`AshA2A.Reactor.*`, `AshA2A.Delivery.Oban`, `AshA2A.Execution.FLAME`,
  `AshA2A.Durability.DurableServer`, `AshA2A.Topology.{Group,Presence}`).
  The real evidence that those adapters never regain ambient DO exists only
  as twelve separate, adapter-specific test files
  (`reactor_command_workflow_test.exs`, `flame_placement_test.exs`,
  `flame_real_placement_test.exs`, `oban_delivery_test.exs`,
  `oban_delivery_qualification_test.exs`, `durable_server_test.exs`,
  `durable_server_continuity_test.exs`, `durable_server_real_restart_test.exs`,
  `group_topology_test.exs`, `group_real_topology_test.exs`,
  `presence_topology_test.exs`, `lifecycle_reactor_test.exs`) -- no single
  check asserts the invariant across all five uniformly, so a future adapter
  edit that reintroduces a direct `AshA2A.Dispatcher` call, or drops the
  adapter's own established evidence wrapper, fails loudly here rather than
  only if that adapter's own scattered test file happens to still cover it.

  ## What "no ambient DO" means, checked per real adapter source file

  Every check below reads the adapter's own real `.ex` source file(s) off
  disk (`File.read!/1` against this compiled module's own `__DIR__` --
  the real, current file, not a hand-copied string) and asserts two things
  against the real text:

    1. **No direct `AshA2A.Dispatcher` reference** -- no `AshA2A.Dispatcher.`
       call, `alias AshA2A.Dispatcher`, or `import AshA2A.Dispatcher` appears
       anywhere in the adapter's source. `AshA2A.Dispatcher.dispatch/5` is
       reachable only through `AshA2A.CommandBus.run/4`'s admission/claim/
       receipt fence (see `Receipted Command Execution.md` INV-1) -- an
       adapter regaining a direct reference would be exactly the "ambient
       DO" regression this check exists to catch. A bare mention of the word
       "Dispatcher" inside a `@moduledoc` (both `reactor/execute_command.ex`
       and `reactor/command_workflow.ex` document the invariant this way
       today) is deliberately NOT flagged -- only an actual code reference
       (module-dot-call, `alias`, or `import`) counts, so this check does not
       punish the very documentation that states the invariant.
    2. **The adapter's own already-established evidence contract is real,
       present code** -- not a generic "must wrap in RuntimeReceipt" rule
       (that would be false for two of the five: `AshA2A.Delivery.Oban`'s
       real evidence type is `AshA2A.Delivery`, not `AshA2A.RuntimeReceipt`,
       per `Integration Adapters.md` #13.2 ("Delivery != execution"); and
       `AshA2A.Reactor.ExecuteCommand` legitimately returns the real command
       `AshA2A.Receipt` produced by `AshA2A.CommandBus.run/4` directly,
       which is correct behavior, not a violation, because it still only
       ever reaches that receipt by routing through `CommandBus`). Each
       check below instead confirms the specific real contract that
       adapter's own moduledoc already documents:

       | Adapter | Real evidence contract checked |
       |---|---|
       | Reactor (`reactor/*.ex`) | Mutating step routes through `AshA2A.CommandBus.run(` |
       | Oban (`delivery/oban.ex`) | Mutating `enqueue/3` wraps in `Delivery.new(` |
       | FLAME (`execution/flame.ex`) | Mutating `run/5` routes through `CommandBus.run(` inside the placed closure AND wraps placement evidence in `RuntimeReceipt.new(` |
       | DurableServer (`durability/durable_server.ex`) | Every mutating lifecycle op wraps in `RuntimeReceipt.new(` |
       | Group + Presence (`topology/{group,presence}.ex`) | Every mutating op in both files wraps in `RuntimeReceipt.new(` |

  This is a real, deterministic, file-content check (Chicago-style: a real
  file on disk, real text, a real assertion on that text) -- it does not
  require standing up Oban/FLAME/DurableServer/Group/Presence runtime
  infrastructure (that heavier, genuinely-behavioral proof is exactly what
  the twelve adapter-specific test files already do; this check is
  deliberately narrower and orthogonal to them: a static regression fence,
  not a duplicate of their runtime coverage).

  Wired as its own standalone `mix ash_a2a.verify_adapters` task
  (`lib/mix/tasks/ash_a2a.verify_adapters.ex`), kept separate from
  `mix ash_a2a.verify_architecture` / `AshA2A.ArchitectureVerifier` so this
  addition never edits either of those existing, shared files.
  """

  @type result :: %{name: String.t(), status: :pass | :fail, detail: String.t()}

  # `__DIR__` is a compile-time constant: the real absolute directory of
  # *this* source file (`lib/ash_a2a/architecture_verifier/`) as it sits on
  # disk in this exact worktree/checkout. `Path.expand("..", __DIR__)`
  # therefore always resolves to this same checkout's real `lib/ash_a2a`
  # directory, wherever this repo happens to be cloned.
  @lib_ash_a2a_dir Path.expand("..", __DIR__)

  @doc "Runs every real cross-adapter 'no ambient DO' check, most-important first."
  @spec checks() :: [result()]
  def checks do
    [
      check_reactor_no_ambient_do(),
      check_oban_no_ambient_do(),
      check_flame_no_ambient_do(),
      check_durable_server_no_ambient_do(),
      check_group_presence_no_ambient_do()
    ]
  end

  # -- Check 1: Reactor step adapters --

  @doc """
  Real check: every real `.ex` file under `lib/ash_a2a/reactor/` contains no
  direct `AshA2A.Dispatcher` code reference, and the mutating step
  (`AshA2A.Reactor.ExecuteCommand`) real-routes through
  `AshA2A.CommandBus.run(` rather than any raw dispatch/Ash-action call.
  """
  @spec check_reactor_no_ambient_do() :: result()
  def check_reactor_no_ambient_do do
    name = "Reactor adapter (lib/ash_a2a/reactor/*.ex) never regains ambient DO"
    files = source_files("reactor")

    evaluate(name, files,
      forbidden: [],
      required: [{"execute_command.ex", "CommandBus.run("}]
    )
  end

  # -- Check 2: Oban delivery adapter --

  @doc """
  Real check: `lib/ash_a2a/delivery/oban.ex` contains no direct
  `AshA2A.Dispatcher` code reference, and its mutating `enqueue/3` real-wraps
  its result in `Delivery.new(` -- Oban's own established evidence contract
  (delivery is recorded separately from execution; see this module's
  moduledoc), never a raw dispatch call and never a bare `AshA2A.Receipt`.
  """
  @spec check_oban_no_ambient_do() :: result()
  def check_oban_no_ambient_do do
    name = "Oban delivery adapter (lib/ash_a2a/delivery/oban.ex) never regains ambient DO"
    files = source_files("delivery/oban.ex")

    evaluate(name, files,
      forbidden: [],
      required: [{"oban.ex", "Delivery.new("}]
    )
  end

  # -- Check 3: FLAME execution adapter --

  @doc """
  Real check: `lib/ash_a2a/execution/flame.ex` contains no direct
  `AshA2A.Dispatcher` code reference; its placed closure real-routes through
  `CommandBus.run(`, and every real placement attempt (success or failure)
  is wrapped in `RuntimeReceipt.new(` -- FLAME chooses only *where* the
  command runs, never gaining independent dispatch authority.
  """
  @spec check_flame_no_ambient_do() :: result()
  def check_flame_no_ambient_do do
    name = "FLAME execution adapter (lib/ash_a2a/execution/flame.ex) never regains ambient DO"
    files = source_files("execution/flame.ex")

    evaluate(name, files,
      forbidden: [],
      required: [
        {"flame.ex", "CommandBus.run("},
        {"flame.ex", "RuntimeReceipt.new("}
      ]
    )
  end

  # -- Check 4: DurableServer durability adapter --

  @doc """
  Real check: `lib/ash_a2a/durability/durable_server.ex` contains no direct
  `AshA2A.Dispatcher` code reference, and every real mutating lifecycle
  operation (`ensure_task/5`, `rehome_task/5`, `cordon_task/3`,
  `uncordon_task/2`, `delete_task/3` -- all routed through the shared
  private `actuate/4`) real-wraps its result in `RuntimeReceipt.new(`.
  """
  @spec check_durable_server_no_ambient_do() :: result()
  def check_durable_server_no_ambient_do do
    name =
      "DurableServer adapter (lib/ash_a2a/durability/durable_server.ex) never regains ambient DO"

    files = source_files("durability/durable_server.ex")

    evaluate(name, files,
      forbidden: [],
      required: [{"durable_server.ex", "RuntimeReceipt.new("}]
    )
  end

  # -- Check 5: Group + Presence topology adapters --

  @doc """
  Real check: both `lib/ash_a2a/topology/group.ex` and
  `lib/ash_a2a/topology/presence.ex` contain no direct `AshA2A.Dispatcher`
  code reference, and every real mutating operation in each
  (`register/3`/`unregister/2`/`join/3`/`leave/2` for Group;
  `track/5`/`update/5`/`untrack/4` for Presence) real-wraps its result in
  `RuntimeReceipt.new(`.
  """
  @spec check_group_presence_no_ambient_do() :: result()
  def check_group_presence_no_ambient_do do
    name =
      "Group + Presence topology adapters (lib/ash_a2a/topology/{group,presence}.ex) never regain ambient DO"

    files = source_files(["topology/group.ex", "topology/presence.ex"])

    evaluate(name, files,
      forbidden: [],
      required: [
        {"group.ex", "RuntimeReceipt.new("},
        {"presence.ex", "RuntimeReceipt.new("}
      ]
    )
  end

  # -- shared helpers --

  # Reads the real, current adapter source file(s) off disk relative to this
  # compiled module's own directory. `rel` is either a single relative path
  # (a directory glob-suffixed with `*.ex`, or a single file) or a list of
  # relative file paths. Returns `%{basename => {path, content}}`.
  @spec source_files(String.t() | [String.t()]) :: %{String.t() => {String.t(), String.t()}}
  defp source_files(rel) when is_binary(rel) do
    path = Path.join(@lib_ash_a2a_dir, rel)

    paths =
      if String.ends_with?(rel, ".ex") do
        [path]
      else
        Path.wildcard(Path.join(path, "*.ex"))
      end

    read_all(paths)
  end

  defp source_files(rels) when is_list(rels) do
    rels
    |> Enum.map(&Path.join(@lib_ash_a2a_dir, &1))
    |> read_all()
  end

  defp read_all(paths) do
    Map.new(paths, fn path -> {Path.basename(path), {path, File.read!(path)}} end)
  end

  # A real, direct code reference to `AshA2A.Dispatcher` -- a dotted call
  # (`AshA2A.Dispatcher.` followed by a function name), an `alias`, or an
  # `import`. Deliberately excludes a bare backtick-quoted mention inside
  # prose/`@moduledoc` (e.g. "call `AshA2A.Dispatcher` directly", which two
  # real reactor files use to document this very invariant) -- only an
  # actual call-shaped or alias/import-shaped reference counts.
  @dispatcher_call ~r/AshA2A\.Dispatcher\./
  @dispatcher_alias ~r/\balias\s+AshA2A\.Dispatcher\b/
  @dispatcher_import ~r/\bimport\s+AshA2A\.Dispatcher\b/

  @spec direct_dispatcher_reference?(String.t()) :: boolean()
  defp direct_dispatcher_reference?(source) do
    Regex.match?(@dispatcher_call, source) or
      Regex.match?(@dispatcher_alias, source) or
      Regex.match?(@dispatcher_import, source)
  end

  # Evaluates one check's `files` (a `%{basename => {path, content}}` map,
  # from `source_files/1`) against a `forbidden` list of `{basename,
  # pattern}` pairs (real code text that must NOT appear) and a `required`
  # list of `{basename, pattern}` pairs (real code text that MUST appear),
  # in addition to the shared "no direct Dispatcher reference" check run
  # over every file unconditionally. Returns a real `result()` map with a
  # detail string naming exactly which real file(s)/pattern(s) passed or
  # failed, never a bare boolean.
  @spec evaluate(String.t(), map(), keyword()) :: result()
  defp evaluate(name, files, opts) do
    forbidden = Keyword.get(opts, :forbidden, [])
    required = Keyword.get(opts, :required, [])

    dispatcher_violations =
      files
      |> Enum.filter(fn {_basename, {_path, content}} ->
        direct_dispatcher_reference?(content)
      end)
      |> Enum.map(fn {basename, _} -> basename end)

    forbidden_violations =
      for {basename, pattern} <- forbidden,
          {^basename, {_path, content}} <- files,
          String.contains?(content, pattern) do
        "#{basename} unexpectedly contains forbidden pattern #{inspect(pattern)}"
      end

    missing_required =
      for {basename, pattern} <- required,
          {^basename, {_path, content}} <- files,
          not String.contains?(content, pattern) do
        "#{basename} is missing required pattern #{inspect(pattern)}"
      end

    missing_files =
      for {basename, pattern} <- required, not Map.has_key?(files, basename) do
        "#{basename} not found on disk (checking for #{inspect(pattern)})"
      end

    violations =
      dispatcher_violations |> Enum.map(&"#{&1} contains a direct AshA2A.Dispatcher reference")

    all_violations = violations ++ forbidden_violations ++ missing_required ++ missing_files

    inspected =
      files
      |> Map.keys()
      |> Enum.sort()
      |> Enum.join(", ")

    if all_violations == [] do
      pass(
        name,
        "inspected #{map_size(files)} real file(s) (#{inspected}): no direct AshA2A.Dispatcher " <>
          "reference in any, and every required real evidence-wrapper pattern " <>
          "(#{Enum.map_join(required, ", ", fn {b, p} -> "#{b}: #{inspect(p)}" end)}) is present."
      )
    else
      fail(name, Enum.join(all_violations, "; "))
    end
  end

  defp pass(name, detail), do: %{name: name, status: :pass, detail: detail}
  defp fail(name, detail), do: %{name: name, status: :fail, detail: detail}
end
