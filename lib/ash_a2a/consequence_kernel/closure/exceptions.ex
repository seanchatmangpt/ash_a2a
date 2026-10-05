# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.Closure.Exceptions do
  @moduledoc """
  Typed exceptions to the kernel-only-DO closure (`AshA2A.ConsequenceKernel.ClosureCourt`).

  An exception is EXACT: one caller MFA, one callee (or one dynamic site), one class, one
  reason and the court (test file) that proves the exception is fenced. Nothing is matched by
  prefix except the `:fixture_effect` class (test-fixture resources that are the subject of a
  court, not production callers). The court also refuses a STALE exception (declared, no longer
  observed) so a dead edge cannot stay listed after its removal.

  Classes:

    * `:legacy_observe`      -- live observation path; `Dispatcher.dispatch_observe/5` refuses a
      consequence-bearing skill (sole-DO anchor gate), so it cannot actuate.
    * `:correlation_anchor`  -- `CommandBus` puts the BRCE anchor as correlation evidence for the
      kernel dispatch inversion; the anchor is not authority and cannot admit DO alone.
    * `:c2_control_plane`    -- C2 control plane hands an effect + certificate to an OUT-OF-BEAM
      actuator client; no in-BEAM effector runs on that path.
    * `:court_probe`         -- a court/verifier that deliberately calls the direct path to prove
      it is refused.
    * `:behaviour_dispatch`  -- dynamic call through an injected behaviour module (store, broker,
      client); the behaviour surface cannot name a DO entry.
    * `:on_cancel_mfa`       -- user-declared `on_cancel` hook MFA (no DO authority, runs after
      cancellation; DO entries still refuse outside the kernel fence).
    * `:dead_in_beam_actuator` -- `C2.Actuator` in-BEAM effector: zero non-test callers.
    * `:fixture_effect`      -- Ash effects performed by court fixture resources (only when
      generated inside a real Spark resource/domain, never by a bare fixture-named module).
    * `:callback_dispatch`   -- configured callback/behaviour dynamic site outside the DO-adjacent
      modules with a DO-shaped name (`apply/N`, `execute`, `put`, ...).
    * `:fenced_second_ingress` -- a verified second ingress (e.g. `AshA2A.Executor`) that crosses
      the sole-DO fence itself with the identical gate sequence (`BrceAnchor.take/0` ->
      `CapabilityRelease.guard/2` -> `BrceAnchor.admit/2` -> W4 `DispatcherFence`) before any Ash
      call; the court proves an unanchored consequence-bearing dispatch is refused pre-Ash.
  """

  @type edge :: %{
          id: String.t(),
          class: atom(),
          caller: String.t(),
          callee: String.t(),
          reason: String.t(),
          court: String.t()
        }

  @doc "Resolved-edge exceptions: caller MFA string, callee `Module.fun/arity` string."
  @spec edges() :: [edge()]
  def edges do
    [
      %{
        id: "agent-legacy-observe",
        class: :legacy_observe,
        caller: "AshA2A.Agent.dispatch_skill/5",
        callee: "AshA2A.Dispatcher.dispatch_observe/5",
        reason:
          "live observe path; dispatch_observe enters DispatcherFence and sets observation_only, " <>
            "the sole-DO anchor gate refuses a consequence-bearing skill",
        court: "test/ash_a2a/c1_closure/closure_court_test.exs"
      },
      %{
        id: "command-bus-anchor",
        class: :correlation_anchor,
        caller: "AshA2A.CommandBus.dispatch_with_ocel_correlation/5",
        callee: "AshA2A.BrceAnchor.put/1",
        reason:
          "BRCE anchor is correlation evidence for W4 DispatchInversion, not authority " <>
            "(Dispatcher refuses without DispatcherFence)",
        court: "test/ash_a2a/rfc004_fence_test.exs"
      },
      %{
        id: "c2-remote-actuator",
        class: :c2_control_plane,
        caller: "AshA2A.C2.ActuationPipeline.execute/4",
        callee: "AshA2A.C2.ActuatorClient.execute/4",
        reason: "control plane delegates to an independent out-of-BEAM actuator",
        court: "test/ash_a2a/c2/architecture_closure_test.exs"
      },
      %{
        id: "verifier-sole-do-probe",
        class: :court_probe,
        caller: "AshA2A.ArchitectureVerifier.check_sole_do_fence_refuses_unanchored_dispatch/0",
        callee: "AshA2A.Dispatcher.dispatch/3",
        reason: "probe proving an unanchored direct dispatch is refused",
        court: "test/ash_a2a/rfc004_fence_test.exs"
      },
      %{
        id: "brce-court-direct-dispatch",
        class: :court_probe,
        caller: "AshA2A.Chicago.Courts.Brce.direct_dispatch/3",
        callee: "AshA2A.Dispatcher.dispatch/3",
        reason: "BRCE court stimulus: direct dispatch must be refused",
        court: "test/ash_a2a/chicago/brce_gate7_test.exs"
      },
      %{
        id: "brce-court-direct-observe",
        class: :court_probe,
        caller: "AshA2A.Chicago.Courts.Brce.direct_observe/2",
        callee: "AshA2A.Dispatcher.dispatch/3",
        reason: "BRCE court stimulus: direct dispatch of an observe skill",
        court: "test/ash_a2a/chicago/brce_gate7_test.exs"
      },
      %{
        id: "federated-bypass-fixture",
        class: :court_probe,
        caller: "AshA2A.Chicago.Fixtures.FederatedDelegation.bypass_peer_b/2",
        callee: "AshA2A.Dispatcher.dispatch/5",
        reason: "federated-delegation court fixture: bypass:true is the negative stimulus",
        court: "test/ash_a2a/chicago/federated_delegation_test.exs"
      },
      %{
        id: "executor-run-create",
        class: :fenced_second_ingress,
        caller: "AshA2A.Executor.run_create/4",
        callee: "Ash.create/2",
        reason:
          "verified second ingress; crosses the sole-DO fence itself (BrceAnchor.take -> " <>
            "CapabilityRelease.guard -> BrceAnchor.admit -> W4 DispatcherFence) before any Ash call",
        court: "test/ash_a2a_zach_courts_test.exs"
      },
      %{
        id: "executor-run-update",
        class: :fenced_second_ingress,
        caller: "AshA2A.Executor.run_update/4",
        callee: "Ash.update/2",
        reason:
          "verified second ingress; crosses the sole-DO fence itself (BrceAnchor.take -> " <>
            "CapabilityRelease.guard -> BrceAnchor.admit -> W4 DispatcherFence) before any Ash call",
        court: "test/ash_a2a_zach_courts_test.exs"
      },
      %{
        id: "executor-run-destroy",
        class: :fenced_second_ingress,
        caller: "AshA2A.Executor.run_destroy/4",
        callee: "Ash.destroy/2",
        reason:
          "verified second ingress; crosses the sole-DO fence itself (BrceAnchor.take -> " <>
            "CapabilityRelease.guard -> BrceAnchor.admit -> W4 DispatcherFence) before any Ash call",
        court: "test/ash_a2a_zach_courts_test.exs"
      },
      %{
        id: "executor-run-generic",
        class: :fenced_second_ingress,
        caller: "AshA2A.Executor.run_generic/4",
        callee: "Ash.run_action/2",
        reason:
          "verified second ingress; crosses the sole-DO fence itself (BrceAnchor.take -> " <>
            "CapabilityRelease.guard -> BrceAnchor.admit -> W4 DispatcherFence) before any Ash call",
        court: "test/ash_a2a_zach_courts_test.exs"
      }
    ]
  end

  @doc "Dynamic-site exceptions (caller MFA string, site string as printed by `Chicago.Closure`)."
  @spec dynamic_sites() :: [map()]
  def dynamic_sites do
    bus = "AshA2A.CommandBus"

    bus_sites =
      for {fun, site} <- [
            {"claim_actuation/6", "?:claim_actuation/3"},
            {"claim_receipt/3", "?:claim/2"},
            {"commit_actuation_once/4", "?:commit_actuation/3"},
            {"commit_once/3", "?:commit/2"},
            {"confirm_execution/5", "?:confirm_claim/3"},
            {"mark_standing/2", "?:durable?/0"},
            {"release_actuation/5", "?:release_actuation/2"},
            {"standing_with_broker/3", "?:granted?/3"},
            {"verify_with_broker/3", "?:verify/2"}
          ] do
        dyn(
          "command-bus-#{fun}-#{site}",
          :behaviour_dispatch,
          "#{bus}.#{fun}",
          site,
          "injected claim/receipt/broker behaviour module",
          "test/ash_a2a/command_bus_test.exs"
        )
      end

    # Non-DO-adjacent modules with a DO-shaped (fully dynamic / DO-named) call site. Each is a
    # configured-callback or behaviour dispatch enumerated so a NEW site is reviewed, not assumed.
    callback_sites =
      for {caller, site} <- [
            {"AshA2A.CallbackRegistry.invoke/3", "apply/3"},
            {"AshA2A.Chicago.Bench.B11Wire.start_listener/1", "apply/3"},
            {"AshA2A.Cluster.Checkpoint.land/4", "?:put/2"},
            {"AshA2A.Cluster.Handover.rehydrate_one/3", "?:put/2"},
            {"AshA2A.Eval.Scorers.apply_custom/4", "apply/3"},
            {"AshA2A.Enterprise.Pipeline.budget_check/3", "apply/3"},
            {"AshA2A.Execution.PPlan.resolve_value/1", "apply/3"},
            {"AshA2A.Chicago.Courts.Shacl.run/1", "apply/3"},
            {"AshA2A.Chicago.Courts.Shex.run/1", "apply/3"},
            {"AshA2A.Chicago.Fixtures.EnvelopeNegotiationTransport.Http.start_listener/1",
             "apply/3"},
            {"AshA2A.ConsequenceKernel.PreparedEffectStore.call/3", "apply/3"},
            {"AshA2A.ConsequenceKernel.Runtime.StoreHandle.call/3", "apply/3"},
            {"AshA2A.ConsequenceKernel.W5.ClaimProtocol.claim/3", "?:put/2"},
            {"AshA2A.Durability.DurableServer.invoke/2", "apply/3"},
            {"AshA2A.Protocol.Agent.Runtime.run_cancel/2", "apply/3"},
            {"AshA2A.Protocol.Agent.State.put_task/2", "?:put/2"},
            {"AshA2A.Protocol.Plug.call_authorizer/4", "apply/3"},
            {"AshA2A.ReceiptOutbox.safe/3", "apply/3"},
            {"AshA2A.Replan.Port.AshPPlan.legacy_propose/2", "apply/3"},
            {"AshA2A.Replan.Port.Beam4pm.propose/2", "apply/3"},
            {"AshA2A.Replan.Port.Ferroplan.propose/2", "apply/3"},
            {"AshA2A.Semantic.Conformance.run_requirement/1", "apply/3"},
            {"AshA2A.Telemetry.Metrics.metrics/0", "apply/3"},
            {"AshA2A.Topology.Group.invoke/2", "apply/3"},
            {"AshA2A.Topology.Presence.invoke/3", "apply/3"}
          ] do
        dyn(
          "callback-#{caller}-#{site}",
          :callback_dispatch,
          caller,
          site,
          "configured callback/behaviour dispatch outside the DO-adjacent modules; enumerated " <>
            "so a new DO-shaped dynamic site is reviewed",
          "test/ash_a2a/c1_closure/closure_court_test.exs"
        )
      end

    callback_sites ++
      [
        dyn(
          "agent-receipt-store",
          :behaviour_dispatch,
          "AshA2A.Agent.fetch_continuation_receipt/2",
          "?:fetch/2",
          "receipt store behaviour from CommandBus.default_store/0",
          "test/ash_a2a/command_bus_test.exs"
        ),
        dyn(
          "agent-on-cancel",
          :on_cancel_mfa,
          "AshA2A.Agent.invoke_on_cancel_hook/5",
          "apply/3",
          "user on_cancel MFA/module hook, post-cancel, no DO authority",
          "test/ash_a2a/c1_closure/closure_court_test.exs"
        ),
        dyn(
          "c2-actuator-claim",
          :dead_in_beam_actuator,
          "AshA2A.C2.Actuator.execute/5",
          "?:claim/2",
          "in-BEAM actuator has no non-test caller",
          "test/ash_a2a/c2/architecture_closure_test.exs"
        ),
        dyn(
          "c2-actuator-complete",
          :dead_in_beam_actuator,
          "AshA2A.C2.Actuator.execute/5",
          "?:complete/2",
          "in-BEAM actuator has no non-test caller",
          "test/ash_a2a/c2/architecture_closure_test.exs"
        ),
        dyn(
          "c2-actuator-perform",
          :dead_in_beam_actuator,
          "AshA2A.C2.Actuator.execute/5",
          "?:perform/1",
          "in-BEAM actuator has no non-test caller",
          "test/ash_a2a/c2/architecture_closure_test.exs"
        ),
        dyn(
          "c2-actuator-client",
          :behaviour_dispatch,
          "AshA2A.C2.ActuatorClient.execute/4",
          "?:execute/3",
          "actuator client behaviour (Remote/Framed, out of BEAM)",
          "test/ash_a2a/c2/architecture_closure_test.exs"
        ),
        dyn(
          "c2-authority-client",
          :behaviour_dispatch,
          "AshA2A.C2.AuthorityClient.authorize/3",
          "?:authorize/2",
          "authority client behaviour (no actuation)",
          "test/ash_a2a/c2/architecture_closure_test.exs"
        ),
        dyn(
          "c2-authority-admit",
          :behaviour_dispatch,
          "AshA2A.C2.AuthorityService.authorize/3",
          "?:admit/2",
          "authority policy behaviour (no actuation)",
          "test/ash_a2a/c2/architecture_closure_test.exs"
        ),
        dyn(
          "c2-authority-issue",
          :behaviour_dispatch,
          "AshA2A.C2.AuthorityService.authorize/3",
          "?:issue/2",
          "certificate issuer behaviour (no actuation)",
          "test/ash_a2a/c2/architecture_closure_test.exs"
        )
      ] ++ bus_sites
  end

  defp dyn(id, class, caller, site, reason, court),
    do: %{id: id, class: class, caller: caller, site: site, reason: reason, court: court}

  @doc "Module-name prefixes of court fixture resources allowed to perform Ash effects."
  @spec fixture_prefixes() :: [String.t()]
  def fixture_prefixes,
    do: ["AshA2A.Chicago.Fixtures", "AshA2A.Test.Fixture", "AshA2A.ArchitectureVerifier.Fixture"]

  @doc "Modules whose dynamic call sites must each be an enumerated exception."
  @spec dynamic_sensitive_prefixes() :: [String.t()]
  def dynamic_sensitive_prefixes,
    do: [
      "AshA2A.Agent",
      "AshA2A.CommandBus",
      "AshA2A.Dispatcher",
      "AshA2A.BrceAnchor",
      "AshA2A.C2"
    ]
end
