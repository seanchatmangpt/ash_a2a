# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.PortContractTest do
  use ExUnit.Case, async: true

  defmodule FakeBeam4pm do
    def execute(:strategic_recompile, _handle, inputs, _opts),
      do: {:recompile_required, Map.get(inputs, :evidence, %{})}
  end

  defmodule FakeAshPPlan do
    def select_policy(domain, initial, opts),
      do: {:ok, %{domain: domain, initial: initial, opts: opts, policy: :candidate}}
  end

  test "Beam4PM strategic recompile remains a candidate rather than provider failure" do
    assert {:ok, %{subject: "s", outcome: :recompile_required}} =
             AshA2A.Replan.Port.Beam4pm.propose(
               %{
                 subject: "s",
                 decision: :strategic_recompile,
                 formalism: :hddl,
                 evidence: %{x: 1}
               },
               beam4pm_module: FakeBeam4pm
             )
  end

  test "AshPPlan uses the live select_policy/3 boundary" do
    # The port prefers the owner-side AshPPlan.SA2A.Provider adapter (see
    # AshA2A.Replan.AshPPlanPortTest). To exercise the legacy select_policy/3
    # boundary directly, disable the owner adapter with an unloadable module.
    assert {:ok, %{subject: "s", policy: :candidate}} =
             AshA2A.Replan.Port.AshPPlan.propose(
               %{subject: "s", formalism: :fond, domain: %{d: 1}, initial: :s0},
               ash_pplan_provider_module: :missing_owner_adapter,
               ash_pplan_module: FakeAshPPlan
             )
  end
end
