# Changelog

All notable changes to `ash_a2a` are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project intends to adhere to [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
once it reaches 1.0.

## [26.9.20] - 2026-09-20

### Added

- **`AshA2A.Reconciliation.MapeK`**: a named Monitor/Analyze/Plan/Execute
  loop over shared Knowledge, built on the existing
  `AshA2A.Reconciliation.classify/4` and `.reconcile/4` (purely additive,
  no change to either) (`test/ash_a2a/reconciliation_mape_k_test.exs`).
- **GALL structured-work-fabric (SWF) message types**: six new modules
  under `lib/ash_a2a/gall/` -- `Capability`, `Checkpoint`,
  `EvidenceReceipt`, `Fields`, `Message`, `WorkLease` -- typed message
  shapes for GALL checkpoint/lease/receipt exchange with typed authority
  refusals (`test/ash_a2a_gall_swf_message_test.exs`, 21 tests, 0
  failures).
- Per-method A2A JSON-RPC conformance tests over the real vendored
  `A2A.Plug` (`test/ash_a2a_a2a_methods_test.exs`) and
  `docs/reference/a2a-spec-version-mapping.md`. One test in this file,
  `message/stream answers with an SSE event stream`, is `@tag :skip`'d: it
  exposed a genuine gap -- `A2A.stream/3` returns an error (observed as a
  real `application/json` reply, not `text/event-stream`) for an agent
  built over a plain `:read`-skill Ash resource. Left skipped with the
  gap documented inline rather than silently weakened or deleted; fixing
  `AshA2A.Agent`'s streaming-skill support is real feature work out of
  this release's scope.
- `CITATION.cff`, `REPRODUCE.md`.
- Two GALL process-intervention specs (from `gall/v26.9.18-final-specs`):
  `docs/jira/v26.9.18/GALL-029-process-finding-admission-{PRD,ARD}.md`,
  `docs/jira/v26.9.18/GALL-030-bounded-process-intervention-{PRD,ARD}.md`.

### Changed

- SA2A profile identifiers moved from v26.9.16 to v26.9.20
  (`SA2A-PROFILE-v26.9.20`, `urn:sa2a:profile:v26.9.20`,
  `SA2A-STRICT-v26.9.20`) in `AshA2A.SA2A.Conformance` and
  `AshA2A.Semantic.Extension`, with matching test-fixture updates.

## [26.9.18] - 2026-09-19

### Fixed

- **`RouterCounters` telemetry cross-contamination between concurrent
  same-node instances** (v26.9.17 stress finding, resolved):
  `:telemetry.execute/3` broadcasts
  `[:ash_a2a, :router, :tier_selected]` to every attached handler on the
  node, so two overlapping instances each counted the other's dispatches --
  the exact per-batch mismatch the stress wave reproduced and had to prune
  around (`multinode_concurrency_test.exs`). `attach!/3` now accepts
  `owner: pid` (default `:any`, the unchanged historical semantics), the
  same design `AshA2A.Telemetry.AllocationCounters` shipped for the
  identical broadcast problem; `handle_event/4` runs in the emitting
  process, so a pid-scoped instance counts exactly its own dispatches.
  Fail-before: two concurrent drivers x (2 facts + 1 phrase) dispatches
  each read `%{deterministic: 4, phrase: 2}`; pass-after: each reads its
  own exact counts (`test/ash_a2a/telemetry/router_counters_isolation_test.exs`).
  `AshA2A.Test.MultinodeRouterCounters.drive_and_report/3` (the reference
  consumer that hit the defect) now attaches with `owner: self()`.

### Added

- **Standing `CommandBus.run/4` tail-latency SLO tripwire**
  (`AshA2A.Chicago.Stress.CommandBusTailLatencyTripwireTest`, `:benchmark`
  tag): under sustained concurrent load, late-half p99 must stay within
  **3.0x** early-half p99 with zero errors -- 2x headroom over the worst
  non-pathological `Memory`-store measurement (1.274x-1.515x), versus the
  pathological 181x observed under heavy host contention. The tripwire
  reports the store's real max mailbox length and outbox depth alongside
  the ratio (so a trip arrives with its mechanism attached) and carries an
  explicit forced-synthetic knob (`ASH_A2A_TAIL_TRIPWIRE_FORCE_X`) used
  only for its own fail-before evidence (forced 10x late-half run trips:
  measured ratio 12.158x). SLO and mechanism documented in
  `AshA2A.CommandBus`'s moduledoc. Mechanism diagnosis behind the bound:
  per-dispatch sampler evidence shows the store mailbox and the receipt
  outbox do NOT accumulate through a run (both ~0 from start to finish),
  while mean/p50 climb and throughput decays track host contention -- the
  shared-mailbox deschedule amplification the
  `v26.9.17-commandbus-scale.md` Memory-vs-Ekv differential already
  measured, not unbounded in-SUT state growth; callers needing the
  tightest tail on contended hosts configure `:receipt_store, Ekv`
  (0.812x-1.072x on the same metric).

- Three new public-vocabulary prefixes in `AshA2A.Semantic.Vocabulary`:
  `ssn` (http://www.w3.org/ns/ssn/), `saref`
  (https://saref.etsi.org/core/), and `qudt`
  (http://qudt.org/schema/qudt/), alongside the existing
  rdf/rdfs/owl/prov/time/odrl/skos/schema/oa/sosa registry. No other
  behavior changes -- `expand/1`, `local/1`, and every other prefix keep
  their existing IRIs. Prompted by a planned SA2A-MFG-01 synthetic
  manufacturing case study (in a separate repo) that needs
  equipment/quantity semantics expressed on public ontologies rather than
  a bespoke domain schema; landed here first since the case study depends
  on it.

## [26.9.17] - 2026-09-17

### Fixed -- HddlSolver cross-VM temp-file collision (the stress pass's disclosed defect, now fixed at the source)

- `AshA2A.Planning.HddlSolver.run/4` derived its temp paths from
  `System.unique_integer/1`, which is unique only WITHIN one BEAM VM. On
  the stress wave's own shape (real `:peer` nodes on one shared host, all
  resolving the same `System.tmp_dir!/0`), two fresh VMs' monotonic
  counters emit identical sequences, so same-sequence solves derived the
  SAME absolute temp paths; the concurrent `File.write!/2` + `File.rm/1`
  pairs then corrupted each other's solve (the original stress run caught
  two peers both computing `ash_a2a_hddl_domain_11.hddl`, one peer's
  cleanup unlinking the file under the other peer's in-flight
  `System.cmd/3` read). The fix prefixes a sanitized `node()` tag to the
  per-invocation unique integer, making paths unique ACROSS VMs by
  construction (distinct nodes have distinct names); cleanup is unchanged
  and per-owner. Reproduction:
  `AshA2A.PlanningHddlSolverCrossvmTest` (`test/ash_a2a_planning_hddl_solver_crossvm_test.exs`)
  drives TWO real `:peer` nodes concurrently over a shared `tmp_dir`, one
  with the genuinely solvable `freedom_gym_meeting` pair and one with the
  genuinely unsolvable `unsolvable_qualification` pair, and asserts every
  outcome stayed consistent with its own node's inputs. Fail-before
  (unfixed code; re-verified on this branch): `1 test, 1 failure` on every
  run, with run-varying real cross-contamination through the shared paths
  -- the solvable node returning `:hddl_solve_error` for solutions that
  were its own bytes, and on the original stress run, node B's first
  iteration returning `ok: true`, a solve of node A's bytes. Pass-after:
  `1 test, 0 failures` (plus 2 stability reruns), related
  planning/multinode/HddlSolver suites (8 files) `42 tests, 0 failures`,
  `mix test --max-cases 6` clean except the disclosed pre-existing
  graphlaw-family flakes (`GraphLawVendorToolVersionCwdTest` `/private/var`;
  `GraphlawEngineTest` `on_exit` teardown races), all green in isolation.
  The stress harness's test-side
  `isolate_peer_unique_integer_counters/1` band mitigation
  (`test/ash_a2a/chicago/stress/multinode_concurrency_test.exs`) remains
  harmless but is now redundant; removing it belongs to that file's own
  scope.

### Docs
- Production-readiness documentation pass (v26.9.17 dry run): README
  front-door rewrite (correcting the false "vendored `:a2a` SDK" claim —
  it is the published `actioncard/a2a-elixir` Hex package — and the CI
  native-build claim: CI builds `hddl_cli` only), a corrected Getting
  Started (agents boot via `config :ash_a2a, :agents` because the library
  app already runs `A2A.AgentSupervisor`; new HTTP-serving step with
  `A2A.Plug`/`A2A.Client`), new reference pages (DSL schema,
  configuration, telemetry events, mix tasks, A2A endpoint contract), a
  new message-lifecycle explanation, new how-tos (testing, verifying
  authority on async Oban paths), auth/OCEL how-to corrections, status
  banners on the v26.9.17 reports, `SECURITY.md`, and hex-package
  shipping of the `docs/` quadrants (previously `mix hex.publish` would
  fail to build ExDoc extras the package did not contain).

### Fixed -- CommandBus production-scale story: real gap closed, Ekv wiring now genuinely config-only

- Merged both v26.9.17 Benchmark-phase branches
  (`feat/bench-ekv-receipt-store-scale`, `feat/bench-ekv-authority-broker-scale`)
  that measured `AshA2A.ReceiptStore.Ekv` and `AshA2A.Authority.Broker.Ekv`
  against their `Memory`/`InMemory` counterparts under real sustained
  concurrent load. Real, disclosed findings (both against the hypothesized
  "Ekv resolves scale" outcome, verified rather than assumed): the receipt
  store's Ekv variant resolves the specific *climbing* p99-under-load
  pattern `Memory` shows, but trades it for materially lower throughput and
  occasional multi-second I/O-contended outliers on a shared/loaded host;
  the authority broker's Ekv variant does not resolve anything at that
  read-heavy layer -- it is ~1.7x-2.2x higher latency than `InMemory` at
  every percentile, with no throughput upside. Neither is an unqualified
  scale win; both are real durability-vs-latency trades. Full numbers in
  `docs/explanation/v26.9.17-commandbus-scale.md`.
- **Real gap found and fixed while investigating why a production caller
  would choose `Ekv` at all**: `AshA2A.Application.start/2` auto-wired a
  real `EKV` instance for `:receipt_store` when set to
  `AshA2A.ReceiptStore.Ekv`, but had no equivalent clause for
  `:authority_broker` -- so `docs/how-to/authenticate-agent-requests.md`'s
  own primary example (`config :ash_a2a, :authority_broker,
  AshA2A.Authority.Broker.Ekv`, alone) was not actually config-only: no
  `EKV` instance existed for the broker to read/write, so every real
  `granted?/3` call rescued/caught to `false`. Fixed with a new
  `authority_broker_children/0` in `lib/ash_a2a/application.ex`, mirroring
  `receipt_store_children/0` exactly (bare-module and `{module, opts}`
  tuple config forms both handled, a distinct default `:name`/`:data_dir`
  so the two Ekv-backed layers never share an on-disk keyspace by
  accident). `AshA2A.Authority.Broker.InMemory` keeps its existing
  host-started convention -- only the durable `Ekv` broker needed this.
- Two new real (no mock/stub) tests in `test/ash_a2a/application_test.exs`
  prove the fix: one starts the real application with only the config line
  above set and round-trips a real grant through
  `AshA2A.Authority.Grant.grant/3`/`granted?/3`/`revoke/3` with no manual
  `EKV` start anywhere in the test; the other configures both
  `:receipt_store` and `:authority_broker` as `Ekv` simultaneously and
  asserts two distinct, real, alive `EKV` children. Both fixed two further
  real defects these tests themselves caught while being written
  (`EKV.child_spec/1`'s real supervision type, and directory/subject-name
  uniqueness that a bare `System.unique_integer/1` does not guarantee
  across separate `mix test` process invocations) -- confirmed stable
  across 9 repeated runs (5 back-to-back plus 4 distinct `--seed` values),
  0 failures.

### Hardened, benchmarked, and stress-tested -- v26.9.17 harden/benchmark/stress pass

- 14 disjoint worktree tasks ran in parallel against v26.9.17 (6
  hardening, 5 benchmark-authoring covering 7 new RFC-SA2A-002
  categories, 3 stress/soak), then merged serially (`--no-ff`, no
  conflicts) onto `main`. Final head `fea05cd`.
- **Hardening (6 tasks)**: 4 clean bills of health -- no real defect
  found in `CommandBus`/S55 actuation-claim concurrency, crash
  boundaries (RFC S70), the mock/Dialyzer posture (0 mock violations,
  0 new Dialyzer warning classes), or `Bounds`/`Allocator` resource-
  exhaustion/escalation paths. 2 tasks found real production defects,
  both correctly left unfixed here (the fix lives in a file shared
  with other parallel worktrees) and flagged for the serial
  MergeVerify/integration phase instead: (1)
  `AshA2A.Semantic.Peer.admit_candidate/2` silently admits non-Turtle
  garbage that parses to zero triples over the real HTTP wire (no
  parse-stage witness, unlike `AdmissionPipeline`); (2) the shipped
  `test/support/command_worker.ex` never calls
  `ObanAuthority.verify_live!/3`, so a revoked-but-unexpired authority
  still actuates through it. Verbatim findings and commit SHAs in
  `docs/explanation/chicago-benchmark-report.md`'s new "Hardening
  findings" section. **Both defects were subsequently fixed on `main` in
  `1f06cab` (2026-09-17)**: `Peer.admit_candidate/2` now requires a
  parse-stage witness, and `test/support/command_worker.ex` now calls
  `ObanAuthority.verify_live!/3` with receipt-peek ordering.
- **Benchmarks**: RFC-SA2A-002 names 10 benchmark categories; before
  this pass only 3 (B1/B5/B9) had a real standalone module. This pass
  adds real, measured modules for the other 7 (B2 logic closure, B3
  Knowledge Hook reflex, B4 HDDL/FOND planning, B6 reactive cascade,
  B7 cross-runtime portability, B8 offline replay, B10 crash/
  recovery) -- all 10 categories now produce real numbers, though the
  7 new modules are not yet wired into `Bench.@benchmarks`/the mix
  task (a disclosed follow-up, not done here since that touches a
  file shared with other parallel worktrees). Full numbers in
  `docs/explanation/chicago-benchmark-report.md`.
- **Stress/soak (3 tasks)**: sustained-throughput found a real,
  reproduced tail-latency-climbs-under-load pattern in
  `CommandBus.run/4` (34,881 dispatches across three 12s runs, 0
  errors, 0 process leak, but late-half p99 up to 181x early-half
  p99); multinode-concurrency ran 6 real `:peer` BEAM nodes cleanly
  (0 failures across 5 seeds) while surfacing two real out-of-scope
  defects (a cross-VM temp-file collision in `HddlSolver`, and
  `RouterCounters` telemetry cross-contamination between concurrent
  instances on one node); resource-ceiling drove 130 real delegations
  against a 100-execution ceiling and terminated exactly at 100/100
  with zero leak past the ceiling. Full detail in
  `docs/explanation/v26.9.17-stress-report.md` and the benchmark
  report's new "Stress test results" section.
- Post-merge full suite (`mix test --max-cases 6`): 58 doctests, 29
  properties, 2086 tests. 1-2 failures observed across repeated runs,
  in different tests each run (`AshA2A.SemanticRefusalTest`'s
  `:hddl_solve_error` mapping check; an `:eaddrinuse` port-bind race
  under parallel execution) -- confirmed pre-existing on `main`
  before this pass (none of this pass's merges touched `lib/` files
  that could move either check), not a regression introduced here.
  Architecture verifier: 11/11 clean on the final merge.

### Verified -- v26.9.17 PRD/ARD 50-agent pass: ash_a2a's own scope only

- Scope note, stated plainly: this entry covers `ash_a2a`'s own portion of a
  v26.9.17 requirements pass. It is **not** a full 11-repo RFC-SA2A-003
  ecosystem CONFORMANT claim -- no other repo in that RFC was touched,
  re-verified, or re-scored as part of this pass.
- Real numbers from this pass: 83 requirements already implemented, 18 real
  gaps found, 16 real gaps built and merged (see the `feat/sa2a-ard-*`
  merge commits in `git log`), 0 gaps deferred to a follow-up within this
  pass's ARD scope (the deferred list is empty for this pass; one
  regression surfaced during the pass and was deferred to the owning
  cluster rather than this task's scope -- see the "Fixed --
  IrAdmissionSeal regression" entry later in this same 26.9.17 section,
  closed there).
- CalVer bump to 26.9.17 committed (`mix.exs` version line only, single-line
  diff, confirmed via `git diff` before commit).
- Real `mix hex.publish --dry-run` outcome: built `ash_a2a 26.9.17` correctly
  end to end -- all 20 declared deps resolved, full lib/priv/mix.exs/README/
  CHANGELOG/LICENSE file manifest listed (several hundred files, including
  every `chicago/*` court module and `semantic/*`, including the new
  `ir_admission_seal.ex`, plus `priv/graphlaw` and `priv/sa2a_conformance`
  fixtures). The prompt reached `Publishing package to public repository
  hexpm. Proceed? [Yn]` and was answered `n` -- no publish occurred (and
  `--dry-run` itself never calls hex.pm's publish endpoint regardless of the
  answer given).
- Architecture-verifier test named by this task
  (`test/ash_a2a_architecture_verifier_test.exs`): 11 tests, 0 failures,
  clean.
- Real, reproducible full-suite regression found and root-caused, **not**
  fixed in this pass (out of this task's assigned scope of bump + verify +
  dry-run + report): `mix test --max-cases 6`, run twice for reproducibility
  (515.8s and 586.3s), reported identical counts both runs -- 58 doctests,
  19 properties, 2036 tests, **24 failures**, 8 invalid, 1 skipped (14
  excluded). The 8 invalid match the known pre-existing baseline (no local
  Postgres) and are not new. The 24 failures are new relative to the stated
  0-failure baseline and are not a flake: every one returns
  `{:error, %{code: :semantic_ir_unsealed, detail: %{source_id: ...}}}`.
  Root cause, confirmed by reading source: the recently-merged
  `lib/ash_a2a/semantic/ir_admission_seal.ex` now gates
  `AshA2A.Semantic.Ontology.from_ir/1`, `PlanningIR.from_ir/2`,
  `ExecutionPackage.new/6`, and `RequestRouter.route/3` behind
  `IrAdmissionSeal.verify/1`, which rejects any IR lacking a real
  `admission_seal`/`admission_receipt_id` minted by `Admission.admit/2`.
  Roughly 15 pre-existing test files still hand-construct
  `%IR{standing: :admitted, authority: :none, ...}` directly instead of
  routing through `Admission.admit/2` -- exactly the forgery class
  `ir_admission_seal.ex`'s own moduledoc names as the gap it closes (citing
  only one already-fixed helper, in `semantic_execution_package_test.exs`).
  Affected files include (non-exhaustive):
  `test/ash_a2a/semantic_feedback_test.exs`,
  `test/ash_a2a/planning/request_router_test.exs`,
  `test/ash_a2a_agent_semantic_router_wiring_test.exs`,
  `test/ash_a2a/chicago/*_test.exs`, and
  `test/ash_a2a/planning/request_router_telemetry_test.exs`. Triage and fix
  of these ~15 files is left to whichever cluster owns
  `ir_admission_seal.ex` / the affected test files; it is out of this
  task's assigned scope.
- Honest overall standing for this pass, at the time it landed: the version
  bump was real and committed; the named architecture-verifier test was
  real and green; the `hex.publish --dry-run` output was real; the
  full-suite baseline was **not** clean -- see the immediately following
  entry for the real fix that closed this out.

### Fixed -- IrAdmissionSeal regression from the v26.9.17 50-agent pass (closed)

- The 24-test regression named in the entry above is now closed for real,
  not by weakening `IrAdmissionSeal.verify/1`. Root causes: (1)
  `AshA2A.Planning.GoalFacts.to_semantic_structs/2` is a pre-existing,
  legitimate SECOND real admission chain (typed facts, no free text, so
  `Admission.admit/2`'s substring check is a category error there) that set
  `standing: :admitted` without minting a seal -- now mints one for real via
  `IrAdmissionSeal.mint/1` after its own real checks pass. (2)
  `lib/ash_a2a/chicago/courts/authority_non_implication.ex`'s
  `plan_package/2` hand-built an unsealed `%IR{standing: :admitted}` with no
  real admission chain at all -- a genuine gap the seal correctly caught;
  routed through real `IR.from_map/2` + `Admission.admit/2`. (3) the 8 new
  refusal codes this pass introduced had no S42 classification -- added
  (`semantic_ir_unsealed`/`semantic_ir_seal_invalid` -> `refused_identity`,
  `peer_b_unavailable` -> `blocked_resource`, 5 `evidence_bounds_*`/
  `evidence_fan_out_exceeded` codes -> `refused_bounds`). (4) two test files
  (`semantic_feedback_test.exs`,
  `ash_a2a_authority_non_implications_test.exs`) had genuine hand-forged
  unsealed IR literals -- fixed via real `IR.from_map/2` +
  `Admission.admit/2`, matching `semantic_execution_package_test.exs`'s
  established pattern. (5) `unknown_llm_gate12_test.exs`'s hardcoded
  `@expected` verdict map was missing the real `SA2A-MX-006` falsifier this
  same pass added to `machine_experience.ex` -- added the entry.
- Checked, not changed: `AshA2A.Chicago.Fixtures.ShexShaclAdmission.
  premarked_canonical_provenance/0` also hand-sets `standing: :admitted` --
  confirmed this is a deliberate negative-control forgery witness for a
  real gate-2 falsifier, not a bug.
- Real, current verification: `mix format --check-formatted` and
  `mix compile --warnings-as-errors` clean; mock grep clean across every
  changed file; architecture verifier + Chicago rollup test 15/15; full
  suite (`mix test --max-cases 6`): 58 doctests, 19 properties, 2036 tests,
  **0 failures**, 8 invalid (known no-local-Postgres baseline, unchanged),
  1 skipped -- the known-stable baseline is restored.

### Fixed -- Local dev-setup gap misread as a board-persona regression

- Real defect found while independently verifying the board-persona
  deliberation plan (`test/ash_a2a/board_persona_deliberation_test.exs`,
  itself fully green and unrelated to this): a fresh worktree's full
  `mix test` run reported 37 real failures and 4 new `setup_all` invalids
  against the stated baseline. Root-caused (not asserted) by reproducing
  the exact failure in an isolated worktree first: `native/hddl_cli`'s
  `target/release/hddl_cli` binary was never built there, so every test
  that dispatches through it (directly, or via the shared
  `test/support/freedom_gym_meeting_plan.ex` fixture) hit the real,
  correctly-raised `hddl_cli_not_built` error instead of a skip. CI
  (`.github/workflows/ci.yml`) already builds this binary as an explicit
  step, and the fixture's own error message already names the fix
  (`cd native/hddl_cli && cargo build --release`) -- this was never a
  source-code bug in `native/hddl_cli/src/main.rs` or in the fixture, and
  no assertion was weakened or deleted to "fix" it.
- Real fix: ran `cargo build --release --locked` for `native/hddl_cli`
  (`Cargo.lock` unchanged) in the isolated worktree; the previously-failing
  suite then reported 0 failures. Added a "Local Development Setup"
  section to `README.md` documenting the two native builds a fresh clone
  or worktree needs before `mix test` (this repo had no such documentation
  anywhere, which is the actual reason the gap existed to begin with).

### Verified -- v26.9.17 FOND/HDDL Self-Improvement Domain

- **`test/ash_a2a/chicago/sa2a_v26_9_17_fond_qualification_test.exs`**: the
  v26.9.17 FOND/HDDL model of the cross-repo SA2A self-improvement
  qualification loop (`test/support/hddl/sa2a_v26_9_17_dogfood/{domain,problem}.hddl`)
  was verified against the real `native/hddl_cli` (ferroplan, strong-cyclic
  FOND) solver, not asserted from description. The real, disclosed outcome
  is `solved: false` -- genuine `NoPlan`, quoted precisely from the real
  solver run: `{"error":"planner error: NoPlan"}`. This is a semantic
  `NoPlan`, not a parse/grounding error (the fixture grounds cleanly; a
  separate test asserts this). Per-branch ablation isolates the exact
  irreducible cause to a small set of predicates left deliberately terminal
  (no repair method added because one would fabricate confidence or bypass
  a real invariant): `unsupported`, `candidate-unsupported`,
  `verification-failed`/`process-nonconformant` (both episodes),
  `candidate-refused` on the knowledge-promotion court, `equivalence-failed`,
  `receipt-reconcile-blocked` (both episodes), and episode 2's
  replay-specific `authority-refused`/`actuation-failed` occurrences.
  Restoring every other, genuinely recoverable branch in combination still
  reports real `solved: true`, so no other latent modeling defect remains.
- The `receipt-reconcile-blocked` terminal branches confirm a real,
  unresolved tension between BRCE's zero-unreceipted-actuation "NEVER
  replay automatically" invariant (`AshA2A.CommandBus`) and this pinned
  ferroplan revision's `PlanningType::Fond` universal-coverage requirement:
  there is no HDDL syntax in this rev to declare an accepted non-goal
  terminal state, so a domain that faithfully models the invariant cannot
  also report a strong-cyclic solve for the predicates that invariant
  touches. An honest `NoPlan` is the correct report here, not a defect.

### Added -- v26.9.17 FOND/HDDL planning: ash_a2a-side completion

- The v26.9.17 FOND/HDDL planning work's remaining ash_a2a-side pieces were
  finished via four orthogonal, independently-committed additions: a
  source-fidelity audit recovering and mechanically verifying the original
  domain/problem paste (`test/ash_a2a/chicago/sa2a_v26_9_17_source_fidelity_test.exs`),
  a permanent cross-repo topology-existence court
  (`AshA2A.Chicago.Courts.SA2AV269_17Topology`, confirming 11 repos alive),
  a reachability-analysis doc re-running `hddl_analyze` independently
  (`docs/explanation/sa2a-v26-9-17-hddl-reachability-analysis.md`), and a
  capability-coverage sweep comparing ash_a2a's own 42+ Chicago courts
  against the 9 v26.9.17 capability categories
  (`docs/explanation/sa2a-v26-9-17-capability-coverage-sweep.md`): 4
  categories fully covered, 4 partially covered, 1 with no matching court
  (`cap-framework-projection`, a disclosed real gap, not force-mapped).
  All four merged to `main` with a full-suite regression run afterward
  (1923 tests, 0 failures, 8 invalid -- no local Postgres -- matching the
  pre-existing baseline).

### Added -- RFC-SA2A-002 Chicago Conformance Court

- **`AshA2A.Chicago`**: a falsification-based conformance court for
  RFC-SA2A-002 v26.9.16 (`docs/rfc/RFC-SA2A-002-v26.9.16.md`). Conformance
  is earned by attempted falsification, not green unit tests:
  `Conformant(S) => ExactIdentity(S) ^ FalsifiersAttempted(S) ^
  ForbiddenStandingAbsent(S) ^ RequiredConsequencesObserved(S) ^
  IndependentEvidence(S)`. Pieces: `Court` (behaviour), `Falsifier` (S11),
  `Result` (S12 verdict algebra), `Context`, `Subject` (S5 exact-subject
  identity), `Observer` (independent OCEL 2.0 process observer), `Query`,
  `Runner` (S104 execution order), `StandingReceipt` (S115), `Crown`
  (release-facing assembly, S31/S98/S114/S145/Appendix C). Entry point:
  `mix ash_a2a.chicago --profile core|logic|plan|do|strict [--court ID]
  [--list] [--crown]` (`mix help ash_a2a.chicago` for the full option
  reference).
- **42 discoverable courts** (`lib/ash_a2a/chicago/courts/`), covering all
  twelve RFC-SA2A-002 gates -- Gate 1 (Exact Identity Fenced) through
  Gate 12 (Zero Runtime Inference on KNOWN) -- plus the admission-pipeline
  courts (ShEx, SHACL, Safe Datalog, N3, SPARQL, canonical graph identity,
  root manifest, semantic envelope, extension negotiation, and others).
- **Mandatory falsifier corpus** (`priv/sa2a/chicago_mandatory_corpus.json`,
  S98): the fourteen RFC-SA2A-001 counterexamples, each resolved against a
  real, currently-declared court falsifier id by
  `Crown.mandatory_corpus_coverage/2`. A member that fails to resolve is a
  reported evidence gap, never silently dropped, and blocks a `:strict`
  claim from reading CONFORMANT.
- **Benchmarks**: `AshA2A.Chicago.Courts.Benchmarks` and
  `mix ash_a2a.chicago.bench`, writing verifiable raw timing results and
  refusing a tampered result file.
- **Mutation testing**: `AshA2A.Chicago.Mutation.Catalog` plus
  `mix ash_a2a.chicago.mutate` and the `SA2A-MUTATION` court, which proves
  each catalog mutant is actually killed by a real court falsifier rather
  than assumed killed. `AshA2A.Test.ChicagoSelfTest` (`CHI-SELFTEST`)
  qualifies the qualification machinery itself against a deliberately
  lying court fixture.
- **Real defects the court found and fixed, not weakened around**:
  - `SA2A-AUTH-017` -- capability substitution across agents: a standing
    grant for one resource's skill authorized the same-named skill on any
    other resource, because `Agent.build_command/4` authorized against the
    caller-supplied wire skill selector instead of the canonical,
    resource-qualified capability id. Fixed in `AshA2A.Agent.build_command/4`.
  - `SA2A-CHAOS-019`/`SA2A-CHAOS-020` -- bounded claim-lease liveness gap:
    a crash between `ReceiptStore.claim/2` and receipt-anchor preparation
    left a command permanently `:in_flight`, with no live executor able to
    resolve it. Fixed by `AshA2A.ReceiptStore.ClaimLease`.
  - `CHI-SELFTEST-REPLAY-001` -- the self-test court never drove a replay,
    so the `replay_calls_actuator` mutation could survive undetected.
    Closed by `AshA2A.Test.ChicagoSelfTest.ReplayCourt`.

### Security -- BREAKING (fail-closed default change)

- **Authority escalation on the default `AshA2A.Agent` dispatch path closed
  (RFC-SA2A-001 S28/S29/S30/S60).** `AshA2A.Agent.build_command/4` took
  `capability_id` from the inbound message's own `skill` metadata -- a
  caller-supplied value -- and handed it straight to
  `AshA2A.Authority.from_verified_identity/2`, which is a pure *constructor*
  that mints a full `%AshA2A.Authority{}` for whatever capability id it is
  given (`source: :transport_verified`). `AshA2A.CommandBus.admit/2` then
  checked `AshA2A.Authority.admits?/2`, which compares the authority's own
  `capability_id` against the command's -- and so passed by construction,
  every time. Net effect: **any transport-authenticated caller held authority
  for every skill on the agent card**, including every `:change` and
  `:external_do` skill. RFC-SA2A-001 S29 ("Authentication does NOT imply
  Authority") was false on the real production dispatch path.

  Reproduced before the fix against a real `A2A.Agent` process and a real
  actuation counter: an authenticated principal holding no grant of any kind
  actuated both an `:external_do` and a `:change` skill (2 real actuations).
  After the fix the identical run produces 0 actuations and two `failed`
  tasks. Regression coverage:
  `test/ash_a2a_authority_capability_grant_test.exs`.

  The fix introduces `AshA2A.Authority.Grant` -- the real capability-GRANT
  decision that sits between "identity verified by the transport" and
  "authority held for this capability" -- wired into `agent.ex` in place of
  the direct `from_verified_identity/2` call. It consults the configured
  `AshA2A.Authority.Broker` (the seam RFC S28 names, which already existed in
  this codebase with two real implementations and had never been reachable
  from any dispatch path). No grant means no authority, and
  `CommandBus.admit/2`'s existing `:authority_required` refusal fails the
  dispatch closed before the Ash action runs, before any record is written,
  and before any receipt is committed.

  **`:observe` skills are unaffected** -- `admit/2` admits them
  unconditionally, by design, and they need no grant.

  **Replay is preserved.** `AshA2A.Command.fingerprint/1` hashes
  `authority.token_id`, and a fresh token id per dispatch was a real,
  previously reproduced regression that broke `CommandBus` replay detection
  for every authenticated caller. `Grant.authorize/3` therefore still builds
  the authority through `from_verified_identity/2`, whose token id is the
  deterministic `AshA2A.Authority.grant_token_id/2`: the grant decision
  changes *whether* an authority is produced, never *which* one. Proven by a
  real regression test that dispatches the same real message twice as a
  granted caller and asserts the action body ran exactly once.

### Added

- `AshA2A.Authority.Grant` -- `authorize/3` (the dispatch-path grant
  decision), `grant/3`, `granted?/3`, and `policy/1`.
- `AshA2A.Authority.Broker.granted?/3` -- a new callback on the existing
  behaviour: "does a standing, unrevoked grant of this capability to this
  subject exist right now". Implemented in both shipped brokers as a pure
  read of the issued/revoked state each one already maintained for
  `issue/3`/`revoke/2`, and required to fail closed (return `false`) on any
  uncertainty. `issue/3` is deliberately not usable in its place: it has a
  real recording side effect and refuses a second call under the same grant
  token id, so per-dispatch use would both mutate broker state on every
  request and refuse every retry.
- `AshA2A.Authority.grant_token_id/2` -- the previously private deterministic
  `(subject, capability_id)` token id, made public because it is the shared
  key the authority constructor, `Grant.grant/3`, and every broker's
  `granted?/3` must all agree on.
- `AshA2A.Test.AuthorityGrantCase` -- real test-support helper that issues
  real grants into the real run-wide broker (no mocks, no policy bypass).

### Changed -- MIGRATION REQUIRED

- New config `config :ash_a2a, :authority_policy, mode`, defaulting to
  **`:broker`** (fail-closed). The pre-fix behavior remains available,
  explicitly, as `:transport_verified_grants_capability`, which logs a real
  warning naming the escalation on first use.
- New config `config :ash_a2a, :authority_broker, MyBroker` (or
  `{MyBroker, opts}`). Under the `:broker` policy with no broker configured,
  no grant can be proven, so **every `:change`/`:external_do` dispatch is
  refused** with `:authority_required`; a real warning names the missing
  configuration so the refusals are never silent.

  **Why fail-closed is the default, deliberately, despite being the more
  disruptive choice:** the alternative is shipping a library whose documented
  security property (S29) is known to be false while the default is in
  effect. A deployment that upgrades and changes nothing gets loud, typed,
  diagnosable refusals on consequential skills instead of a silent,
  invisible privilege escalation. Both modes are named, documented, and
  warned about, and switching is one config line in either direction.

  **To migrate:** configure a broker, start it in your supervision tree, and
  issue a real grant per `(principal, capability_id)` pair your callers
  legitimately need -- see `docs/how-to/authenticate-agent-requests.md`
  ("Authentication is NOT authority"). Or set
  `:authority_policy` to `:transport_verified_grants_capability` for a
  migration window, accepting the documented escalation.
- This repository's own test suite was migrated accordingly, not weakened:
  `config/test.exs` names the `:broker` policy and a real broker,
  `test/test_helper.exs` starts it, and each affected test issues its own
  real grants for exactly the capabilities it dispatches
  (`ash_a2a_agent_command_bus_test.exs`, `ash_a2a_ocel_default_path_sink_test.exs`,
  `ash_a2a_plug_tenant_actor_test.exs`, `ash_a2a_freedom_gym_hddl_plan_test.exs`,
  `ash_a2a_freedom_gym_phase_admission_test.exs`,
  `ash_a2a_freedom_gym_ocel_conformance_e2e_test.exs`,
  `ash_a2a_agent_semantic_replan_test.exs`). `:observe` and `:unknown`
  capabilities were deliberately left ungranted so the tests that assert on
  those paths still prove what they claim.

## [26.9.16] - 2026-09-16

No curated entry was cut for this release at the time; the milestone's
record lives in `docs/jira/v26.9.16/` and the git history (RFC-SA2A-002
Chicago gate work, canonical graph identity, RDF serialization gates,
GraphLaw engine work).

## [26.9.15] - 2026-09-15

No curated entry was cut for this release at the time; the milestone's
record lives in `docs/jira/v26.9.15/` and the git history.

## [26.9.14] - 2026-09-14

### Fixed (test suite, `--include external_api` only -- default `mix test` unaffected)
- **Real `:external_api` test suite made runnable end to end for the first
  time this session**: this environment carries real `ZAI_API_KEY`/
  `GROQ_API_KEY`/`ANTHROPIC_API_KEY` credentials, meaning the 5
  `@moduletag :external_api`-tagged files (excluded from the default `mix
  test` run) had never actually been exercised despite being fully
  runnable. Running them for real surfaced two real, disclosed findings,
  both fixed:
  - **Real cross-test rate-limit contention**: every real, unseamed
    live-LLM-calling test in the `:external_api` set
    (`ash_a2a_llm_profiles_test.exs`, `ash_a2a_freedom_gym_llm_test.exs`,
    `ash_a2a_freedom_gym_zai_test.exs`, `ash_a2a_agent_semantic_request_test.exs`,
    `ash_a2a_agent_semantic_replan_test.exs`) has a genuine interaction with
    `ash_a2a_zai_concurrency_ocel_test.exs`'s real 50-way concurrency probe
    when the full suite runs together: the probe genuinely exhausts the
    real ZAI API's rate limit (confirmed via real HTTP 429 responses), and
    a real-but-slower call attempted shortly after -- non-deterministically,
    depending on real rate-limit recovery timing, not a fixed test order --
    can then exceed both `A2A.Agent.call/3`'s own 60s `GenServer.call`
    default and ExUnit's own 60s test-process default before the real API
    recovers. Fixed by raising both real timeout layers
    (`timeout: 170_000` on the call option, `@tag timeout: 180_000` on the
    test) on every real unseamed LLM-call site across all 5 files, matching
    the pattern `ash_a2a_zai_concurrency_ocel_test.exs` itself already
    established. Confirmed via repeated real full-suite reproduction (3
    real timeouts in one run, 1 more in a different file on the next run
    after a partial fix, 0 in the fully-converged run) -- not assumed fixed
    after the first partial pass.
  - `ash_a2a_freedom_gym_ocel_conformance_e2e_test.exs` (the real
    end-to-end HDDL-plan -> A2A dispatch -> OCEL -> POWL-conformance loop
    against a real `beam4pm` `BeamPM.OcelIngest.Router` server) had never
    run in this session either -- confirmed genuinely passing once a real
    local `beam4pm` server instance was started for real and made
    reachable at its default `OCEL_INGEST_URL`.
  Final, fully converged result, real and reproduced: `mix test --include
  external_api` -- **3 doctests, 9 properties, 347 tests, 0 failures, 0
  skipped** (with the real `beam4pm` server up). None of this affects the
  default `mix test` run (still `3 doctests, 9 properties, 340 tests, 0
  failures (7 excluded)`, unchanged, reconfirmed after every fix) -- these
  fixes only matter when running the full suite with `--include
  external_api`, an opt-in, credential-dependent validation mode.

### Added
- **Real `ash_oban` `scheduled_actions` (cron) usage**: `mix.exs` declared
  `{:ash_oban, "~> 0.8"}` with zero resource using it anywhere in this
  repository until now. `AshA2A.Test.Fixture.ScheduledSweep`
  (`test/support/scheduled_sweep_fixture.ex`) declares a real
  `oban do scheduled_actions do schedule ... end end` cron entry, qualified
  by `test/ash_a2a/scheduled_sweep_qualification_test.exs` against a real
  Postgres-backed `oban_jobs` table via `AshOban.Test.schedule_and_run_triggers/2`
  (Oban's own real, documented drain-queue test helper — no hand-rolled
  scheduler, no mocked cron clock). Note for integrators: the installed
  `ash_oban` version's generated worker invokes a scheduled action's `run/2`
  purely through the generic-action path (`Ash.ActionInput`/
  `Ash.run_action!`) regardless of whether the target is a `:create` or
  generic `:action` — point `scheduled_actions`' `action:` at a real generic
  `:action` that performs the create internally, not directly at a `:create`
  action, or the job discards with `No such action ... of type :action`.
- **`AshA2A.ReceiptStore.Ekv`**: a real, on-disk-persisted `ReceiptStore`
  implementation backed by the `:ekv` dependency (promoted out of
  `only: :test` — it is now a real, non-test collaborator, the same
  precedent as the earlier `:plug` promotion). Closes the previous gap
  where the only shipped store (`AshA2A.ReceiptStore.Memory`) lost every
  receipt on process restart. `claim/2`/`commit/2`/`fetch/2` replicate
  `Memory`'s replay / `:command_conflict` / `:in_flight` decision logic
  against real durable storage. `AshA2A.Application.receipt_store_children/0`
  auto-wires a supervised `EKV` child when `:ash_a2a, :receipt_store` is
  configured as `AshA2A.ReceiptStore.Ekv`, configurable via
  `:ash_a2a, :receipt_store_ekv_opts`.
- **`AshA2A.Receipt.standing` vocabulary**: `:durable`, alongside the
  existing `:observed`. `CommandBus.run/4` marks a committed receipt
  `:durable` only when the configured store exports `durable?/0 -> true`
  (checked via the same `Code.ensure_loaded?`/`function_exported?` idiom
  already used for `DurableServer`/`FLAME` provider detection — no
  hardcoded module allowlist). `AshA2A.ReceiptStore.Memory` is unaffected;
  its receipts still carry `standing: :observed`.
- **Typed per-skill arguments in the capability index**:
  `AshA2A.CapabilityIndex.Compiler.project/3` now derives real
  `AshA2A.Argument` entries from `Ash.Resource.Info.action/2`'s real
  `arguments` (public actions) and, for `:create`/`:update`, from
  `action.accept`-derived attributes — closing a gap `AshA2A.Skill`'s own
  moduledoc had already promised ("Action arguments are always derived
  from Ash introspection") but `project/3` never implemented, leaving
  every skill's `arguments` field hardcoded to `[]`. The wire
  `A2A.AgentCard` projection still cannot carry per-argument schema data
  (the vendored `A2A.AgentCard` skill struct has no schema field — a real,
  separate constraint of that dependency, not worked around here); the
  real, useful surface is the in-process `AshA2A.Info.capability_index/1`
  and `AshA2A.Info.skill/2` API, which an in-process composer can call
  directly.

### Fixed
- **`AshA2A.FlamePlacementTest` real happy-path coverage**: the only
  existing FLAME test wrapped its entire body in
  `unless FLAME.available?() do ... end` with no else branch, so in any
  environment where FLAME is actually available (including this one) the
  test passed vacuously and never exercised the real
  `CommandBus`-through-`FLAME` path. Added a real integration test against
  FLAME's own documented local execution mode (a real `FLAME.Pool` on
  `FLAME.LocalBackend`, not a mock), asserting on the real returned
  receipt/placement structs including a genuine replay round-trip. Also
  fixed a real bug found while writing it: the module's own
  `alias AshA2A.{..., Execution.FLAME, ...}` shadowed the bare `FLAME`
  name, so an unqualified `{FLAME.Pool, ...}` child spec resolved to the
  nonexistent `AshA2A.Execution.FLAME.Pool`.
- **OCEL double-event emission on `CommandBus`-routed dispatch, fixed**:
  every CommandBus-routed dispatch previously fired two independent OCEL
  events for one logical action ([:ash_a2a, :dispatch, :stop] and
  [:ash_a2a, :receipt, :committed] both reaching the sink). A per-process
  correlation marker now stashes the dispatch span's data and merges it
  into the single receipt-derived event; direct `Dispatcher.dispatch/5`
  callers are unaffected. Resolves the item the parallel v26.9.14 release-
  closure work below disclosed as open and unresolved.
- **`mix ash_a2a.install` detect-and-merge extensions**: running install
  against a module that already declares an `extensions:` list no longer
  adds a duplicate key -- uses `Spark.Igniter.add_extension/5`, matching
  `ash_r2rml.install.ex`'s own established pattern.
- **`docs/PHOENIX_RUNTIME_PRIOR_ART_AUDIT.md`**, closing GitHub issue #11:
  `DurableServer`/`Group`/`Presence` classified Reuse, `FLAME` classified
  Compose, each backed by real `mix test` output per subsystem.
- **`AshA2A.SemanticSubject`**: A2A command/receipt identity bound to a
  semantic graph digest + generated-projection digest + manufacturer
  digest, folded into `Command.fingerprint/1` and copied into `Receipt`.
  `CommandBus` remains the only later DO path; `SemanticSubject` grants no
  authority and does not change `Receipt.standing`.

- **Explicit production semantic-request A2A surface**: a resource/domain
  opts in via `a2a do semantic_requests true end` (real, compiled DSL
  truth, `AshA2A.Info.semantic_requests_enabled?/1`); a caller opts in by
  setting `:semantic_request`/`"semantic_request"` message metadata to
  `true` (the same atom-then-string convention `:skill` metadata already
  uses). Both gates must be true, or dispatch falls straight through to
  ordinary skill resolution exactly as before -- never a silent fallback
  for an unrecognized skill name or arbitrary free text. Routes to
  `AshA2A.Semantic.Compiler.compile/3` for real, converting the resulting
  `ExecutionPackage` into a real `AshA2A.Dispatcher.reply()` via
  `ExecutionPackage.to_reply/1` (candidate-standing, `authority: none`
  evidence only).
- **Receipt-driven replanning**, automatic only for a continuation
  carrying a prior `ExecutionPackage`'s fingerprint (`:continuation_fingerprint`
  message metadata): a follow-up semantic request correlates back to the
  real committed `AshA2A.Receipt` that closed the original package and
  routes through `AshA2A.Semantic.Compiler.replan/4` for real
  (`Feedback.from_receipt/2` -> `PlanningIR.with_observation/2` ->
  re-synthesis) -- never a fresh compile, never auto-DO. A continuation
  fingerprint with no matching committed receipt is refused closed
  (`:continuation_receipt_not_found`). New `AshA2A.Semantic.PackageStore`
  (started alongside the default receipt store) correlates a package's
  one-way content-addressed fingerprint back to the full struct
  `replan/4` needs.
- **Real Oban integration** (`AshA2A.Delivery.Oban`): a real Postgres-backed
  `oban_jobs` table and a real `Oban.Worker` reconstructing an admitted
  `AshA2A.Command` from persisted job args and re-admitting through
  `CommandBus` -- proving queue acceptance != execution receipt and that
  Oban's at-least-once delivery replays through `CommandBus` rather than
  double-executing.
- **Real AshStateMachine integration** (`AshA2A.TaskLifecycle`): a real
  fixture resource genuinely transitions state through the real extension
  (`possible_next_states/2` now returns real extension-sourced values
  instead of the `:unsupported` degrade path for an opted-in resource).
- **Real Reactor DAG execution**: `AshA2A.Reactor.CommandWorkflow` composes
  real steps run through the actual `Reactor.run/2` engine (previously
  only the `Reactor.Step` callback contract had ever been exercised, via a
  bare function call) -- proving a deliberately unauthorized command halts
  the real Reactor run before any receipt commits or record is created.
- **Real single-node DurableServer restart evidence**: a real managed
  process is really killed (`Process.exit/2`) and the real dependency's
  own lifecycle manager really restarts it under real supervision with
  real recovered state -- real cross-node rehome remains a disclosed,
  separate gap (see below).
- **Real distributed BEAM peer-node evidence**: a genuine second node via
  OTP 28's `:peer` module, real `:nodedown` delivery, and a real
  cross-node `Group` membership purge on node loss -- proving
  `TaskID != PID != Node` with real distributed evidence.
- **Real Group, FLAME, and ash_r2rml exercises**: `AshA2A.Topology.Group`
  against a real running registry; `AshA2A.Execution.FLAME` placing a real
  `CommandBus.run/4` dispatch on a distinct real process via
  `FLAME.LocalBackend`; a real fixture genuinely declaring the `AshR2RML`
  extension with a real, admitted subject map (previously only the
  refusal path had ever been exercised).
- **Real OCEL sink for the default dispatch path**: a real local sink
  genuinely receives real HTTP POSTs derived from a real committed
  Receipt for a CommandBus-routed dispatch through the default `Agent`
  path.
- Architecture verifier extended 4 -> 9 real checks (`mix
  ash_a2a.verify_architecture`); real property/fuzz suite
  (`test/ash_a2a_property_fuzz_test.exs`); real concurrency/replay stress
  test (30 concurrent racers, same command_id, exactly one execution);
  consolidated real failure-injection suite; performance harness extended
  to 8 benchmarked operations.

### Fixed
- `Oban.Testing.perform_job/2` crashed (`DateTime.diff/3`
  `FunctionClauseError`) on a job fetched straight off the DB because
  `attempted_at` is nil until a real dequeue happens -- worked around with
  a real Ecto `dequeue!/1` step mirroring Oban's own producer SQL.
- `DurableServer.Backends.EKVStore` round-trips state as a native
  atom-keyed term, not string-keyed JSON -- the pre-existing
  `DurableServerFixture`'s `load_state/2` clause never actually matched
  this backend and silently fell through to a default, latent only
  because that fixture was never restarted before this release's real
  restart test existed.

### Changed
- `docs/explanation/architecture.md`'s "ecosystem adapters" section,
  stale since earlier dependency additions, corrected: `oban`,
  `ash_oban`, `ash_state_machine`, `flame`, `durable_server`, and the
  `group`/`phoenix_pubsub` transitive/direct deps are all real, and every
  adapter now has a real qualification test cited by name.

### Disclosed, not silently resolved
- DurableServer cross-node rehome (a second node taking over an orphaned
  task) remains unexercised; only real single-node restart is proven.
- A resource author can still explicitly declare `consequence: :observe`
  on an otherwise-mutating action via source-code DSL override -- an
  intentional escape hatch, never something a remote caller can trigger.
- `AshA2A.Topology.Group` currently has unit-test coverage only, no
  live-process integration test, unlike `DurableServer`/`Presence`/`FLAME`
  (recorded in `docs/PHOENIX_RUNTIME_PRIOR_ART_AUDIT.md`).

## [26.9.13] - 2026-09-13

### Added
- **Semantic closed-loop pipeline** (`AshA2A.Semantic.{Source,IR,Admission,
  Ontology,PlanningIR,Schema,Vocabulary,Compiler,Feedback,ExecutionPackage}`,
  `AshA2A.Planning.SemanticSynthesis`): text → admitted semantic IR →
  ontology → PlanningIR → LLM-synthesized HDDL/FOND candidate → canonical
  capability re-admission → `ExecutionPackage`, with real solver
  verification against the CI-built `native/hddl_cli` (ferroplan) binary.
  Full real-collaborator (zero-mock) test coverage across all 11 modules.
  **Not yet wired to a production A2A caller** — reachable today only from
  tests; see "Consequence semantics" below for the closest related fix.
- **`AshA2A.Skill.consequence`**: `:observe` / `:change` / `:external_do` /
  `:unknown`, computed once at compile time
  (`AshA2A.CapabilityIndex.Compiler`) from the real Ash `action.type`, with
  an explicit `a2a do skill ..., consequence: ... end` override. Real
  capability truth, not a value re-derived ad hoc from `action.type` at
  dispatch time — `action.type` alone cannot distinguish a pure generic
  `:action` from a real consequence-bearing one. An unclassified (`:unknown`)
  capability is refused closed (`:consequence_unclassified`) rather than
  defaulting to either safe-to-skip or safe-to-execute.

### Changed
- **`CommandBus` is now on the default `AshA2A.Agent.__dispatch__` path**
  for every `:change`/`:external_do`-consequence skill — the gap the
  26.9.12 entry above flagged as "not yet wired." A real
  `AshA2A.Command` is built per dispatch (`command_id` is the real,
  protocol-native `A2A.Message.message_id`, not a fresh id per call, so a
  genuine client retry replays instead of re-executing, and a same-id/
  different-content retry is a real `:command_conflict` refusal); real
  `AshA2A.Authority` is synthesized from the already-verified transport
  identity (`AshA2A.Authority.from_verified_identity/2`, deterministic
  `token_id` so replay fingerprinting stays stable across retries) and
  fails `:change`/`:external_do` admission closed for an unauthenticated
  caller. `:read` and `:observe`-classified skills stay on the direct
  dispatch path (a streaming `:read` reply would otherwise have its real
  `Enumerable.t()` collapsed by `Receipt.from_reply/4`'s `summarize/1`).
- `AshA2A.Telemetry.OcelForwarder.attach!/0` is now called from
  `AshA2A.Application.start` — previously real and correct but never
  attached outside tests, so a host got no OCEL forwarding by default even
  after configuring `:ocel_ingest_url`. Idempotent and a no-op cost when
  `:ocel_ingest_url` is unconfigured.
- `AshA2A.Dispatcher`'s skill lookup now matches a caller-supplied selector
  against a skill's canonical `id` as well as its `name` (previously
  `name`-only), matching `AshA2A.Info.skill/2`'s existing two-field match —
  a selector-consistency fix between the direct-dispatch and
  `CommandBus`-routed lookup paths, not a security change (fail-closed
  either way).

### Fixed
- `AshA2A.Dispatcher.run_update/4` passed the raw dispatch input (including
  the resolved primary-key field) straight to `Ash.Changeset.for_update/3`,
  raising a spurious `Ash.Error.Invalid.NoSuchInput` for any update action
  whose `accept` list doesn't also happen to include its own primary-key
  attribute. Fixed the same way `run_destroy/4` already was: strip the
  resolved primary-key field(s) before building the update changeset.
- `AshA2A.Authority.from_verified_identity/2` was minting a fresh random
  `token_id` on every call; since `AshA2A.Command.fingerprint/1` hashes the
  authority's `token_id`, this made every authenticated retry's fingerprint
  differ from the last, permanently defeating `CommandBus` replay detection
  with a spurious `:command_conflict`. Fixed by deriving a deterministic
  `token_id` from `{subject, capability_id}` — a synthesized standing claim
  must be idempotent for the same pair, unlike a one-time-issued credential
  grant.

## [26.9.12] - 2026-09-12

### Added
- **Canonical capability projection** (`AshA2A.CapabilityIndex.Compiler`):
  skills are now derived live from every public Ash action
  (`Ash.Resource.Info.public_actions/1`), not just explicitly-declared
  `a2a do skill ... end` entries — those now act as overrides/renames on
  top of the canonical set rather than an allowlist. Skill `id` is a
  fully-qualified `<Resource>.<action>` identity (avoids collisions across
  resources sharing a short skill name); `name` carries the short,
  human-facing name.
- **Typed command/receipt machinery** (`AshA2A.Command`, `AshA2A.Identity`,
  `AshA2A.CommandBus`, `AshA2A.ReceiptStore` + `ReceiptStore.Memory`,
  `AshA2A.RuntimeReceipt`): command/task/agent/principal identity are
  separately-typed values; `CommandBus.run/4` provides a real
  admit → claim → dispatch → receipt → telemetry path with idempotent
  replay on duplicate command identity and refusal on conflicting reuse.
  **Not yet wired into the default `AshA2A.Agent.__dispatch__` path** —
  available today as opt-in infrastructure (used by the Reactor step,
  Oban, and FLAME adapters below), not a mandatory boundary every A2A call
  passes through.
- **Admission bridge** (`AshA2A.Authority`, `AshA2A.Planning.candidate_fence/1`):
  a real, non-fixture SELECT-vs-DO authority check and a planner-candidate
  fence that refuses any candidate claiming standing beyond `:candidate`/
  authority beyond `:none`. Same wiring caveat as above — real, tested,
  not on the default path yet.
- **Lifecycle/Reactor composition** (`AshA2A.TaskLifecycle`,
  `AshA2A.Reactor.ExecuteCommand`): a thin adapter deferring transition
  legality to `AshStateMachine.possible_next_states/1,2` when that
  extension is installed (it is not currently a project dependency, so
  this degrades to `{:error, {:unsupported, :ash_state_machine}}` in this
  repo today), plus a Reactor step wired to `CommandBus.run/4`.
- **Ecosystem adapter seams** (`AshA2A.Delivery.Oban`,
  `AshA2A.Topology.Group`, `AshA2A.Topology.Presence`,
  `AshA2A.Durability.DurableServer`, `AshA2A.Execution.FLAME`): one
  `Code.ensure_loaded?/1`-guarded, receipted adapter module per named
  ecosystem primitive (provider-substitutable by design), each with real
  restart/node-loss or payload-shape test coverage. **None of the six
  underlying libraries (AshStateMachine, AshOban/Oban, Group,
  DurableServer, Phoenix Presence, FLAME) is currently a real dependency
  of this project** — every adapter self-degrades to an `:unsupported`
  refusal until a real provider is added.
- **Semantic/OCEL evidence projection** (`AshA2A.SemanticProjection`):
  real `ocel_event/1`, `capability/2`, `r2rml_mapping_result/1` helpers
  projecting receipts into OCEL/RDF-shaped evidence.

### Fixed
- `AshA2A.Telemetry.OcelForwarder` now forwards a real `relationships`
  entry (from the dispatched object's real identity) alongside dispatch
  attributes — previously dropped in an intermediate refactor, restored
  during this release's merge.
- Six test files updated for the canonical-capability-projection semantics
  change (capability-id shape, `:ambiguous_skill` disambiguation for
  fixtures that now correctly expose 2+ real skills, `DslError` wording,
  supervision-tree assertions accounting for the new
  `AshA2A.ReceiptStore.Memory` default child).

### Docs
- Added a [Diataxis](https://diataxis.fr/)-structured documentation set
  under `docs/`: **tutorials** (`docs/tutorials/`), **how-to guides**
  (`docs/how-to/`), **reference** (`docs/reference/`), and **explanation**
  (`docs/explanation/`). README.md's inline usage walkthrough was trimmed
  to a short quick-start and now links into this set.

### Status note
This release's admission/receipt/lifecycle/ecosystem-adapter machinery is
real, committed, and independently tested, but **not yet the architecture's
enforced default path** — `AshA2A.Agent.__dispatch__` still calls
`AshA2A.Dispatcher.dispatch/5` directly. Wiring `CommandBus` into that
default path, and adding real ecosystem-primitive dependencies, are
deliberately deferred to a follow-up release, not silently implied by this
one.

### Candidate architecture design record

The stacked PR series #1 through #6 defined one candidate sequence:
derive capabilities from Ash public actions, separate machine identities,
add the receipted command path, compose lifecycle behavior with
AshStateMachine and Reactor, separate background delivery through Oban,
and project Group as runtime topology. The design keeps task, command,
execution, runtime, delivery, and topology identities distinct instead of
collapsing them into one agent identifier. (Historical design-state note
written while that work was still CANDIDATE; the shipped behavior is
described in the sections above.)

## [26.9.10] - 2026-09-10

### Added
- Spark DSL for defining A2A (Agent-to-Agent) agents, actions, and skills.
- Capability index (`AshA2A.CapabilityIndex`) with `Validator` and `AgentCardBuilder`
  decomposed as separate modules.
- Dispatcher for routing A2A requests to Ash actions/skills.
- Task history/context threading through to dispatch instead of being discarded.
- Installer for wiring `ash_a2a` into a host application.

### Fixed
- `AgentCard` `supported_interfaces` proto-drift.
- Dispatcher `KeyError` on skill lookup.
- `__spark_metadata__` verification issues.
