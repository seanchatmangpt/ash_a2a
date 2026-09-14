# Changelog

All notable changes to `ash_a2a` are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project intends to adhere to [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
once it reaches 1.0.

## [26.9.14] - 2026-09-14

### Added
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
- **`CommandBus` is now on the default `AshA2A.Agent.__dispatch__/3` path**
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
  `AshA2A.Application.start/2` — previously real and correct but never
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
