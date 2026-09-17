defmodule AshA2A.Chicago.Courts.CrashReconciliation do
  @moduledoc """
  `SA2A-CHAOS` -- Crash & Reconciliation, Idempotency / Replay Protection,
  chaos subset and Benchmark B10 (RFC-SA2A-002 §70, §71, §94, §96).

  Every stimulus drives the real `AshA2A.CommandBus.run/4` over a real
  consequence-bearing Ash action (`AshA2A.Chicago.Fixtures.ChaosReconciliation.Effect`)
  with the real durable `AshA2A.ReceiptStore.Ekv` (on-disk EKV) and the real
  filesystem `AshA2A.ReceiptOutbox`. Faults change the environment around
  those components only (§10): the executing process is killed with `:kill`
  at a real CommandBus boundary event, inside the external call, or after an
  actuator timeout; the EKV tree is killed and restarted over the same data
  dir; a journal file is torn. Nothing in the path is replaced.

  Post-state is read by independent readers: the external ledger through
  `Ash.read!/2`, raw journal files and raw EKV entries
  (`Environment.raw_evidence/2`), and the durable-evidence classifier
  `AshA2A.Reconciliation`, whose telemetry the independent OCEL consumer uses
  to corroborate each verdict.

  Crash injection at a boundary event relies on `:telemetry` dispatching the
  already-attached observer before the crash handler; the court verifies that
  on the live node first and reports every falsifier `BLOCKED` otherwise.
  """

  use AshA2A.Chicago.Court

  alias AshA2A.{CommandBus, Identity, Receipt, Reconciliation}
  alias AshA2A.Chicago.{Context, Falsifier, Result}
  alias AshA2A.Chicago.Fixtures.ChaosReconciliation.Environment, as: Env
  alias AshA2A.Chicago.Ocel.Mapping

  @court "SA2A-CHAOS"

  @claim [:ash_a2a, :command_bus, :claim]
  @prepare [:ash_a2a, :command_bus, :prepare]
  @actuate_start [:ash_a2a, :command_bus, :actuate, :start]
  @actuate_stop [:ash_a2a, :command_bus, :actuate, :stop]
  @commit [:ash_a2a, :command_bus, :commit]

  # A stalled external call (the crash/timeout lands while it is in progress).
  @stall_ms 30_000

  @impl true
  def id, do: @court
  @impl true
  def title, do: "Crash & reconciliation, idempotency / replay protection, chaos, B10"
  @impl true
  def gate, do: nil
  @impl true
  def profile, do: :do
  @impl true
  def rfc_sections, do: ["§70", "§71", "§94", "§96", "§100"]

  @impl true
  def ocel_mappings do
    for {suffix, activity} <- [
          classified: "reconciliation.classified",
          reconciled: "reconciliation.reconciled",
          compensated: "reconciliation.compensated"
        ] do
      Mapping.new!(
        event: [:ash_a2a, :reconciliation, suffix],
        activity: activity,
        source: __MODULE__,
        objects: fn _m, meta ->
          [
            {"command", meta[:command_id], "command"},
            {"receipt", meta[:receipt_id], "receipt"},
            {"receipt", meta[:compensation_receipt_id], "compensation"}
          ]
        end,
        attributes: fn _m, meta ->
          Map.take(meta, [
            :label,
            :state,
            :before_state,
            :source,
            :receipt_status,
            :resolved_as,
            :durable_in_primary,
            :unreadable_outbox_entries,
            :outcome,
            :drained_committed,
            :drained_remaining,
            :code
          ])
        end
      )
    end
  end

  # --- declarations ---------------------------------------------------------------

  @impl true
  def falsifiers do
    [
      negative(1,
        invariant:
          "A crash before receipt preparation leaves no consequence and is classified not_attempted; no later actuation lacks a prepared anchor",
        stimulus:
          "CommandBus.run killed at brce.claim(execute); EKV killed+restarted; classify; reconcile(probe); resubmit same command",
        boundary: "CommandBus prepare_receipt_anchor before actuate + AshA2A.Reconciliation",
        forbidden_outcome:
          "external effect without anchor, a repeated effect, or a post-crash state other than not_attempted",
        attempt_evidence:
          "brce.claim(execute) then reconciliation.classified(post_crash) and a second brce.admission",
        survival_evidence:
          "ledger rows > 0 after crash or > 1 final; classified(post_crash) state != not_attempted; actuation not preceded by prepare",
        guard:
          "CommandBus.execute_claimed/9 prepare-before-actuate; Reconciliation.state/2 no-evidence clause",
        failure_class: :receipt_failure,
        attempt_predicate:
          {:all,
           [
             {:observed, "brce.claim", %{"outcome" => "execute"}},
             {:observed, "reconciliation.classified", %{"label" => "post_crash"}},
             {:count, "brce.admission", :gte, 2}
           ]},
        outcome_predicate:
          {:any,
           [
             {:not,
              {:observed, "reconciliation.classified",
               %{"label" => "post_crash", "state" => "not_attempted"}}},
             {:not, {:precedes, "brce.prepare", "brce.actuate.start", "command"}},
             {:count, "brce.actuate.start", :gte, 2}
           ]}
      ),
      negative(2,
        invariant:
          "A crash after preparation / before the external call is prepared_unknown_outcome, never actuated on resubmission, and reconciles as not executed",
        stimulus:
          "CommandBus.run killed at brce.prepare(prepared); EKV killed+restarted; classify; reconcile(probe); resubmit",
        boundary: "ReceiptOutbox pending anchor + ReceiptStore claim/replay + Reconciliation",
        forbidden_outcome:
          "any actuation or external effect, or a post-crash/final state other than prepared_unknown_outcome/reconciled",
        attempt_evidence:
          "brce.prepare(prepared), reconciliation.classified(post_crash), reconciliation.reconciled(recovery), second admission",
        survival_evidence:
          "brce.actuate.start observed; ledger rows > 0; classified states differ from prepared_unknown_outcome -> reconciled(not_executed)",
        guard:
          "ReceiptOutbox.reconcile pending commit + ReceiptStore replay of the pending anchor",
        failure_class: :replay_failure,
        attempt_predicate:
          {:all,
           [
             {:observed, "brce.prepare", %{"outcome" => "prepared"}},
             {:observed, "reconciliation.classified", %{"label" => "post_crash"}},
             {:observed, "reconciliation.reconciled", %{"label" => "recovery"}},
             {:count, "brce.admission", :gte, 2}
           ]},
        outcome_predicate:
          {:any,
           [
             {:observed, "brce.actuate.start"},
             {:not,
              {:observed, "reconciliation.classified",
               %{"label" => "post_crash", "state" => "prepared_unknown_outcome"}}},
             {:not,
              {:observed, "reconciliation.classified",
               %{"label" => "final", "state" => "reconciled", "resolved_as" => "not_executed"}}}
           ]}
      ),
      negative(3,
        invariant:
          "A crash during the external call (effect already applied) is never reported executed from memory, never repeated, and reconciles as executed",
        stimulus:
          "CommandBus.run killed while the external call stalls after applying its row; EKV killed+restarted; classify; reconcile(probe); resubmit",
        boundary: "Pending receipt anchor + claim replay + Reconciliation probe",
        forbidden_outcome:
          "a second actuation or row, or post-crash state other than prepared_unknown_outcome, or final state other than reconciled(executed)",
        attempt_evidence:
          "brce.actuate.start, reconciliation.classified(post_crash), reconciliation.reconciled(recovery), second admission",
        survival_evidence:
          "brce.actuate.start count >= 2; ledger rows > 1; classified states differ",
        guard: "CommandBus claim_receipt/3 replay of the drained pending anchor",
        failure_class: :replay_failure,
        attempt_predicate:
          {:all,
           [
             {:observed, "brce.actuate.start"},
             {:observed, "reconciliation.classified", %{"label" => "post_crash"}},
             {:observed, "reconciliation.reconciled", %{"label" => "recovery"}},
             {:count, "brce.admission", :gte, 2}
           ]},
        outcome_predicate: executed_crash_forbidden()
      ),
      negative(4,
        invariant:
          "A crash after the external response / before finalization loses no replay protection and reconciles as executed",
        stimulus:
          "CommandBus.run killed at brce.actuate.stop; EKV killed+restarted; classify; reconcile(probe); resubmit",
        boundary: "Pending receipt anchor + claim replay + Reconciliation probe",
        forbidden_outcome:
          "a second actuation or row, or post-crash state other than prepared_unknown_outcome, or final state other than reconciled(executed)",
        attempt_evidence:
          "brce.actuate.stop, reconciliation.classified(post_crash), reconciliation.reconciled(recovery), second admission",
        survival_evidence:
          "brce.actuate.start count >= 2; ledger rows > 1; classified states differ",
        guard: "Receipt.pending/3 anchor persisted before DO; ReceiptStore replay",
        failure_class: :replay_failure,
        attempt_predicate:
          {:all,
           [
             {:observed, "brce.actuate.stop"},
             {:observed, "reconciliation.classified", %{"label" => "post_crash"}},
             {:observed, "reconciliation.reconciled", %{"label" => "recovery"}},
             {:count, "brce.admission", :gte, 2}
           ]},
        outcome_predicate: executed_crash_forbidden()
      ),
      negative(5,
        invariant:
          "A crash after finalization / before caller acknowledgement is classified executed and the caller's retry replays, never re-actuates",
        stimulus:
          "CommandBus.run killed at brce.commit(committed); EKV killed+restarted; classify; resubmit",
        boundary: "ReceiptStore committed receipt + claim replay",
        forbidden_outcome: "a second actuation or row, or post-crash state other than executed",
        attempt_evidence:
          "brce.commit(committed), reconciliation.classified(post_crash), second admission",
        survival_evidence:
          "brce.actuate.start count >= 2; ledger rows > 1; classified(post_crash) != executed",
        guard: "ReceiptStore.Ekv.decide_claim/2 replay clause",
        failure_class: :replay_failure,
        attempt_predicate:
          {:all,
           [
             {:observed, "brce.commit", %{"outcome" => "committed"}},
             {:observed, "reconciliation.classified", %{"label" => "post_crash"}},
             {:count, "brce.admission", :gte, 2}
           ]},
        outcome_predicate:
          {:any,
           [
             {:count, "brce.actuate.start", :gte, 2},
             {:not,
              {:observed, "reconciliation.classified",
               %{"label" => "post_crash", "state" => "executed"}}}
           ]}
      ),
      negative(6,
        invariant: "Duplicate submission of the same command produces exactly one consequence",
        stimulus: "CommandBus.run of one command id three times sequentially",
        boundary: "ReceiptStore claim (same id + same fingerprint -> replay)",
        forbidden_outcome: "more than one actuation or ledger row",
        attempt_evidence: "three brce.admission events",
        survival_evidence: "brce.actuate.start count >= 2; ledger rows > 1",
        guard: "ReceiptStore.Ekv.claim/2 replay/in_flight decisions",
        failure_class: :replay_failure,
        attempt_predicate: {:count, "brce.admission", :gte, 3},
        outcome_predicate: {:count, "brce.actuate.start", :gte, 2}
      ),
      negative(7,
        invariant:
          "Concurrent duplicate transport (many processes, one command id) produces exactly one consequence",
        stimulus:
          "8 concurrent CommandBus.run of one command id: 4 racing the claim, 4 more while the winner is inside the external call",
        boundary: "ReceiptStore.Ekv insert-if-absent CAS claim + outbox drain during execution",
        forbidden_outcome: "more than one actuation or ledger row",
        attempt_evidence: "eight brce.admission events",
        survival_evidence: "brce.actuate.start count >= 2; ledger rows > 1",
        guard: "ReceiptStore.Ekv.attempt_fresh_claim/3 if_vsn: nil CAS",
        failure_class: :replay_failure,
        attempt_predicate: {:count, "brce.admission", :gte, 8},
        outcome_predicate: {:count, "brce.actuate.start", :gte, 2}
      ),
      negative(8,
        invariant:
          "Replay after reconciliation (repeated replays, repeated drains, another restart) creates zero new consequence and reconciliation is idempotent",
        stimulus:
          "crash during external call; restart; reconcile(probe); 3 replays; drain; restart again; reconcile again; replay",
        boundary: "ReceiptStore replay of the reconciled receipt + Reconciliation idempotency",
        forbidden_outcome: "any second actuation or row, or a final state other than reconciled",
        attempt_evidence:
          "reconciliation.reconciled(recovery) and (recovery2), five brce.admission events",
        survival_evidence:
          "brce.actuate.start count >= 2; ledger rows > 1; classified(final) != reconciled",
        guard:
          "Reconciliation.resolve/4 only resolves prepared_unknown_outcome; ReceiptStore replay",
        failure_class: :replay_failure,
        attempt_predicate:
          {:all,
           [
             {:observed, "reconciliation.reconciled", %{"label" => "recovery"}},
             {:observed, "reconciliation.reconciled", %{"label" => "recovery2"}},
             {:count, "brce.admission", :gte, 5}
           ]},
        outcome_predicate:
          {:any,
           [
             {:count, "brce.actuate.start", :gte, 2},
             {:not,
              {:observed, "reconciliation.classified",
               %{"label" => "final", "state" => "reconciled"}}}
           ]}
      ),
      negative(9,
        invariant:
          "Primary receipt storage lost mid-run fails closed: no success, no committed receipt, no re-actuation while down, outcome recoverable after restart",
        stimulus:
          "EKV killed from inside the bus at brce.prepare(prepared); run continues; retry while down; restart; reconcile; resubmit",
        boundary:
          "CommandBus.commit_receipt/3 retries + outbox_after_consequence/2 + claim_receipt/3 rescue",
        forbidden_outcome:
          "{:ok, _} or brce.commit(committed) while storage is down, a second actuation, or final state other than executed",
        attempt_evidence:
          "brce.prepare(prepared), brce.actuate.stop, brce.commit, reconciliation.reconciled(recovery)",
        survival_evidence:
          "brce.commit(committed) observed; bus returned ok; brce.actuate.start count >= 2; classified(final) != executed",
        guard:
          "CommandBus.commit_receipt/3 {:error, _} branch; claim_receipt/3 store-unavailable refusal",
        failure_class: :receipt_failure,
        attempt_predicate:
          {:all,
           [
             {:observed, "brce.prepare", %{"outcome" => "prepared"}},
             {:observed, "brce.actuate.stop"},
             {:observed, "brce.commit"},
             {:observed, "reconciliation.reconciled", %{"label" => "recovery"}}
           ]},
        outcome_predicate:
          {:any,
           [
             {:observed, "brce.commit", %{"outcome" => "committed"}},
             {:count, "brce.actuate.start", :gte, 2},
             {:not,
              {:observed, "reconciliation.classified",
               %{"label" => "final", "state" => "executed"}}}
           ]}
      ),
      negative(10,
        invariant: "An actuator timeout is recorded as an unknown outcome, never as success",
        stimulus:
          "external call stalls before applying; caller kills the bus 100ms after actuation starts; restart; classify; drain (no probe); resubmit",
        boundary:
          "Receipt.pending/3 anchor + ReceiptOutbox.reconcile (pending committed as pending)",
        forbidden_outcome:
          "a completed/committed receipt, brce.actuate.stop(ok), an executed classification, or any external effect",
        attempt_evidence:
          "brce.actuate.start, reconciliation.classified(post_timeout), second admission",
        survival_evidence:
          "brce.commit(committed) or actuate.stop(ok) observed; classified state executed; resubmission status completed; ledger rows > 0",
        guard: "ReceiptOutbox.reconcile/2 commits :pending without inferring an outcome",
        failure_class: :actuation_failure,
        attempt_predicate:
          {:all,
           [
             {:observed, "brce.actuate.start"},
             {:observed, "reconciliation.classified", %{"label" => "post_timeout"}},
             {:count, "brce.admission", :gte, 2}
           ]},
        outcome_predicate:
          {:any,
           [
             {:observed, "brce.commit", %{"outcome" => "committed"}},
             {:observed, "brce.actuate.stop", %{"outcome" => "ok"}},
             {:observed, "reconciliation.classified", %{"state" => "executed"}},
             {:count, "brce.actuate.start", :gte, 2},
             {:not,
              {:observed, "reconciliation.classified",
               %{"label" => "post_timeout", "state" => "prepared_unknown_outcome"}}},
             {:not,
              {:observed, "reconciliation.classified",
               %{"label" => "final", "state" => "prepared_unknown_outcome"}}}
           ]}
      ),
      negative(11,
        invariant:
          "A torn (partially written) receipt anchor is never read as not_attempted and never licenses re-actuation",
        stimulus:
          "CommandBus.run killed at brce.prepare(prepared); journal file truncated to half; restart; classify; reconcile(probe); resubmit",
        boundary:
          "ReceiptOutbox decode + Reconciliation unreadable-entry fail-closed + durable claim",
        forbidden_outcome: "not_attempted classification, any actuation, or any external effect",
        attempt_evidence:
          "brce.prepare(prepared), reconciliation.classified(post_corruption), second admission",
        survival_evidence:
          "classified not_attempted; brce.actuate.start observed; ledger rows > 0",
        guard: "Reconciliation.state/2 unreadable-entry clause; ReceiptStore.Ekv in_flight claim",
        failure_class: :receipt_failure,
        attempt_predicate:
          {:all,
           [
             {:observed, "brce.prepare", %{"outcome" => "prepared"}},
             {:observed, "reconciliation.classified", %{"label" => "post_corruption"}},
             {:count, "brce.admission", :gte, 2}
           ]},
        outcome_predicate:
          {:any,
           [
             {:observed, "brce.actuate.start"},
             {:observed, "reconciliation.classified", %{"state" => "not_attempted"}},
             {:not,
              {:observed, "reconciliation.classified",
               %{"label" => "post_corruption", "state" => "prepared_unknown_outcome"}}}
           ]}
      ),
      negative(12,
        invariant:
          "Reconciliation never discards an observed (finalized, outboxed) outcome because the primary store already holds the pending anchor",
        stimulus:
          "executor held at brce.actuate.start; outbox drained (pending anchor -> primary); EKV killed; executor resumes (commit fails, finalized receipt outboxed); restart; reconcile (no probe)",
        boundary: "ReceiptOutbox.reconcile_entry/3",
        forbidden_outcome:
          "the reconciled state is not executed (the observed outcome was erased) or a second actuation",
        attempt_evidence:
          "receipt.outboxed, reconciliation.classified(pre_drain), reconciliation.reconciled(recovery)",
        survival_evidence:
          "reconciliation.reconciled(recovery).state != executed; classified(final) != executed",
        guard: "ReceiptOutbox.reconcile_entry/3 finalized-supersedes-pending clause",
        failure_class: :receipt_failure,
        attempt_predicate:
          {:all,
           [
             {:observed, "receipt.outboxed"},
             {:observed, "reconciliation.classified", %{"label" => "pre_drain"}},
             {:observed, "reconciliation.reconciled", %{"label" => "recovery"}}
           ]},
        outcome_predicate:
          {:any,
           [
             {:not,
              {:observed, "reconciliation.reconciled",
               %{"label" => "recovery", "state" => "executed"}}},
             {:not,
              {:observed, "reconciliation.classified",
               %{"label" => "final", "state" => "executed"}}},
             {:count, "brce.actuate.start", :gte, 2}
           ]}
      ),
      negative(13,
        invariant:
          "After a crash, the same command id with different content is refused, not replayed and not executed (actuation identity is bound to content)",
        stimulus:
          "CommandBus.run killed at brce.actuate.stop; restart; resubmit the same command id with a different input",
        boundary: "ReceiptStore fingerprint check (command_conflict)",
        forbidden_outcome: "a replayed receipt or a second actuation for the conflicting content",
        attempt_evidence: "brce.actuate.stop and two brce.claim events",
        survival_evidence:
          "brce.claim(replay) observed; brce.actuate.start count >= 2; bus returned ok",
        guard: "ReceiptStore.Ekv.decide_claim/2 fingerprint mismatch clause",
        failure_class: :identity_failure,
        attempt_predicate:
          {:all, [{:observed, "brce.actuate.stop"}, {:count, "brce.claim", :gte, 2}]},
        outcome_predicate:
          {:any,
           [
             {:observed, "brce.claim", %{"outcome" => "replay"}},
             {:count, "brce.actuate.start", :gte, 2}
           ]}
      ),
      positive(14,
        invariant:
          "Positive control: an uncrashed authorized command prepares, actuates once, commits durably and is classified executed",
        stimulus: "one CommandBus.run of a fresh command; classify",
        boundary: "CommandBus + ReceiptStore.Ekv + Reconciliation",
        attempt_evidence: "brce.admission(admitted)",
        survival_evidence:
          "prepare precedes actuation; brce.commit(committed); classified(final) executed; one ledger row",
        attempt_predicate: {:observed, "brce.admission", %{"outcome" => "admitted"}},
        outcome_predicate:
          {:all,
           [
             {:precedes, "brce.prepare", "brce.actuate.start", "command"},
             {:observed, "brce.commit", %{"outcome" => "committed"}},
             {:observed, "reconciliation.classified",
              %{"label" => "final", "state" => "executed"}}
           ]}
      ),
      positive(15,
        invariant:
          "Positive control: distinct command ids submitted concurrently each execute exactly once (idempotency does not collapse distinct identities)",
        stimulus: "6 concurrent CommandBus.run of 6 distinct command ids",
        boundary: "ReceiptStore.Ekv claim",
        attempt_evidence: "six brce.admission events",
        survival_evidence: "exactly six actuations and six commits; one ledger row per id",
        attempt_predicate: {:count, "brce.admission", :gte, 6},
        outcome_predicate:
          {:all, [{:count, "brce.actuate.start", :eq, 6}, {:count, "brce.commit", :gte, 6}]}
      ),
      positive(16,
        invariant:
          "Positive control: an external rejection is classified failed, not executed or unknown",
        stimulus: "one CommandBus.run whose external call rejects; classify",
        boundary: "Receipt.finalize/2 status + Reconciliation",
        attempt_evidence: "brce.actuate.start",
        survival_evidence: "brce.actuate.stop(error); classified(final) failed; zero ledger rows",
        attempt_predicate: {:observed, "brce.actuate.start"},
        outcome_predicate:
          {:all,
           [
             {:observed, "brce.actuate.stop", %{"outcome" => "error"}},
             {:observed, "reconciliation.classified", %{"label" => "final", "state" => "failed"}}
           ]}
      ),
      positive(17,
        invariant:
          "Positive control: an executed consequence compensated by a receipted compensation is classified compensated and its replay does not re-actuate",
        stimulus:
          "CommandBus.run; Reconciliation.compensate/5 running a compensating CommandBus.run; replay original; classify",
        boundary: "Reconciliation.compensate/5 + CommandBus",
        attempt_evidence: "reconciliation.compensated",
        survival_evidence:
          "reconciliation.compensated(compensated); classified(final) compensated; exactly two actuations; zero ledger rows",
        attempt_predicate: {:observed, "reconciliation.compensated"},
        outcome_predicate:
          {:all,
           [
             {:observed, "reconciliation.compensated", %{"outcome" => "compensated"}},
             {:observed, "reconciliation.classified",
              %{"label" => "final", "state" => "compensated"}},
             {:count, "brce.actuate.start", :eq, 2}
           ]}
      ),
      Falsifier.new!(
        id: fid(18),
        court_id: @court,
        kind: :measurement,
        invariant:
          "SA2A-B10: every injected crash point reports prepared receipt state, outcome knowledge, recovery time, reconciliation result and zero repeated external effects",
        stimulus:
          "sweep of the five §70 crash points, each: crash, EKV restart, reconcile(probe), resubmit",
        boundary: "CommandBus + ReceiptStore.Ekv + ReceiptOutbox + Reconciliation",
        attempt_evidence: "ten brce.admission events and five reconciliation.reconciled events",
        survival_evidence:
          "repeated external effects (ledger rows beyond one per command id) must be 0",
        rfc_sections: ["§94"],
        tags: [:benchmark, :b10],
        attempt_predicate:
          {:all,
           [
             {:count, "brce.admission", :gte, 10},
             {:count, "reconciliation.reconciled", :gte, 5}
           ]},
        outcome_predicate: {:count, "brce.actuate.start", :lte, 3}
      ),
      negative(19,
        invariant:
          "An abandoned claim (crash before receipt preparation) becomes reclaimable once its configured claim lease elapses, and the resubmission after the lease succeeds with exactly one actuation",
        stimulus:
          "with a short claim_lease_ms configured: CommandBus.run killed at brce.claim(execute) (no anchor ever prepared, matching scenario 1's crash point); resubmit immediately (still in_flight); sleep past the lease; resubmit again",
        boundary: "AshA2A.ReceiptStore.ClaimLease.abandoned?/2 inside ReceiptStore.Ekv.claim/2",
        forbidden_outcome:
          "the resubmission after the lease elapses is still refused in_flight, or more than one actuation or ledger row is ever observed",
        attempt_evidence:
          "brce.claim(execute), brce.claim(refused, in_flight) before the lease elapses, and a third brce.admission for the post-lease resubmission",
        survival_evidence:
          "the post-lease resubmission is still refused in_flight, or ledger rows != 1, or actuate.start count != 1, or the immediate replay of the resubmission is not replayed?: true",
        guard:
          "AshA2A.ReceiptStore.ClaimLease.abandoned?/2 lease+anchor test; ReceiptStore.Ekv.decide_claim/4 + reclaim/3",
        failure_class: :receipt_failure,
        attempt_predicate:
          {:all,
           [
             {:observed, "brce.claim", %{"outcome" => "execute"}},
             {:observed, "brce.claim", %{"outcome" => "refused", "code" => "in_flight"}},
             {:count, "brce.admission", :gte, 3}
           ]},
        outcome_predicate:
          {:any,
           [
             {:not_observed, "brce.commit", %{"outcome" => "committed"}},
             {:not, {:count, "brce.actuate.start", :eq, 1}}
           ]}
      ),
      negative(20,
        invariant:
          "A claim that reached receipt preparation is never reclaimed by the claim lease alone, no matter how long the lease window has passed; it remains recoverable only through the existing outbox reconciliation path, with zero actuations",
        stimulus:
          "with a short claim_lease_ms configured: CommandBus.run killed at brce.prepare(prepared) (anchor durably written, matching scenario 2's crash point); sleep well past the lease; a direct ReceiptStore.Ekv.claim/2 call (bypassing CommandBus.run's own outbox auto-drain) must still refuse in_flight; then run the real Reconciliation.reconcile(probe) recovery path and resubmit through CommandBus.run",
        boundary:
          "AshA2A.ReceiptStore.ClaimLease.abandoned?/2's outbox-anchor test inside ReceiptStore.Ekv.claim/2",
        forbidden_outcome:
          "any actuation or ledger row at any point, the direct post-lease store claim is anything other than refused in_flight, or the final reconciled state is not not_executed",
        attempt_evidence:
          "brce.prepare(prepared), reconciliation.classified(post_lease_wait), reconciliation.reconciled(recovery)",
        survival_evidence:
          "actuate.start observed at any point; ledger rows > 0; classified(final) != reconciled(not_executed)",
        guard:
          "AshA2A.ReceiptStore.ClaimLease.abandoned?/2 anchored?/1 clause; ReceiptOutbox.reconcile pending-commit recovery path",
        failure_class: :receipt_failure,
        attempt_predicate:
          {:all,
           [
             {:observed, "brce.prepare", %{"outcome" => "prepared"}},
             {:observed, "reconciliation.classified", %{"label" => "post_lease_wait"}},
             {:observed, "reconciliation.reconciled", %{"label" => "recovery"}},
             {:count, "brce.admission", :gte, 2}
           ]},
        outcome_predicate:
          {:any,
           [
             {:observed, "brce.actuate.start"},
             {:not,
              {:observed, "reconciliation.classified",
               %{"label" => "post_lease_wait", "state" => "prepared_unknown_outcome"}}},
             {:not,
              {:observed, "reconciliation.classified",
               %{"label" => "final", "state" => "reconciled", "resolved_as" => "not_executed"}}}
           ]}
      )
    ]
  end

  defp executed_crash_forbidden do
    {:any,
     [
       {:count, "brce.actuate.start", :gte, 2},
       {:not,
        {:observed, "reconciliation.classified",
         %{"label" => "post_crash", "state" => "prepared_unknown_outcome"}}},
       {:not,
        {:observed, "reconciliation.classified",
         %{"label" => "final", "state" => "reconciled", "resolved_as" => "executed"}}}
     ]}
  end

  defp fid(n), do: @court <> "-" <> String.pad_leading(Integer.to_string(n), 3, "0")

  defp negative(n, fields) do
    Falsifier.new!(
      [id: fid(n), court_id: @court, kind: :negative, rfc_sections: sections(n)] ++ fields
    )
  end

  defp positive(n, fields) do
    Falsifier.new!(
      [
        id: fid(n),
        court_id: @court,
        kind: :positive_control,
        rfc_sections: ["§100" | sections(n)]
      ] ++
        fields
    )
  end

  defp sections(n) when n in [1, 2, 3, 4, 5, 12], do: ["§70"]
  defp sections(n) when n in [6, 7, 8, 13], do: ["§71"]
  defp sections(n) when n in [9, 10, 11], do: ["§96"]
  defp sections(_), do: ["§70", "§71"]

  # --- execution ------------------------------------------------------------------

  @impl true
  def run(%Context{} = ctx) do
    declared = falsifiers()

    if Env.attach_ordered?() do
      Enum.map(declared, fn f -> safe_scenario(ctx, f) end)
    else
      Enum.map(
        declared,
        &Result.blocked(
          &1,
          "telemetry does not dispatch handlers in attach order on this node; a boundary crash handler could erase the boundary evidence before the observer records it"
        )
      )
    end
  end

  defp safe_scenario(ctx, %Falsifier{id: id} = f) do
    n = id |> String.split("-") |> List.last() |> String.to_integer()
    scenario(n, ctx, f)
  rescue
    exception ->
      Result.unknown(
        f,
        "scenario raised: " <> Exception.format(:error, exception, __STACKTRACE__),
        :ocel_evidence_incomplete
      )
  catch
    kind, reason ->
      Result.unknown(f, "scenario #{kind}: #{inspect(reason)}", :ocel_evidence_incomplete)
  end

  # 001-005: crash the executing bus at a point, restart, classify, recover.
  defp scenario(1, ctx, f) do
    crash_scenario(ctx, f, %{}, {:at_event, @claim, %{outcome: :execute}}, fn ev ->
      attempt? =
        ev.crash.crash_point_reached? and seen(ctx, f, "brce.claim", %{"outcome" => "execute"}) and
          classified?(ev.post) and count(ctx, f, "brce.admission") >= 2

      forbidden? =
        ev.rows_after_crash > 0 or ev.rows_final > 1 or state(ev.post) != :not_attempted or
          not precedes?(ctx, f, "brce.prepare", "brce.actuate.start") or
          count(ctx, f, "brce.actuate.start") >= 2

      {attempt?, forbidden?}
    end)
  end

  defp scenario(2, ctx, f) do
    crash_scenario(ctx, f, %{}, {:at_event, @prepare, %{outcome: :prepared}}, fn ev ->
      attempt? =
        ev.crash.crash_point_reached? and seen(ctx, f, "brce.prepare", %{"outcome" => "prepared"}) and
          ev.raw_post_crash.outbox_statuses == [:pending] and classified?(ev.post) and
          match?({:ok, _}, ev.recovery) and count(ctx, f, "brce.admission") >= 2

      forbidden? =
        ev.rows_final > 0 or count(ctx, f, "brce.actuate.start") > 0 or
          state(ev.post) != :prepared_unknown_outcome or
          not final?(ev.final, :reconciled, :not_executed)

      {attempt?, forbidden?}
    end)
  end

  defp scenario(3, ctx, f) do
    input = %{"hang_after_ms" => @stall_ms}

    crash_scenario(ctx, f, input, :during_external_call, fn ev ->
      attempt? =
        ev.crash.crash_point_reached? and ev.rows_after_crash == 1 and
          seen(ctx, f, "brce.actuate.start") and classified?(ev.post) and
          match?({:ok, _}, ev.recovery) and count(ctx, f, "brce.admission") >= 2

      {attempt?, executed_crash_violated?(ctx, f, ev)}
    end)
  end

  defp scenario(4, ctx, f) do
    crash_scenario(ctx, f, %{}, {:at_event, @actuate_stop, %{}}, fn ev ->
      attempt? =
        ev.crash.crash_point_reached? and ev.rows_after_crash == 1 and
          seen(ctx, f, "brce.actuate.stop") and classified?(ev.post) and
          match?({:ok, _}, ev.recovery) and count(ctx, f, "brce.admission") >= 2

      {attempt?, executed_crash_violated?(ctx, f, ev)}
    end)
  end

  defp scenario(5, ctx, f) do
    crash_scenario(ctx, f, %{}, {:at_event, @commit, %{outcome: :committed}}, fn ev ->
      attempt? =
        ev.crash.crash_point_reached? and seen(ctx, f, "brce.commit", %{"outcome" => "committed"}) and
          classified?(ev.post) and count(ctx, f, "brce.admission") >= 2

      forbidden? =
        ev.rows_final > 1 or count(ctx, f, "brce.actuate.start") >= 2 or
          state(ev.post) != :executed or
          not match?({:ok, %Receipt{replayed?: true}}, ev.resubmission)

      {attempt?, forbidden?}
    end)
  end

  defp scenario(6, ctx, f) do
    with_env(ctx, f, fn env ->
      cid = new_command_id(f)
      input = input(cid)

      replies =
        Context.stimulus(ctx, f, fn -> for _ <- 1..3, do: Env.run(env, cid, input) end)

      rows = Env.rows(cid)
      actuations = count(ctx, f, "brce.actuate.start")

      Result.negative(f,
        attempt_observed?: count(ctx, f, "brce.admission") >= 3,
        forbidden_outcome_observed?: rows > 1 or actuations >= 2,
        evidence: %{
          "command_id" => cid,
          "replies" => Enum.map(replies, &reply/1),
          "ledger_rows" => rows,
          "actuations_observed" => actuations
        }
      )
    end)
  end

  defp scenario(7, ctx, f) do
    with_env(ctx, f, fn env ->
      cid = new_command_id(f)
      input = Map.put(input(cid), "hang_after_ms", 300)

      replies =
        Context.stimulus(ctx, f, fn ->
          wave1 = for _ <- 1..4, do: Task.async(fn -> Env.run(env, cid, input) end)
          _ = Env.wait_until(fn -> Env.rows(cid) > 0 end, 10_000)
          wave2 = for _ <- 1..4, do: Task.async(fn -> Env.run(env, cid, input) end)
          Task.await_many(wave1 ++ wave2, 30_000)
        end)

      rows = Env.rows(cid)
      actuations = count(ctx, f, "brce.actuate.start")

      Result.negative(f,
        attempt_observed?: count(ctx, f, "brce.admission") >= 8,
        forbidden_outcome_observed?: rows > 1 or actuations >= 2,
        evidence: %{
          "command_id" => cid,
          "replies" =>
            replies |> Enum.map(&reply/1) |> Enum.frequencies() |> Enum.map(&inspect/1),
          "ledger_rows" => rows,
          "actuations_observed" => actuations
        }
      )
    end)
  end

  defp scenario(8, ctx, f) do
    with_env(ctx, f, fn env ->
      cid = new_command_id(f)
      input = Map.put(input(cid), "hang_after_ms", @stall_ms)

      ev =
        Context.stimulus(ctx, f, fn ->
          crash = Env.run_crashing(env, cid, input, :during_external_call)
          env = Env.restart_store(env)
          recovery = reconcile(env, cid, label: "recovery", probe: &Env.probe/1)
          replays = for _ <- 1..3, do: Env.run(env, cid, input)
          drain = CommandBus.reconcile_outboxed_receipts(Env.store(), Env.store_opts(env))
          env = Env.restart_store(env)
          recovery2 = reconcile(env, cid, label: "recovery2", probe: &Env.probe/1)
          last = Env.run(env, cid, input)
          final = classify(env, cid, "final")

          %{
            crash: crash,
            recovery: recovery,
            replays: replays ++ [last],
            drain: drain,
            recovery2: recovery2,
            final: final
          }
        end)

      rows = Env.rows(cid)
      actuations = count(ctx, f, "brce.actuate.start")

      Result.negative(f,
        attempt_observed?:
          ev.crash.crash_point_reached? and match?({:ok, _}, ev.recovery) and
            match?({:ok, _}, ev.recovery2) and count(ctx, f, "brce.admission") >= 5,
        forbidden_outcome_observed?:
          rows > 1 or actuations >= 2 or not final?(ev.final, :reconciled, :executed),
        evidence: %{
          "command_id" => cid,
          "crash" => crash_evidence(ev.crash),
          "recovery" => recovery_evidence(ev.recovery),
          "recovery2" => recovery_evidence(ev.recovery2),
          "replays" => Enum.map(ev.replays, &reply/1),
          "final" => classification_evidence(ev.final),
          "ledger_rows" => rows,
          "actuations_observed" => actuations
        }
      )
    end)
  end

  defp scenario(9, ctx, f) do
    with_env(ctx, f, fn env ->
      cid = new_command_id(f)
      input = input(cid)

      ev =
        Context.stimulus(ctx, f, fn ->
          handler = Env.attach_store_crash(env, @prepare, %{outcome: :prepared})

          returned =
            try do
              Env.run(env, cid, input)
            after
              :telemetry.detach(handler)
            end

          store_down? = not Env.store_alive?(env)
          retry_while_down = Env.run(env, cid, input)
          rows_while_down = Env.rows(cid)
          env = Env.restart_store(env)
          raw_after_restart = Env.raw_evidence(env, cid)
          recovery = reconcile(env, cid, label: "recovery")
          resubmission = Env.run(env, cid, input)
          final = classify(env, cid, "final")

          %{
            returned: returned,
            store_down?: store_down?,
            retry_while_down: retry_while_down,
            rows_while_down: rows_while_down,
            raw_after_restart: raw_after_restart,
            recovery: recovery,
            resubmission: resubmission,
            final: final,
            raw_final: Env.raw_evidence(env, cid)
          }
        end)

      rows = Env.rows(cid)
      actuations = count(ctx, f, "brce.actuate.start")

      Result.negative(f,
        attempt_observed?:
          ev.store_down? and seen(ctx, f, "brce.prepare", %{"outcome" => "prepared"}) and
            seen(ctx, f, "brce.actuate.stop") and seen(ctx, f, "brce.commit") and
            match?({:ok, _}, ev.recovery),
        forbidden_outcome_observed?:
          match?({:ok, _}, ev.returned) or match?({:ok, _}, ev.retry_while_down) or
            seen(ctx, f, "brce.commit", %{"outcome" => "committed"}) or actuations >= 2 or
            rows > 1 or state(ev.final) != :executed,
        evidence: %{
          "command_id" => cid,
          "returned_while_store_down" => reply(ev.returned),
          "retry_while_store_down" => reply(ev.retry_while_down),
          "ledger_rows_while_down" => ev.rows_while_down,
          "raw_after_restart" => ev.raw_after_restart,
          "recovery" => recovery_evidence(ev.recovery),
          "resubmission" => reply(ev.resubmission),
          "final" => classification_evidence(ev.final),
          "raw_final" => ev.raw_final,
          "ledger_rows" => rows,
          "actuations_observed" => actuations
        }
      )
    end)
  end

  defp scenario(10, ctx, f) do
    with_env(ctx, f, fn env ->
      cid = new_command_id(f)
      input = Map.put(input(cid), "hang_before_ms", @stall_ms)

      ev =
        Context.stimulus(ctx, f, fn ->
          crash = Env.run_crashing(env, cid, input, {:actuator_timeout, 100})
          env = Env.restart_store(env)
          post = classify(env, cid, "post_timeout")
          recovery = reconcile(env, cid, label: "recovery")
          resubmission = Env.run(env, cid, input)
          final = classify(env, cid, "final")

          %{
            crash: crash,
            post: post,
            recovery: recovery,
            resubmission: resubmission,
            final: final,
            raw_final: Env.raw_evidence(env, cid)
          }
        end)

      rows = Env.rows(cid)

      Result.negative(f,
        attempt_observed?:
          ev.crash.crash_point_reached? and seen(ctx, f, "brce.actuate.start") and
            classified?(ev.post) and count(ctx, f, "brce.admission") >= 2,
        forbidden_outcome_observed?:
          rows > 0 or state(ev.post) != :prepared_unknown_outcome or
            state(ev.final) != :prepared_unknown_outcome or
            match?({:ok, %Receipt{status: :completed}}, ev.resubmission) or
            seen(ctx, f, "brce.actuate.stop", %{"outcome" => "ok"}) or
            seen(ctx, f, "brce.commit", %{"outcome" => "committed"}) or
            count(ctx, f, "brce.actuate.start") >= 2,
        evidence: %{
          "command_id" => cid,
          "crash" => crash_evidence(ev.crash),
          "post_timeout" => classification_evidence(ev.post),
          "recovery" => recovery_evidence(ev.recovery),
          "resubmission" => reply(ev.resubmission),
          "final" => classification_evidence(ev.final),
          "raw_final" => ev.raw_final,
          "ledger_rows" => rows
        }
      )
    end)
  end

  defp scenario(11, ctx, f) do
    with_env(ctx, f, fn env ->
      cid = new_command_id(f)
      input = input(cid)

      ev =
        Context.stimulus(ctx, f, fn ->
          crash =
            Env.run_crashing(env, cid, input, {:at_event, @prepare, %{outcome: :prepared}})

          torn = Env.tear_outbox_entries(env)
          env = Env.restart_store(env)
          post = classify(env, cid, "post_corruption")
          recovery = reconcile(env, cid, label: "recovery", probe: &Env.probe/1)
          resubmission = Env.run(env, cid, input)
          final = classify(env, cid, "final")

          %{
            crash: crash,
            torn: torn,
            post: post,
            recovery: recovery,
            resubmission: resubmission,
            final: final
          }
        end)

      rows = Env.rows(cid)

      Result.negative(f,
        attempt_observed?:
          ev.crash.crash_point_reached? and ev.torn >= 1 and
            seen(ctx, f, "brce.prepare", %{"outcome" => "prepared"}) and classified?(ev.post) and
            count(ctx, f, "brce.admission") >= 2,
        forbidden_outcome_observed?:
          state(ev.post) != :prepared_unknown_outcome or state(ev.final) == :not_attempted or
            seen(ctx, f, "brce.actuate.start") or rows > 0,
        evidence: %{
          "command_id" => cid,
          "crash" => crash_evidence(ev.crash),
          "torn_journal_files" => ev.torn,
          "post_corruption" => classification_evidence(ev.post),
          "recovery" => recovery_evidence(ev.recovery),
          "resubmission" => reply(ev.resubmission),
          "final" => classification_evidence(ev.final),
          "ledger_rows" => rows
        }
      )
    end)
  end

  defp scenario(12, ctx, f) do
    with_env(ctx, f, fn env ->
      cid = new_command_id(f)
      input = input(cid)

      ev =
        Context.stimulus(ctx, f, fn ->
          paused =
            Env.run_paused(env, cid, input, @actuate_start, fn ->
              drain = CommandBus.reconcile_outboxed_receipts(Env.store(), Env.store_opts(env))
              raw = Env.raw_evidence(env, cid)
              Env.crash_store(env)
              %{drain: drain, raw: raw}
            end)

          env = Env.restart_store(env)
          pre = classify(env, cid, "pre_drain")
          raw_pre = Env.raw_evidence(env, cid)
          recovery = reconcile(env, cid, label: "recovery")
          resubmission = Env.run(env, cid, input)
          final = classify(env, cid, "final")

          %{
            paused: paused,
            pre: pre,
            raw_pre: raw_pre,
            recovery: recovery,
            resubmission: resubmission,
            final: final,
            raw_final: Env.raw_evidence(env, cid)
          }
        end)

      rows = Env.rows(cid)
      drained = get_in(ev, [:paused, :while_paused, :drain])
      raw_while_paused = get_in(ev, [:paused, :while_paused, :raw])

      recovered_state =
        case ev.recovery do
          {:ok, %{after: after_c}} -> after_c.state
          _ -> :unavailable
        end

      Result.negative(f,
        attempt_observed?:
          ev.paused.paused? and match?({:ok, %{committed: n}} when n >= 1, drained) and
            match?(%{primary: %{status: :pending}}, raw_while_paused) and
            seen(ctx, f, "receipt.outboxed") and classified?(ev.pre) and
            match?({:ok, _}, ev.recovery),
        forbidden_outcome_observed?:
          recovered_state != :executed or state(ev.final) != :executed or rows > 1 or
            count(ctx, f, "brce.actuate.start") >= 2,
        evidence: %{
          "command_id" => cid,
          "drain_while_executing" => inspect(drained),
          "raw_while_executing" => raw_while_paused,
          "executor_returned" => reply(ev.paused.returned),
          "pre_drain" => classification_evidence(ev.pre),
          "raw_pre_drain" => ev.raw_pre,
          "recovery" => recovery_evidence(ev.recovery),
          "resubmission" => reply(ev.resubmission),
          "final" => classification_evidence(ev.final),
          "raw_final" => ev.raw_final,
          "ledger_rows" => rows
        }
      )
    end)
  end

  defp scenario(13, ctx, f) do
    with_env(ctx, f, fn env ->
      cid = new_command_id(f)
      input = input(cid)

      ev =
        Context.stimulus(ctx, f, fn ->
          crash = Env.run_crashing(env, cid, input, {:at_event, @actuate_stop, %{}})
          env = Env.restart_store(env)
          conflicting = Env.run(env, cid, Map.put(input, "variant", "smuggled"))
          %{crash: crash, conflicting: conflicting}
        end)

      rows = Env.rows(cid)

      Result.negative(f,
        attempt_observed?:
          ev.crash.crash_point_reached? and seen(ctx, f, "brce.actuate.stop") and
            count(ctx, f, "brce.claim") >= 2,
        forbidden_outcome_observed?:
          match?({:ok, _}, ev.conflicting) or seen(ctx, f, "brce.claim", %{"outcome" => "replay"}) or
            count(ctx, f, "brce.actuate.start") >= 2 or rows > 1,
        evidence: %{
          "command_id" => cid,
          "crash" => crash_evidence(ev.crash),
          "conflicting_resubmission" => reply(ev.conflicting),
          "ledger_rows" => rows
        }
      )
    end)
  end

  defp scenario(14, ctx, f) do
    with_env(ctx, f, fn env ->
      cid = new_command_id(f)

      {reply, final} =
        Context.stimulus(ctx, f, fn ->
          reply = Env.run(env, cid, input(cid))
          {reply, classify(env, cid, "final")}
        end)

      rows = Env.rows(cid)

      Result.positive(f,
        attempt_observed?: seen(ctx, f, "brce.admission", %{"outcome" => "admitted"}),
        expected_outcome_observed?:
          match?({:ok, %Receipt{status: :completed, standing: :durable}}, reply) and rows == 1 and
            state(final) == :executed and precedes?(ctx, f, "brce.prepare", "brce.actuate.start") and
            seen(ctx, f, "brce.commit", %{"outcome" => "committed"}),
        evidence: %{
          "command_id" => cid,
          "reply" => reply(reply),
          "final" => classification_evidence(final),
          "ledger_rows" => rows
        }
      )
    end)
  end

  defp scenario(15, ctx, f) do
    with_env(ctx, f, fn env ->
      cids = for _ <- 1..6, do: new_command_id(f)

      replies =
        Context.stimulus(ctx, f, fn ->
          cids
          |> Enum.map(fn cid ->
            Task.async(fn -> Env.run(env, cid, Map.put(input(cid), "hang_after_ms", 50)) end)
          end)
          |> Task.await_many(30_000)
        end)

      rows = Map.new(cids, &{&1, Env.rows(&1)})

      Result.positive(f,
        attempt_observed?: count(ctx, f, "brce.admission") >= 6,
        expected_outcome_observed?:
          Enum.all?(replies, &match?({:ok, %Receipt{status: :completed, replayed?: false}}, &1)) and
            Enum.all?(rows, fn {_cid, n} -> n == 1 end) and
            count(ctx, f, "brce.actuate.start") == 6,
        evidence: %{"replies" => Enum.map(replies, &reply/1), "ledger_rows" => rows}
      )
    end)
  end

  defp scenario(16, ctx, f) do
    with_env(ctx, f, fn env ->
      cid = new_command_id(f)

      {reply, final} =
        Context.stimulus(ctx, f, fn ->
          reply = Env.run(env, cid, Map.put(input(cid), "fail", true))
          {reply, classify(env, cid, "final")}
        end)

      rows = Env.rows(cid)

      Result.positive(f,
        attempt_observed?: seen(ctx, f, "brce.actuate.start"),
        expected_outcome_observed?:
          seen(ctx, f, "brce.actuate.stop", %{"outcome" => "error"}) and state(final) == :failed and
            rows == 0,
        evidence: %{
          "command_id" => cid,
          "reply" => reply(reply),
          "final" => classification_evidence(final),
          "ledger_rows" => rows
        }
      )
    end)
  end

  defp scenario(17, ctx, f) do
    with_env(ctx, f, fn env ->
      cid = new_command_id(f)
      comp_cid = new_command_id(f)
      input = input(cid)

      ev =
        Context.stimulus(ctx, f, fn ->
          original = Env.run(env, cid, input)
          rows_executed = Env.rows(cid)

          compensated =
            Reconciliation.compensate(
              Identity.command(cid),
              Env.store(),
              Env.store_opts(env),
              fn _receipt ->
                Env.run(env, comp_cid, %{"operation_id" => cid}, :compensate_effect)
              end,
              label: "compensation"
            )

          replay = Env.run(env, cid, input)
          final = classify(env, cid, "final")

          %{
            original: original,
            rows_executed: rows_executed,
            compensated: compensated,
            replay: replay,
            final: final
          }
        end)

      rows = Env.rows(cid)

      Result.positive(f,
        attempt_observed?: seen(ctx, f, "reconciliation.compensated"),
        expected_outcome_observed?:
          ev.rows_executed == 1 and rows == 0 and state(ev.final) == :compensated and
            match?({:ok, %Receipt{replayed?: true}}, ev.replay) and
            count(ctx, f, "brce.actuate.start") == 2,
        evidence: %{
          "command_id" => cid,
          "compensation_command_id" => comp_cid,
          "original" => reply(ev.original),
          "ledger_rows_after_execution" => ev.rows_executed,
          "compensation" => classification_evidence(ev.compensated),
          "replay" => reply(ev.replay),
          "final" => classification_evidence(ev.final),
          "ledger_rows" => rows
        }
      )
    end)
  end

  defp scenario(18, ctx, f) do
    points = [
      {"before_receipt_preparation", %{}, {:at_event, @claim, %{outcome: :execute}}},
      {"after_preparation_before_external_call", %{},
       {:at_event, @prepare, %{outcome: :prepared}}},
      {"during_external_call", %{"hang_after_ms" => @stall_ms}, :during_external_call},
      {"after_external_response_before_finalization", %{}, {:at_event, @actuate_stop, %{}}},
      {"after_finalization_before_acknowledgement", %{},
       {:at_event, @commit, %{outcome: :committed}}}
    ]

    records =
      Context.stimulus(ctx, f, fn ->
        Enum.map(points, fn {point, extra, crash} -> b10_point(ctx, f, point, extra, crash) end)
      end)

    repeated = records |> Enum.map(& &1["repeated_external_effects"]) |> Enum.sum()
    recovery = Enum.map(records, & &1["recovery_ms"])

    measurements = %{
      "benchmark_id" => "SA2A-B10",
      "points" => records,
      "crash_points_reached" => Enum.count(records, & &1["crash_point_reached"]),
      "repeated_external_effects_total" => repeated,
      "recovery_ms_max" => Enum.max(recovery),
      "recovery_ms_min" => Enum.min(recovery),
      "environment" => %{
        "otp_release" => to_string(:erlang.system_info(:otp_release)),
        "elixir" => System.version(),
        "schedulers_online" => :erlang.system_info(:schedulers_online),
        "store" => inspect(Env.store()),
        "store_mode" =>
          "EKV member, cluster_size 1, on-disk SQLite, killed and restarted per point"
      }
    }

    attempt? =
      Enum.all?(records, & &1["crash_point_reached"]) and count(ctx, f, "brce.admission") >= 10

    if repeated == 0 do
      Result.measured(f, attempt_observed?: attempt?, measurements: measurements)
    else
      %{
        Result.unknown(
          f,
          "SA2A-B10 observed #{repeated} repeated external effect(s); desired 0 (§94)",
          :actuation_failure
        )
        | measurements: measurements
      }
    end
  end

  # 019/020: bounded claim lease + reconciliation (closes the SA2A-CHAOS
  # liveness gap where an abandoned in-flight claim, receipt: nil forever,
  # blocked every resubmission). Both temporarily configure a short
  # `:claim_lease_ms` and restore the previous value afterward.
  defp scenario(19, ctx, f) do
    with_env(ctx, f, fn env ->
      cid = new_command_id(f)
      input = input(cid)
      lease_ms = 300

      ev =
        Context.stimulus(ctx, f, fn ->
          with_claim_lease(lease_ms, fn ->
            crash = Env.run_crashing(env, cid, input, {:at_event, @claim, %{outcome: :execute}})
            still_in_flight = Env.run(env, cid, input)
            Process.sleep(lease_ms * 3)
            resubmission = Env.run(env, cid, input)
            replay = Env.run(env, cid, input)

            %{
              crash: crash,
              still_in_flight: still_in_flight,
              resubmission: resubmission,
              replay: replay
            }
          end)
        end)

      rows = Env.rows(cid)
      actuations = count(ctx, f, "brce.actuate.start")

      Result.negative(f,
        attempt_observed?:
          ev.crash.crash_point_reached? and
            seen(ctx, f, "brce.claim", %{"outcome" => "execute"}) and
            match?({:error, %{code: :in_flight}}, ev.still_in_flight) and
            count(ctx, f, "brce.admission") >= 3,
        forbidden_outcome_observed?:
          rows != 1 or actuations != 1 or
            not match?({:ok, %Receipt{status: :completed, replayed?: false}}, ev.resubmission) or
            not match?({:ok, %Receipt{replayed?: true}}, ev.replay),
        evidence: %{
          "command_id" => cid,
          "lease_ms" => lease_ms,
          "crash" => crash_evidence(ev.crash),
          "still_in_flight_before_lease" => reply(ev.still_in_flight),
          "resubmission_after_lease" => reply(ev.resubmission),
          "replay_after_resubmission" => reply(ev.replay),
          "ledger_rows" => rows,
          "actuations_observed" => actuations
        }
      )
    end)
  end

  defp scenario(20, ctx, f) do
    with_env(ctx, f, fn env ->
      cid = new_command_id(f)
      input = input(cid)
      lease_ms = 300

      ev =
        Context.stimulus(ctx, f, fn ->
          with_claim_lease(lease_ms, fn ->
            crash =
              Env.run_crashing(env, cid, input, {:at_event, @prepare, %{outcome: :prepared}})

            env = Env.restart_store(env)
            Process.sleep(lease_ms * 3)

            # A DIRECT store-level claim (not `CommandBus.run/4`, whose own
            # `maybe_reconcile_outbox/2` would drain this exact anchor into
            # the primary store before any claim decision runs, confounding
            # what is under test here): proves `ReceiptStore.Ekv.claim/2`'s
            # own reclaim guard holds well past the lease, on its own, before
            # any reconciliation ever touches this command id.
            direct_claim_after_lease =
              Env.store().claim(Env.command(cid, input), Env.store_opts(env))

            rows_after_wait = Env.rows(cid)
            post = classify(env, cid, "post_lease_wait")
            recovery = reconcile(env, cid, label: "recovery", probe: &Env.probe/1)
            resubmission = Env.run(env, cid, input)
            final = classify(env, cid, "final")

            %{
              crash: crash,
              direct_claim_after_lease: direct_claim_after_lease,
              rows_after_wait: rows_after_wait,
              post: post,
              recovery: recovery,
              resubmission: resubmission,
              final: final
            }
          end)
        end)

      rows = Env.rows(cid)
      actuations = count(ctx, f, "brce.actuate.start")

      Result.negative(f,
        attempt_observed?:
          ev.crash.crash_point_reached? and
            seen(ctx, f, "brce.prepare", %{"outcome" => "prepared"}) and
            classified?(ev.post) and match?({:ok, _}, ev.recovery) and
            count(ctx, f, "brce.admission") >= 2,
        forbidden_outcome_observed?:
          not match?({:error, :in_flight}, ev.direct_claim_after_lease) or
            actuations > 0 or rows > 0 or ev.rows_after_wait > 0 or
            state(ev.post) != :prepared_unknown_outcome or
            not final?(ev.final, :reconciled, :not_executed),
        evidence: %{
          "command_id" => cid,
          "lease_ms" => lease_ms,
          "crash" => crash_evidence(ev.crash),
          "direct_claim_after_lease" => inspect(ev.direct_claim_after_lease, limit: 5),
          "post_lease_wait" => classification_evidence(ev.post),
          "recovery" => recovery_evidence(ev.recovery),
          "resubmission" => reply(ev.resubmission),
          "final" => classification_evidence(ev.final),
          "ledger_rows" => rows,
          "actuations_observed" => actuations
        }
      )
    end)
  end

  # Scopes a short `:claim_lease_ms` to `fun`, always restoring whatever was
  # configured before (own `after` clause, not just `on_exit` -- this runs
  # inside a court, not an ExUnit test).
  defp with_claim_lease(lease_ms, fun) do
    previous = Application.get_env(:ash_a2a, :claim_lease_ms)
    Application.put_env(:ash_a2a, :claim_lease_ms, lease_ms)

    try do
      fun.()
    after
      case previous do
        nil -> Application.delete_env(:ash_a2a, :claim_lease_ms)
        value -> Application.put_env(:ash_a2a, :claim_lease_ms, value)
      end
    end
  end

  defp b10_point(ctx, f, point, extra, crash) do
    root = Path.join([ctx.evidence_dir, "sa2a-chaos", f.id, point])
    env = Env.open(root)

    try do
      cid = new_command_id(f)
      input = Map.merge(input(cid), extra)
      crashed = Env.run_crashing(env, cid, input, crash)
      rows_after_crash = Env.rows(cid)
      raw_post_crash = Env.raw_evidence(env, cid)
      started = System.monotonic_time(:microsecond)
      env = Env.restart_store(env)
      post = classify(env, cid, "b10.post_crash")
      recovery = reconcile(env, cid, label: "b10.recovery", probe: &Env.probe/1)
      recovery_us = System.monotonic_time(:microsecond) - started
      resubmission = Env.run(env, cid, input)
      final = classify(env, cid, "b10.final")
      rows = Env.rows(cid)

      %{
        "failure_point" => point,
        "crash_point_reached" => crashed.crash_point_reached?,
        "prepared_receipt_state" => %{
          "classification" => state(post),
          "journal_anchor_statuses" => Enum.map(raw_post_crash.outbox_statuses, &to_string/1),
          "primary" => raw_post_crash.primary
        },
        "external_outcome_knowledge" => %{
          "ledger_rows_after_crash" => rows_after_crash,
          "probe" => probe_label(recovery)
        },
        "recovery_ms" => Float.round(recovery_us / 1000, 3),
        "reconciliation_result" => %{
          "outcome" => recovery_outcome(recovery),
          "final_state" => state(final),
          "resolved_as" => resolved_as(final),
          "resubmission" => reply(resubmission)
        },
        "repeated_external_effects" => max(rows - 1, 0)
      }
    after
      Env.close(env)
    end
  end

  # --- shared crash scenario ----------------------------------------------------------

  defp crash_scenario(ctx, f, extra_input, crash, judge) do
    with_env(ctx, f, fn env ->
      cid = new_command_id(f)
      input = Map.merge(input(cid), extra_input)

      ev =
        Context.stimulus(ctx, f, fn ->
          crashed = Env.run_crashing(env, cid, input, crash)
          rows_after_crash = Env.rows(cid)
          raw_post_crash = Env.raw_evidence(env, cid)
          env = Env.restart_store(env)
          post = classify(env, cid, "post_crash")
          recovery = reconcile(env, cid, label: "recovery", probe: &Env.probe/1)
          resubmission = Env.run(env, cid, input)
          final = classify(env, cid, "final")

          %{
            crash: crashed,
            rows_after_crash: rows_after_crash,
            raw_post_crash: raw_post_crash,
            post: post,
            recovery: recovery,
            resubmission: resubmission,
            final: final,
            raw_final: Env.raw_evidence(env, cid),
            rows_final: Env.rows(cid)
          }
        end)

      {attempt?, forbidden?} = judge.(ev)

      Result.negative(f,
        attempt_observed?: attempt?,
        forbidden_outcome_observed?: forbidden?,
        evidence: %{
          "command_id" => cid,
          "crash" => crash_evidence(ev.crash),
          "ledger_rows_after_crash" => ev.rows_after_crash,
          "raw_post_crash" => ev.raw_post_crash,
          "post_crash" => classification_evidence(ev.post),
          "recovery" => recovery_evidence(ev.recovery),
          "resubmission" => reply(ev.resubmission),
          "final" => classification_evidence(ev.final),
          "raw_final" => ev.raw_final,
          "ledger_rows_final" => ev.rows_final,
          "actuations_observed" => count(ctx, f, "brce.actuate.start")
        }
      )
    end)
  end

  defp executed_crash_violated?(ctx, f, ev) do
    ev.rows_final > 1 or count(ctx, f, "brce.actuate.start") >= 2 or
      state(ev.post) != :prepared_unknown_outcome or not final?(ev.final, :reconciled, :executed)
  end

  # --- helpers -------------------------------------------------------------------------

  defp with_env(ctx, f, fun) do
    env = Env.open(Path.join([ctx.evidence_dir, "sa2a-chaos", f.id]))

    try do
      fun.(env)
    after
      Env.close(env)
    end
  end

  defp new_command_id(%Falsifier{id: id}),
    do: String.downcase(id) <> "-" <> Integer.to_string(System.unique_integer([:positive]))

  defp input(cid), do: %{"operation_id" => cid}

  defp classify(env, cid, label) do
    Reconciliation.classify(Identity.command(cid), Env.store(), Env.store_opts(env), label: label)
  end

  defp reconcile(env, cid, opts) do
    Reconciliation.reconcile(Identity.command(cid), Env.store(), Env.store_opts(env), opts)
  end

  defp state({:ok, %{state: state}}), do: state
  defp state(_), do: :unavailable

  defp resolved_as({:ok, %{resolved_as: resolved}}), do: resolved
  defp resolved_as(_), do: nil

  defp classified?(classification), do: match?({:ok, %{state: _}}, classification)

  defp final?(classification, expected_state, expected_resolution),
    do:
      state(classification) == expected_state and
        resolved_as(classification) == expected_resolution

  defp records(ctx, f), do: Context.observed(ctx, f)

  defp count(ctx, f, activity, attrs \\ %{}) do
    Enum.count(records(ctx, f), fn record ->
      record.activity == activity and
        Enum.all?(attrs, fn {k, v} -> to_string(Map.get(record.attributes, k)) == to_string(v) end)
    end)
  end

  defp seen(ctx, f, activity, attrs \\ %{}), do: count(ctx, f, activity, attrs) > 0

  # In-run mirror of `{:precedes, a, b, "command"}`: every b has an earlier a
  # for the same command object.
  defp precedes?(ctx, f, a, b) do
    records = records(ctx, f)
    as = Enum.filter(records, &(&1.activity == a))

    records
    |> Enum.filter(&(&1.activity == b))
    |> Enum.all?(fn rb ->
      commands = command_objects(rb)
      Enum.any?(as, &(&1.seq < rb.seq and not MapSet.disjoint?(commands, command_objects(&1))))
    end)
  end

  defp command_objects(record) do
    for {"command", id, _q} <- record.objects, into: MapSet.new(), do: id
  end

  defp reply({:ok, %Receipt{} = r}),
    do: %{
      "result" => "ok",
      "status" => r.status,
      "replayed" => r.replayed?,
      "standing" => r.standing
    }

  defp reply({:error, %{code: code}}), do: %{"result" => "error", "code" => code}
  defp reply(nil), do: nil
  defp reply(other), do: %{"result" => inspect(other, limit: 5)}

  defp crash_evidence(crash) do
    %{
      "crash_point_reached" => crash.crash_point_reached?,
      "down_reason" => inspect(crash.down_reason),
      "returned" => reply(crash.returned)
    }
  end

  defp classification_evidence({:ok, %{} = c}) do
    c
    |> Map.drop([:receipt])
    |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
  end

  defp classification_evidence(other), do: %{"error" => inspect(other)}

  defp recovery_evidence({:ok, %{before: before, after: after_c, drain: drain, outcome: outcome}}) do
    %{
      "before" => classification_evidence({:ok, before}),
      "after" => classification_evidence({:ok, after_c}),
      "drain" => drain,
      "outcome" => outcome
    }
  end

  defp recovery_evidence(other), do: %{"error" => inspect(other)}

  defp recovery_outcome({:ok, %{outcome: outcome}}), do: outcome
  defp recovery_outcome(other), do: inspect(other)

  defp probe_label({:ok, %{after: %{resolved_as: resolved}}}) when resolved != nil,
    do: "resolved_#{resolved}"

  defp probe_label({:ok, %{outcome: outcome}}), do: "not_consulted_#{outcome}"
  defp probe_label(_), do: "unavailable"
end
