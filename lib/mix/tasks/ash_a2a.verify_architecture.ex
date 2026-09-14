# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshA2a.VerifyArchitecture do
  @shortdoc "Runs real, executable architecture-invariant checks (CI gate)"

  @moduledoc """
  Machine-checkable architecture verifier for `ash_a2a`.

  Runs a small, fixed set of REAL, executable checks against this repo's own
  real compiled code (`AshA2A.ArchitectureVerifier` -- see that module for
  what each check does and why) and prints one `PASS`/`FAIL` line per check.
  Exits non-zero (via `Mix.raise/1`, which `Mix.CLI` turns into a `System.halt(1)`
  when this task is run from a shell) if any check fails, so this is a real,
  repeatable architecture-invariant gate a CI pipeline can run directly:

      mix ash_a2a.verify_architecture

  This is not documentation of an intended invariant -- every check below
  calls the real, current, unmodified `AshA2A.Info`/`AshA2A.Command`/
  `AshA2A.CommandBus` public API against a real compiled `Ash.Resource`
  (`AshA2A.ArchitectureVerifier.Fixture.Resource`, defined alongside the
  checks in `lib/ash_a2a/architecture_verifier.ex` specifically because
  `test/support/fixture.ex`'s existing `AshA2A.Test.Fixture.Echo`/`Item`
  fixtures are compiled only under `elixirc_paths(:test)` -- see `mix.exs`
  -- and are therefore unreachable from a plain `mix` task run outside
  `MIX_ENV=test`). A change to `AshA2A.CommandBus`'s admission logic, to
  `AshA2A.Command.fingerprint/1`'s hashed field set, or to
  `AshA2A.CapabilityIndex.Compiler`'s default consequence classification
  that breaks one of these four invariants makes this task fail for real,
  not just out of date documentation someone forgot to update.

  Checks performed (see `AshA2A.ArchitectureVerifier.checks/0`):

    1. `AshA2A.Info.capability_index/1` derives a real, non-nil capability
       index from a compiled resource (capability truth is derivable).
    2. A skill with real compiled `consequence: :unknown` is refused by
       `AshA2A.CommandBus.run/4` with `:consequence_unclassified`.
    3. A skill with real compiled `consequence: :change` and no `Authority`
       is refused by `AshA2A.CommandBus.run/4` with `:authority_required`.
    4. `AshA2A.Command.fingerprint/1` is stable for two commands sharing a
       `command_id` and identical semantic content, and diverges for two
       commands sharing a `command_id` but carrying different `input`
       (replay-safety and conflict-safety invariants).
  """

  use Mix.Task

  alias AshA2A.ArchitectureVerifier

  @impl Mix.Task
  def run(_argv) do
    Mix.Task.run("app.start")

    results = ArchitectureVerifier.checks()

    Enum.each(results, &print_result/1)

    failed = Enum.filter(results, &(&1.status == :fail))

    Mix.shell().info("")

    Mix.shell().info(
      "#{length(results) - length(failed)}/#{length(results)} architecture checks passed."
    )

    if failed != [] do
      Mix.raise(
        "ash_a2a.verify_architecture: #{length(failed)} architecture invariant(s) FAILED -- " <>
          Enum.map_join(failed, "; ", & &1.name)
      )
    end
  end

  defp print_result(%{status: :pass, name: name, detail: detail}) do
    Mix.shell().info("PASS  #{name}\n      #{detail}")
  end

  defp print_result(%{status: :fail, name: name, detail: detail}) do
    Mix.shell().error("FAIL  #{name}\n      #{detail}")
  end
end
