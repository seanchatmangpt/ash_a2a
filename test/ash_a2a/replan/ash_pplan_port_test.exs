# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.AshPPlanPortTest do
  use ExUnit.Case, async: true

  alias AshA2A.Replan.Port.AshPPlan, as: Port

  defmodule OwnerProvider do
    def supports?(formalism), do: formalism in [:fond, :powl]

    def propose(request, _opts) do
      {:ok,
       %{
         subject: request.subject,
         formalism: request.formalism,
         authority: :none,
         standing: :candidate,
         source: :owner_adapter
       }}
    end
  end

  defmodule LegacyPlanner do
    def select_policy(_domain, _initial, _opts) do
      {:ok, %{policy: %{s0: :go}, mode: :strong, validation: %{ok: true}}}
    end
  end

  test "does not claim unsupported formalism" do
    refute Port.supports?(:pddl)
  end

  test "prefers the canonical owner-side adapter when present" do
    assert {:ok,
            %{
              subject: "exact-subject",
              authority: :none,
              standing: :candidate,
              source: :owner_adapter
            }} =
             Port.propose(
               %{subject: "exact-subject", formalism: :fond},
               ash_pplan_provider_module: OwnerProvider,
               ash_pplan_module: :definitely_not_the_owner
             )
  end

  test "legacy adapter remains a compatibility fallback" do
    assert {:ok,
            %{
              subject: "exact-subject",
              authority: :none,
              standing: :candidate,
              policy: %{s0: :go}
            }} =
             Port.propose(
               %{
                 subject: "exact-subject",
                 formalism: :fond,
                 domain: %{domain: true},
                 initial: :s0
               },
               ash_pplan_provider_module: :missing_owner_adapter,
               ash_pplan_module: LegacyPlanner
             )
  end
end
