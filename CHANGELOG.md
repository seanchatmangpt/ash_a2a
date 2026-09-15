# Changelog

All notable changes to `ash_a2a` are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project intends to adhere to [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
once it reaches 1.0.

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

## [Unreleased]

### v26.9.12 candidate architecture

The stacked PR series #1 through #6 now defines one candidate sequence: derive capabilities from Ash public actions, separate machine identities, add the receipted command path, compose lifecycle behavior with AshStateMachine and Reactor, separate background delivery through Oban, and project Group as runtime topology.

The design keeps task, command, execution, runtime, delivery, and topology identities distinct instead of collapsing them into one agent identifier.

DurableServer is the next runtime-continuity layer and is tracked in issue #8. FLAME and Phoenix Presence remain later optional composition points. This section records design state only; the stacked work remains CANDIDATE until fresh execution evidence exists.
