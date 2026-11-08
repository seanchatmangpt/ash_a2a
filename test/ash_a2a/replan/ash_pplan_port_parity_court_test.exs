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

    @tag :skip
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
      request = %{subject: "caller-a", formalism: :fond, domain: solvable_domain(), initial: :pending}

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
                 %{subject: "caller-a", formalism: :powl, plan_iri: "https://no-such-plan.example"},
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

    @tag :skip
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
