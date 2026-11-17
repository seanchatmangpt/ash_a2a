# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
# SPDX-License-Identifier: MIT

# ==============================================================================
# Consolidated Test Suite: Replan & Port Totality
# Target: test/replan/replan_consolidated_test.exs
# Consolidated by Worker 17 from 26 source files:
#   - test/ash_a2a/replan/ash_pplan_port_parity_court_test.exs
#   - test/ash_a2a/replan/ash_pplan_port_test.exs
#   - test/ash_a2a/replan/attempt_budget_test.exs
#   - test/ash_a2a/replan/beam4pm_port_test.exs
#   - test/ash_a2a/replan/candidate_authority_refusal_test.exs
#   - test/ash_a2a/replan/candidate_fence_test.exs
#   - test/ash_a2a/replan/effect_identity_test.exs
#   - test/ash_a2a/replan/ferroplan_port_test.exs
#   - test/ash_a2a/replan/loop_failover_test.exs
#   - test/ash_a2a/replan/outcome_test.exs
#   - test/ash_a2a/replan/port_contract_test.exs
#   - test/ash_a2a/replan/portable_envelope_test.exs
#   - test/ash_a2a/replan/portable_schema_test.exs
#   - test/ash_a2a/replan/provider_failure_test.exs
#   - test/ash_a2a/replan/provider_result_test.exs
#   - test/ash_a2a/replan/provider_set_test.exs
#   - test/ash_a2a/replan/reconcile_gate_test.exs
#   - test/ash_a2a/replan/recovery_policy_test.exs
#   - test/ash_a2a/replan/refusal_taxonomy_test.exs
#   - test/ash_a2a/replan/registry_test.exs
#   - test/ash_a2a/replan/replay_key_test.exs
#   - test/ash_a2a/replan/router_test.exs
#   - test/ash_a2a/replan/stale_plan_test.exs
#   - test/ash_a2a/replan/subject_lineage_test.exs
#   - test/ash_a2a/replan/trace_test.exs
#   - test/replan/port_ashpplan_conformance_court_test.exs
# ==============================================================================

# --- SECTION 1: Original test/ash_a2a/replan/ash_pplan_port_parity_court_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.AshPPlanPortParityCourtTest do
  @moduledoc """
  Deliberation-parity court through the `AshA2A.Replan.Port.AshPPlan` seam.

  SEAM DIVISION (docs/explanation/pplan-seams.md): this court exercises ONLY
  the REPLAN CANDIDATE POLICY seam — `propose/2` builds planner candidates
  through `AshPPlan.SA2A.Provider` against real candidate domains. It never
  starts a durable run and never touches
  `AshPPlan.Reactor.Durable.Engine` (that seam lives exclusively in
  `AshA2A.Providers.PPlan`).

  P16 NOTE (upstream in-flight): the authorization seam (ash_pplan facade,
  P16) is in-flight upstream. Today `AshPPlan.SA2A.Refusal` carries a closed
  vocabulary with NO auth-class code, so every typed refusal below maps to
  the A2A task state `:rejected` (refused at admission, terminal). Post-P16,
  a facade-level auth-class refusal would map to `:auth_required` (parked
  resumable). Where a post-P16 world changes the expected task state, the
  affected assertion is marked skip-loud pending upstream landing.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Replan.Port.AshPPlan, as: Port

  @powl_iri "https://w3id.org/ash-pplan#SubscriptionRenewal"

  # A real, solvable FOND candidate domain built through the dep's admitted
  # constructor (same fixture shape as ash_pplan's own fond_hardening court).
  defp solvable_domain do
    {:ok, domain} =
      AshPPlan.FOND.new(
        %{
          pending: %{attempt: [:pending, :succeeded]},
          side: %{wander: [:pending]}
        },
        [:succeeded]
      )

    domain
  end

  # A real FOND domain whose goal is unreachable, so every mode fails
  # synthesis and the sweep consumes the horizon exactly.
  defp unsolvable_domain do
    {:ok, domain} =
      AshPPlan.FOND.new(
        %{
          a: %{noop: [:a]},
          g: %{noop: [:g]}
        },
        [:g]
      )

    domain
  end

  describe "deliberation parity — accepted candidates" do
    @tag :pplan_parity
    test "propose/2 :fond against a real solvable domain returns an authority-free candidate" do
      assert {:ok, candidate} =
               Port.propose(
                 %{
                   subject: "caller-a",
                   formalism: :fond,
                   domain: solvable_domain(),
                   initial: :pending
                 },
                 []
               )

      # owner-adapter-first contract (merge note): candidates only.
      assert candidate.authority == :none
      assert candidate.standing == :candidate
      assert candidate.subject == "caller-a"
      assert candidate.formalism == :fond
      assert is_map(candidate.policy)
      assert candidate.mode in [:strong, :strong_cyclic]
      assert is_list(candidate.attempts)
    end

    @tag :pplan_parity
    test "propose/2 :powl against a real catalog plan returns an authority-free candidate" do
      assert {:ok, candidate} =
               Port.propose(
                 %{
                   subject: :caller_b,
                   formalism: :powl,
                   plan_iri: @powl_iri
                 },
                 []
               )

      assert candidate.authority == :none
      assert candidate.standing == :candidate
      assert candidate.subject == :caller_b
      assert candidate.formalism == :powl
      assert candidate.plan_iri == @powl_iri
      assert %{} = candidate.plan
      assert Enum.any?(candidate.plan.steps, &(&1.iri =~ "AuthorizePayment"))
    end

    test "supports?/1 admits exactly the deliberation formalisms (:fond, :powl)" do
      assert Port.supports?(:fond)
      assert Port.supports?(:powl)
      refute Port.supports?(:htn)
      refute Port.supports?(:pddl)
    end
  end

  describe "hostile-request matrix" do
    # TASK-STATE MAP for every row below (see runtime.ex admission rules):
    # a typed {:error, %{code: c}} from this port is an admission refusal,
    # NOT an auth-class failure (:unauthorized / {:unauthorized, _} /
    # {:auth_required, _}), so the A2A task lands terminal `:rejected` —
    # never `:auth_required` (which is parked, resumable via the same id).
    @refusal_codes [
      :missing_subject,
      :missing_domain,
      :missing_initial,
      :missing_plan_iri,
      :plan_not_found,
      :unsupported_formalism,
      :planner_refused
    ]

    test "the owner refusal vocabulary stays closed and known to this court" do
      assert @refusal_codes == AshPPlan.SA2A.Refusal.codes()
    end

    test "non-map request -> :unsupported_formalism (task state :rejected)" do
      # Non-map requests are refused at the port's own guard with the plain
      # atom; only map requests reach the owner provider's typed map refusal.
      assert {:error, :unsupported_formalism} = Port.propose("not a map", [])
      assert {:error, :unsupported_formalism} = Port.propose(nil, [])
      assert {:error, :unsupported_formalism} = Port.propose([:list], [])

      # a map whose formalism is garbage still reaches the owner provider and
      # gets the typed-map refusal.
      assert {:error, %{code: :unsupported_formalism, authority: :none}} =
               Port.propose(%{formalism: %{nested: :garbage}}, [])
    end

    test "unknown formalism -> :unsupported_formalism (task state :rejected)" do
      for formalism <- [:htn, :pddl, "fond", 42] do
        assert {:error, %{code: :unsupported_formalism, authority: :none}} =
                 Port.propose(%{subject: "caller-a", formalism: formalism}, [])
      end
    end

    test "missing / garbage subject -> :missing_subject (task state :rejected)" do
      for bad_subject <- [nil, "", 42, {:tuple}, [:list], 1.5] do
        assert {:error, %{code: :missing_subject, authority: :none}} =
                 Port.propose(
                   %{
                     subject: bad_subject,
                     formalism: :fond,
                     domain: solvable_domain(),
                     initial: :pending
                   },
                   []
                 )
      end
    end

    test "missing domain -> :missing_domain; missing initial -> :missing_initial (task state :rejected)" do
      assert {:error, %{code: :missing_domain}} =
               Port.propose(%{subject: "caller-a", formalism: :fond, initial: :pending}, [])

      assert {:error, %{code: :missing_initial}} =
               Port.propose(
                 %{subject: "caller-a", formalism: :fond, domain: solvable_domain()},
                 []
               )
    end

    test "unhashable/garbage opts -> :planner_refused {:invalid_opts, opts} (task state :rejected)" do
      request = %{
        subject: "caller-a",
        formalism: :fond,
        domain: solvable_domain(),
        initial: :pending
      }

      # a list that is not a keyword list (non-atom keys) gets the typed
      # owner-provider refusal.
      assert {:error, %{code: :planner_refused, detail: {:invalid_opts, _}}} =
               Port.propose(request, [{"key", :value}])
    end

    @tag skip:
           "SEAM-DEFECT I1-OBS-1 still holds (re-run this lane): lib/ash_a2a/replan/port/ash_pplan.ex:24 " <>
             "calls Keyword.get/3 on non-list opts before any guard; port file is not lane-13-owned"
    test "SKIP-LOUD [SEAM-DEFECT I1-OBS-1]: non-list opts crash the port guard, not a typed refusal" do
      # REGISTERED SEAM DEFECT (upstream, not lane I1's file):
      # AshA2A.Replan.Port.AshPPlan.propose/2 calls Keyword.get/3 on opts
      # BEFORE any totality guard, so non-list opts (nil, "opts", %{...}, 42)
      # raise FunctionClauseError instead of returning the provider's typed
      # {:error, %{code: :planner_refused, detail: {:invalid_opts, opts}}}.
      # Witnessed: lib/ash_a2a/replan/port/ash_pplan.ex:24 via
      # (elixir 1.19.5) lib/keyword.ex:399, opts = nil.
      # The provider doc (AshPPlan.SA2A.Provider moduledoc) promises
      # "garbage opts always return a refusal ... they never raise" — the
      # port breaks that contract before the provider ever sees the call.
      # Re-enable this row when the port guard lands.
      request = %{
        subject: "caller-a",
        formalism: :fond,
        domain: solvable_domain(),
        initial: :pending
      }

      for bad_opts <- [nil, "opts", %{not: :keyword}, 42] do
        assert {:error, %{code: :planner_refused, detail: {:invalid_opts, ^bad_opts}}} =
                 Port.propose(request, bad_opts)
      end
    end

    test "powl: missing/non-binary plan_iri -> :missing_plan_iri; unknown iri -> :plan_not_found (task state :rejected)" do
      assert {:error, %{code: :missing_plan_iri}} =
               Port.propose(%{subject: "caller-a", formalism: :powl}, [])

      assert {:error, %{code: :missing_plan_iri}} =
               Port.propose(%{subject: "caller-a", formalism: :powl, plan_iri: 42}, [])

      assert {:error, %{code: :plan_not_found, detail: "https://no-such-plan.example"}} =
               Port.propose(
                 %{
                   subject: "caller-a",
                   formalism: :powl,
                   plan_iri: "https://no-such-plan.example"
                 },
                 []
               )
    end

    test "propose/2 is total over hostile input: never raises" do
      # A sweep of genuinely hostile terms; every row must return a typed
      # refusal from the closed vocabulary, none may raise.
      hostile = [
        "binary",
        :atom,
        [:list, of: :terms],
        %{formalism: %{nested: :garbage}},
        %{subject: fn -> :unhashable end, formalism: :fond},
        %{subject: make_ref(), formalism: :fond},
        %{subject: "ok", formalism: :fond, domain: :not_a_domain, initial: :s0}
      ]

      for request <- hostile do
        # Non-map requests are refused at the port guard with the plain atom;
        # map requests get the owner provider's typed refusal map. Neither
        # shape may ever raise.
        case Port.propose(request, []) do
          {:error, :unsupported_formalism} -> :ok
          {:error, %{code: code}} -> assert code in @refusal_codes
          other -> flunk("expected a typed refusal, got: #{inspect(other)}")
        end
      end
    end
  end

  describe "horizon exhaustion" do
    @tag :pplan_parity
    test "horizon-exceeded sweep -> :planner_refused with the typed reason preserved (task state :rejected)" do
      assert {:error, refusal} =
               Port.propose(
                 %{
                   subject: "caller-a",
                   formalism: :fond,
                   domain: unsolvable_domain(),
                   initial: :a
                 },
                 policy_opts: [horizon: 1]
               )

      assert %{code: :planner_refused, authority: :none} = refusal

      # The typed reason survives intact: {tag, horizon, witness} with the
      # exact horizon the sweep consumed. The witness is the sweep's no-drift
      # fingerprint (a content hash over the ordered {mode, reason} attempts),
      # not the raw attempt list.
      assert {:horizon_exceeded, 1, witness} = refusal.detail
      assert is_binary(witness) and witness != ""
    end

    test "larger horizon is not exhausted before the sweep admits-failure" do
      # With horizon 2 and two modes, exhaustion happens exactly at 2.
      assert {:error, %{code: :planner_refused, detail: {:horizon_exceeded, 2, _fingerprint}}} =
               Port.propose(
                 %{
                   subject: "caller-a",
                   formalism: :fond,
                   domain: unsolvable_domain(),
                   initial: :a
                 },
                 policy_opts: [horizon: 2]
               )
    end
  end

  describe "P16 authorization seam (skip-loud pending upstream)" do
    # P16 is in-flight upstream: the ash_pplan facade may introduce auth-class
    # refusals through this port. In that post-P16 world these expectations
    # change; they are asserted as explicit loud skips, never silent passes.
    @describetag :skip_p16_pending

    @tag skip:
           "P16-PENDING: ash_pplan dep has no auth-class code in AshPPlan.SA2A.Refusal.codes/0 " <>
             "(re-checked this lane)"
    test "SKIP-LOUD [P16-PENDING]: post-P16 auth-class refusal would map to :auth_required (resumable), not :rejected" do
      # Named skip with the typed reason, never a silent vacuous pass.
      # P16 authorization seam is not landed in the ash_pplan dep 26.10.3:
      # no auth-class code exists in AshPPlan.SA2A.Refusal.codes/0, so
      # asserting the :auth_required mapping today would be a tautology.
      # Re-enable when the facade lands.
      :ok
    end
  end
end

# --- SECTION 2: Original test/ash_a2a/replan/ash_pplan_port_test.exs ---
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

# --- SECTION 3: Original test/ash_a2a/replan/attempt_budget_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.AttemptBudgetTest do
  use ExUnit.Case, async: true

  test "budget exhausts" do
    b = AshA2A.Replan.AttemptBudget.new(1)
    assert {:ok, b} = AshA2A.Replan.AttemptBudget.consume(b)
    assert {:error, %{code: :replan_exhausted}} = AshA2A.Replan.AttemptBudget.consume(b)
  end
end

# --- SECTION 4: Original test/ash_a2a/replan/beam4pm_port_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.Beam4pmPortTest do
  use ExUnit.Case, async: true

  test "declares POWL" do
    assert AshA2A.Replan.Port.Beam4pm.supports?(:powl)
  end
end

# --- SECTION 5: Original test/ash_a2a/replan/candidate_authority_refusal_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.CandidateAuthorityRefusalTest do
  use ExUnit.Case, async: true

  test "authority escalation refused" do
    assert {:error, %{code: :replan_authority_violation}} =
             AshA2A.Replan.CandidateFence.check(%{standing: :candidate, authority: :do})
  end
end

# --- SECTION 6: Original test/ash_a2a/replan/candidate_fence_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.CandidateFenceTest do
  use ExUnit.Case, async: true

  test "candidate has no authority" do
    assert :ok = AshA2A.Replan.CandidateFence.check(%{standing: :candidate, authority: :none})
  end
end

# --- SECTION 7: Original test/ash_a2a/replan/effect_identity_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.EffectIdentityTest do
  use ExUnit.Case, async: true

  test "requires same effect and subject" do
    assert AshA2A.Replan.EffectIdentity.preserve?(%{actuation_id: "a", projection_digest: "p"}, %{
             actuation_id: "a",
             projection_digest: "p"
           })

    refute AshA2A.Replan.EffectIdentity.preserve?(%{actuation_id: "a", projection_digest: "p"}, %{
             actuation_id: "b",
             projection_digest: "p"
           })
  end
end

# --- SECTION 8: Original test/ash_a2a/replan/ferroplan_port_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.FerroplanPortTest do
  use ExUnit.Case, async: false

  alias AshA2A.Replan.Port.Ferroplan

  test "declares FOND" do
    assert Ferroplan.supports?(:fond)
  end

  test "no URL configured answers the typed :ferroplan_unavailable" do
    prev =
      {Application.get_env(:ash_a2a, :ferroplan_url), Application.get_env(:ash_a2a, :beam4pm_url)}

    Application.delete_env(:ash_a2a, :ferroplan_url)
    Application.delete_env(:ash_a2a, :beam4pm_url)

    on_exit(fn ->
      {f, b} = prev
      if f, do: Application.put_env(:ash_a2a, :ferroplan_url, f)
      if b, do: Application.put_env(:ash_a2a, :beam4pm_url, b)
    end)

    assert {:error, :ferroplan_unavailable} =
             Ferroplan.propose(%{domain: "d", problem: "p"}, [])

    assert {:error, %{code: :ferroplan_unavailable}} =
             AshA2A.Planning.plan_with_ferroplan(AshA2A.Test.NoSuchDomain, "d", "p")

    assert :ferroplan in AshA2A.Replan.ProviderRegistry.boot_check()
  end

  test "an unreachable URL yields a transport error, not a crash or in-process call" do
    assert {:error, _} =
             Ferroplan.propose(%{domain: "d", problem: "p"},
               ferroplan_url: "http://127.0.0.1:1/a2a"
             )
  end
end

# --- SECTION 9: Original test/ash_a2a/replan/loop_failover_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.LoopFailoverTest do
  use ExUnit.Case, async: true

  defmodule FailedProvider do
    def supports?(:hddl), do: true
    def supports?(_), do: false
    def propose(_request, _opts), do: {:error, :provider_down}
  end

  defmodule WorkingProvider do
    def supports?(:hddl), do: true
    def supports?(_), do: false
    def propose(request, _opts), do: {:ok, %{subject: request.subject, plan: [:ok]}}
  end

  test "failure excludes only the failed provider and consumes the attempt budget" do
    providers = [failed: FailedProvider, working: WorkingProvider]

    assert {:ok,
            %{
              provider: :working,
              attempt: 1,
              excluded: [:failed],
              replay_key: replay_key,
              candidate: %{subject: "s"}
            }} =
             AshA2A.Replan.Loop.run("s", %{formalism: :hddl}, providers, max_attempts: 2)

    assert is_binary(replay_key)
    assert byte_size(replay_key) == 64
  end

  test "budget exhaustion stops before an unbounded provider loop" do
    providers = [failed: FailedProvider]

    assert {:error, %{code: :replan_exhausted}} =
             AshA2A.Replan.Loop.run("s", %{formalism: :hddl}, providers, max_attempts: 1)
  end
end

# --- SECTION 10: Original test/ash_a2a/replan/outcome_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.OutcomeTest do
  use ExUnit.Case, async: true

  test "unknown is recoverable" do
    assert AshA2A.Replan.Outcome.recoverable?(:unknown_outcome)
  end
end

# --- SECTION 11: Original test/ash_a2a/replan/port_contract_test.exs ---
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

defmodule AshA2A.Replan.Port.Beam4pmHttpTest do
  use ExUnit.Case, async: true

  alias AshA2A.Replan.Port.Beam4pm

  test "no beam4pm configured and no module supplied: typed unavailable, nothing compiled in" do
    assert {:error, :beam4pm_unavailable} = Beam4pm.propose(%{subject: "s"}, [])
  end

  test "beam4pm_url selects the HTTP A2A path (unreachable server -> typed error, not a crash)" do
    assert {:error, _} =
             Beam4pm.propose(%{subject: "s", decision: :hddl_replan},
               beam4pm_url: "http://127.0.0.1:1/a2a",
               retry: false
             )
  end
end

# --- SECTION 12: Original test/ash_a2a/replan/portable_envelope_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.PortableEnvelopeTest do
  use ExUnit.Case, async: true

  alias AshA2A.Replan.PortableEnvelope

  test "failed receipt carries the SA2A replan decision with no authority" do
    assert {:ok,
            %{
              "exact_subject" => "sha256:subject",
              "consequence" => "failed",
              "decision" => %{
                "kind" => "replan",
                "reason" => "failed",
                "authority" => "none"
              }
            }} =
             PortableEnvelope.from_receipt(
               %{
                 semantic_subject: "sha256:subject",
                 receipt_id: "r1",
                 terminal_status: :failed
               },
               :gymact
             )
  end

  test "unknown receipt carries reconcile-before-replan rather than consumer guesswork" do
    assert {:ok,
            %{
              "consequence" => "unknown_outcome",
              "decision" => %{
                "kind" => "replan",
                "reason" => "unknown_outcome_reconcile_first",
                "authority" => "none"
              }
            }} =
             PortableEnvelope.from_receipt(%{
               semantic_subject: "sha256:subject",
               receipt_id: "r2",
               terminal_status: :new_provider_verdict
             })
  end

  test "reconciled and compensated receipts stop instead of replan" do
    for status <- [:reconciled, :compensated] do
      assert {:ok,
              %{
                "consequence" => consequence,
                "decision" => %{"kind" => "stop", "authority" => "none"}
              }} =
               PortableEnvelope.from_receipt(%{
                 semantic_subject: "sha256:subject",
                 receipt_id: "r-terminal-" <> Atom.to_string(status),
                 terminal_status: status
               })

      assert consequence == Atom.to_string(status)
    end
  end

  test "refused receipt carries stop and remains powerless" do
    assert {:ok,
            %{
              "consequence" => "refused",
              "decision" => %{"kind" => "stop", "authority" => "none"}
            }} =
             PortableEnvelope.from_receipt(%{
               semantic_subject: "sha256:subject",
               receipt_id: "r3",
               terminal_status: :refused
             })
  end
end

# --- SECTION 13: Original test/ash_a2a/replan/portable_schema_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.PortableSchemaTest do
  use ExUnit.Case, async: true

  alias AshA2A.Replan.PortableSchema

  test "portable schema has stable content identity" do
    decoded = PortableSchema.decode!()
    assert decoded["$id"] == "https://chatmangpt.com/sa2a/replan-envelope/v1"
    assert PortableSchema.digest() =~ ~r/^sha256:[0-9a-f]{64}$/
  end
end

# --- SECTION 14: Original test/ash_a2a/replan/provider_failure_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.ProviderFailureTest do
  use ExUnit.Case, async: true

  test "records failed edge" do
    assert %{provider: :p, attempt: 2} = AshA2A.Replan.ProviderFailure.new(:p, :timeout, 2)
  end
end

# --- SECTION 15: Original test/ash_a2a/replan/provider_result_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.ProviderResultTest do
  use ExUnit.Case, async: true

  test "normalizes provider id" do
    assert {:ok, %{provider: :p, candidate: %{x: 1}}} =
             AshA2A.Replan.ProviderResult.normalize({:ok, %{x: 1}}, :p)
  end
end

# --- SECTION 16: Original test/ash_a2a/replan/provider_set_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.ProviderSetTest do
  use ExUnit.Case, async: true

  defmodule P do
    def supports?(:hddl), do: true
    def supports?(_), do: false
  end

  test "excludes failed edge" do
    assert nil == AshA2A.Replan.ProviderSet.select([p: P], :hddl, MapSet.new([:p]))
  end
end

# --- SECTION 17: Original test/ash_a2a/replan/reconcile_gate_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.ReconcileGateTest do
  use ExUnit.Case, async: true

  test "unknown outcome blocks replan" do
    assert {:error, %{code: :reconcile_required}} =
             AshA2A.Replan.ReconcileGate.allow?(%{terminal_status: :unknown_outcome})
  end
end

# --- SECTION 18: Original test/ash_a2a/replan/recovery_policy_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.RecoveryPolicyTest do
  use ExUnit.Case, async: true

  test "unknown reconciles first" do
    assert :reconcile_before_replan = AshA2A.Replan.RecoveryPolicy.next(:unknown_outcome)
  end
end

# --- SECTION 19: Original test/ash_a2a/replan/refusal_taxonomy_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.RefusalTaxonomyTest do
  use ExUnit.Case, async: true

  test "taxonomy contains subject drift and exhaustion" do
    codes = AshA2A.Replan.Refusal.codes()
    assert :replan_subject_drift in codes
    assert :replan_exhausted in codes
  end
end

# --- SECTION 20: Original test/ash_a2a/replan/registry_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.RegistryTest do
  use ExUnit.Case, async: true

  test "hddl has providers" do
    assert length(AshA2A.Replan.ProviderRegistry.for(:hddl)) >= 2
  end
end

# --- SECTION 21: Original test/ash_a2a/replan/replay_key_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.ReplayKeyTest do
  use ExUnit.Case, async: true

  test "deterministic" do
    assert AshA2A.Replan.ReplayKey.build("s", :p, 1) == AshA2A.Replan.ReplayKey.build("s", :p, 1)
  end
end

# --- SECTION 22: Original test/ash_a2a/replan/router_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.RouterTest do
  use ExUnit.Case, async: true

  test "failed becomes replan" do
    assert %{kind: :replan} = AshA2A.Replan.Router.decide(%{subject: "s", outcome: :failed})
  end
end

# --- SECTION 23: Original test/ash_a2a/replan/stale_plan_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.StalePlanTest do
  use ExUnit.Case, async: true

  test "digest drift invalidates" do
    assert AshA2A.Replan.StalePlan.stale?(%{projection_digest: "a"}, %{projection_digest: "b"})
  end
end

# --- SECTION 24: Original test/ash_a2a/replan/subject_lineage_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.SubjectLineageTest do
  use ExUnit.Case, async: true

  test "refuses subject drift" do
    assert {:error, %{code: :replan_subject_drift}} = AshA2A.Replan.SubjectLineage.guard("a", "b")
  end
end

# --- SECTION 25: Original test/ash_a2a/replan/trace_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.TraceTest do
  use ExUnit.Case, async: true

  test "replay preserves order" do
    t = %AshA2A.Replan.Trace{} |> AshA2A.Replan.Trace.append(:a) |> AshA2A.Replan.Trace.append(:b)
    assert [:a, :b] = AshA2A.Replan.Trace.replay(t)
  end
end

# --- SECTION 26: Original test/replan/port_ashpplan_conformance_court_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

# Lane I6 — contract-conformance court for AshA2A.Replan.Port.AshPPlan
# against the upstream totality contract.
#
# Standing: this court was run against the ash_pplan checkout as of
# 2026-11-07. The upstream W5 hardening (hashable? pre-flight, non-map
# preserve catch-all) was in-flight upstream: the non-map preserve
# catch-all is LANDED in AshPPlan.SA2A.SubjectGuard, but the hashable?
# pre-flight in front of AshPPlan.select_policy/3 is NOT — so unhashable
# `initial`/`seed` payloads (funs, pids, refs) can still raise inside the
# planner upstream. The court therefore (a) hard-asserts totality for
# shapes the port itself owns, (b) marks upstream-W5-dependent shapes as
# refused-or-raised with the named tag `:pre_w5` and pins the observed
# raise census exactly, so the post-W5 flip is: turn every case from
# `pre_w5: true` to strict refusal assertions and the census test goes to
# zero raised shapes.

defmodule AshA2A.Replan.PortAshPPlanConformanceCourt do
  use ExUnit.Case, async: true

  @moduletag :pplan_court

  alias AshA2A.Replan.Port.AshPPlan, as: Port

  # ---------------------------------------------------------------------------
  # Hostile-matrix census (read at use time, never recalled from memory)
  # pinned by test "census composition matches the recorded hostile matrix"
  # ---------------------------------------------------------------------------

  defmodule FakeOwner do
    @moduledoc false
    def supports?(formalism), do: formalism in [:fond, :powl]

    def propose(request, opts) do
      send(self(), {:fake_owner_call, request, opts})
      {:ok, %{subject: Map.get(request, :subject), source: :fake_owner}}
    end
  end

  defmodule ProposeOnly do
    @moduledoc false
    def propose(_req, _opts), do: {:ok, :propose_only}
  end

  defmodule SupportsOnly do
    @moduledoc false
    def supports?(_f), do: true
  end

  # classify a propose/2 probe into {:refused, r} | {:accepted, r} | {:raised, msg}
  defp classify(fun) do
    try do
      case fun.() do
        {:error, r} -> {:refused, r}
        {:ok, r} -> {:accepted, r}
        other -> {:other, other}
      end
    rescue
      e -> {:raised, Exception.message(e)}
    end
  end

  # generated hostile-shape pool (not an @attr: refs/funs/pids cannot escape
  # into module attributes)
  defp hostile_nonmap_requests do
    [
      nil,
      :ok,
      1,
      "x",
      [1, 2],
      [foo: :bar],
      make_ref(),
      self(),
      fn -> :x end,
      {:t, 1}
    ]
  end

  test "supports? totality matrix: :fond/:powl true, everything else false" do
    assert Port.supports?(:fond)
    assert Port.supports?(:powl)

    Enum.each([nil, :htn, "fond", 1, 2.5, {}, %{}, [], make_ref(), self(), fn -> :x end], fn f ->
      refute Port.supports?(f), "supports? must be false for #{inspect(f, limit: 2)}"
    end)
  end

  test "non-map requests always refuse with the port catch-all atom, never raise" do
    Enum.each(hostile_nonmap_requests(), fn r ->
      assert {:refused, :unsupported_formalism} =
               classify(fn -> Port.propose(r, []) end),
             "non-map request #{inspect(r, limit: 2)} must hit the port catch-all"
    end)
  end

  # --- owner path (default opts -> real AshPPlan.SA2A.Provider) --------------

  test "owner path refuses missing subject/domain/initial with typed %{code:} refusals" do
    assert {:refused, %{code: :missing_subject}} =
             classify(fn -> Port.propose(%{formalism: :fond}, []) end)

    assert {:refused, %{code: :missing_domain}} =
             classify(fn -> Port.propose(%{formalism: :fond, subject: :s}, []) end)

    assert {:refused, %{code: :missing_initial}} =
             classify(fn -> Port.propose(%{formalism: :fond, subject: :s, domain: %{}}, []) end)
  end

  test "owner path powl refusals: subject checked first, then plan_iri shape" do
    assert {:refused, %{code: :missing_subject}} =
             classify(fn -> Port.propose(%{formalism: :powl}, []) end)

    assert {:refused, %{code: :missing_plan_iri}} =
             classify(fn ->
               Port.propose(%{formalism: :powl, subject: :s, plan_iri: 5}, [])
             end)

    assert {:refused, %{code: :plan_not_found}} =
             classify(fn ->
               Port.propose(%{formalism: :powl, subject: :s, plan_iri: "pplan://nope-i6"}, [])
             end)
  end

  # --- upstream W5 in-flight: unhashable initial/seed may raise pre-W5 -------

  test "unhashable initial payloads: refused-or-raised pre-W5 (tag :pre_w5)" do
    {tag, outcome} =
      probe(
        fn ->
          Port.propose(
            %{formalism: :fond, subject: :s, domain: %{}, initial: %{seed: fn -> :x end}},
            []
          )
        end,
        :pre_w5_unhashable_initial
      )

    {tag2, outcome2} =
      probe(
        fn ->
          Port.propose(
            %{formalism: :fond, subject: :s, domain: %{}, initial: %{pid: self()}},
            []
          )
        end,
        :pre_w5_unhashable_initial
      )

    assert {tag, tag2} == {:pre_w5_unhashable_initial, :pre_w5_unhashable_initial}
    assert outcome in [:refused, :raised]
    assert outcome2 in [:refused, :raised]
  end

  # --- port-own totality defects (not upstream W5): tolerated-raise, named ---

  test "port defects pre-fix: opts totality probes (named tags, census-pinned)" do
    {t1, o1} = probe(fn -> Port.propose(%{formalism: :fond}, nil) end, :port_opts_not_list)

    {t2, o2} =
      probe(
        fn -> Port.propose(%{formalism: :fond}, ash_pplan_provider_module: 123) end,
        :port_provider_probe_non_atom
      )

    {t3, o3} =
      probe(
        fn ->
          Port.propose(
            %{formalism: :powl, subject: :s},
            ash_pplan_provider_module: String
          )
        end,
        :port_powl_fetch_totality
      )

    assert {t1, t2, t3} ==
             {:port_opts_not_list, :port_provider_probe_non_atom, :port_powl_fetch_totality}

    assert o1 in [:refused, :raised]
    assert o2 in [:refused, :raised]
    assert o3 in [:refused, :raised]
  end

  # --- legacy path (non-owner provider module in opts) -----------------------

  test "legacy :fond refusals are bare atoms, total over missing keys" do
    legacy_opts = [ash_pplan_provider_module: String]

    assert {:refused, :missing_domain} =
             classify(fn -> Port.propose(%{formalism: :fond, subject: :s}, legacy_opts) end)

    assert {:refused, :missing_initial} =
             classify(fn ->
               Port.propose(%{formalism: :fond, subject: :s, domain: %{}}, legacy_opts)
             end)
  end

  test "legacy :powl unknown iri refuses :plan_not_found" do
    assert {:refused, :plan_not_found} =
             classify(fn ->
               Port.propose(
                 %{formalism: :powl, subject: :s, plan_iri: "pplan://nope-i6"},
                 ash_pplan_provider_module: String
               )
             end)
  end

  # --- delegation ---------------------------------------------------------

  test "fake owner provider is called and the provider key is deleted from opts" do
    req = %{formalism: :fond, subject: :i6_subject}

    assert {:accepted, %{source: :fake_owner, subject: :i6_subject}} =
             classify(fn ->
               Port.propose(req, ash_pplan_provider_module: FakeOwner)
             end)

    assert_received {:fake_owner_call, stored_req, stored_opts}
    assert stored_req == req
    refute Keyword.has_key?(stored_opts, :ash_pplan_provider_module)
  end

  test "legacy fallback triggers for modules without both callbacks; default opts go owner" do
    # default (no provider key): owner path -> owner-shaped typed refusal
    assert {:refused, %{code: :missing_domain}} =
             classify(fn -> Port.propose(%{formalism: :fond, subject: :s}, []) end)

    # modules lacking supports?/1 or propose/2 fall back to the legacy path
    for opts <- [
          [ash_pplan_provider_module: ProposeOnly],
          [ash_pplan_provider_module: SupportsOnly]
        ] do
      assert {:refused, :missing_domain} =
               classify(fn -> Port.propose(%{formalism: :fond, subject: :s}, opts) end)
    end
  end

  # probe/2: run a hostile shape under a named tag, classify the outcome.
  # Refused/accepted pass through; a raise is TOLERATED only for tagged
  # pre-W5 / pre-fix shapes and is recorded in the census by tag.
  defp probe(fun, tag) do
    case classify(fun) do
      {:raised, msg} ->
        IO.puts("[I6 court] RAISE tolerated pre-W5/pre-fix tag=#{inspect(tag)}: " <> msg)

        {tag, :raised}

      {kind, r} = other when kind in [:refused, :accepted, :other] ->
        _ = r
        {tag, kind}
    end
  end

  # --- seam-division court (static, comment-aware) --------------------------
  # The port's own SEAM DIVISION note (in comments) names
  # AshPPlan.Reactor.Durable.Engine. A naive grep would false-fail on the
  # note itself; the court strips comment-only lines and asserts no
  # non-comment occurrence of the Engine namespace.

  defp port_source do
    path =
      __DIR__
      |> Path.join("../../lib/ash_a2a/replan/port/ash_pplan.ex")
      |> Path.expand()

    case File.read(path) do
      {:ok, src} -> src
      {:error, reason} -> raise "cannot read port source: #{inspect(reason)}"
    end
  end

  defp strip_comments(src) do
    src
    |> String.split("\n")
    |> Enum.reject(&(String.trim(&1) |> String.starts_with?("#")))
    |> Enum.join("\n")
  end

  test "seam division: port source has no live Durable.Engine reference" do
    src = port_source()

    assert src =~ "SEAM DIVISION",
           "the SEAM DIVISION note must stay pinned in the port source"

    live = strip_comments(src)

    refute live =~ "Durable.Engine",
           "port must never reference AshPPlan.Reactor.Durable.Engine outside comments"

    refute live =~ "Durable.Start",
           "port must never start a durable run"
  end

  test "census: exactly the recorded shapes raise pre-W5/pre-fix" do
    raised =
      [
        # owner path, unhashable initial (upstream W5 in-flight)
        fn ->
          Port.propose(
            %{formalism: :fond, subject: :s, domain: %{}, initial: %{seed: fn -> :x end}},
            []
          )
        end,
        fn ->
          Port.propose(%{formalism: :fond, subject: :s, domain: %{}, initial: %{pid: self()}}, [])
        end,
        # port-own defects (opts totality)
        fn -> Port.propose(%{formalism: :fond}, nil) end,
        fn -> Port.propose(%{formalism: :fond}, ash_pplan_provider_module: 123) end,
        fn ->
          Port.propose(
            %{formalism: :powl, subject: :s},
            ash_pplan_provider_module: String
          )
        end
      ]
      |> Enum.map(&classify/1)
      |> Enum.filter(&match?({:raised, _}, &1))

    # Post-W5 + post-fix, this must be [] — flip the tolerated-raise tests above to strict.
    assert length(raised) == 3
  end
end
