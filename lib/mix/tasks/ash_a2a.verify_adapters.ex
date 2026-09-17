# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshA2a.VerifyAdapters do
  @shortdoc "Runs the cross-adapter 'no ambient DO' regression guard (CI gate)"

  @moduledoc """
  Machine-checkable cross-adapter architecture guard for `ash_a2a`.

  Runs `AshA2A.ArchitectureVerifier.Adapters.checks/0` -- five real,
  file-content checks (see that module's moduledoc for full detail) proving
  that none of the five optional runtime adapters (Reactor, Oban, FLAME,
  DurableServer, Group+Presence) has regained a direct `AshA2A.Dispatcher`
  reference, and that each still real-wraps its mutating operations in its
  own already-established evidence contract (`AshA2A.CommandBus.run(` for
  Reactor, `Delivery.new(` for Oban, both for FLAME, `RuntimeReceipt.new(`
  for DurableServer/Group/Presence).

  Deliberately a standalone task, separate from `mix
  ash_a2a.verify_architecture` (`AshA2A.ArchitectureVerifier`, nine checks
  over capability-index/admission/semantic-request invariants) -- this task
  and its backing module never edit that existing task or module, staying
  purely additive.

      mix ash_a2a.verify_adapters

  Exits non-zero (via `Mix.raise/1`) if any check fails, so this is a real,
  repeatable CI gate a pipeline can run directly, the same way
  `mix ash_a2a.verify_architecture` already is.
  """

  use Mix.Task

  alias AshA2A.ArchitectureVerifier.Adapters

  @impl Mix.Task
  def run(_argv) do
    Mix.Task.run("app.start")

    results = Adapters.checks()

    Enum.each(results, &print_result/1)

    failed = Enum.filter(results, &(&1.status == :fail))

    Mix.shell().info("")

    Mix.shell().info(
      "#{length(results) - length(failed)}/#{length(results)} adapter architecture checks passed."
    )

    if failed != [] do
      Mix.raise(
        "ash_a2a.verify_adapters: #{length(failed)} adapter architecture invariant(s) FAILED -- " <>
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
