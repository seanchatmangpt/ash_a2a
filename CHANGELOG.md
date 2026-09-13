# Changelog

All notable changes to `ash_a2a` are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project intends to adhere to [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
once it reaches 1.0.

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

Nothing yet.
