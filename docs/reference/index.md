# Module Reference Index

Status legend:

- **ALIVE** — real code, wired into the default dispatch path, exercised by tests.
- **ALIVE (opt-in trigger)** — real code on the default dispatch path, but only reached
  when its own real trigger condition is met (e.g. a `:change`/`:external_do` skill for
  `CommandBus`, or the semantic-request DSL/metadata gate) — not a parallel/bypassable
  route, a conditional branch of the one real path.
- **REAL_INTEGRATED (provider, opt-in)** — real adapter module, its target dependency
  (Oban, `Group`, Phoenix Presence, `DurableServer`, FLAME, `AshStateMachine`) is a real,
  resolvable dependency of this project, and a real Chicago-style qualification test
  exercises it against a genuinely running collaborator. Still opt-in: a resource that
  never uses the adapter never pays for or depends on the provider being present.
- **PARTIAL (not default path)** — real code, tested, but not called by
  `AshA2A.Agent.__dispatch__`'s default path under any condition; reached only via an
  explicit alternate caller (Reactor step, planner output, etc.).

As of v26.9.14 (re-verified at v26.9.21), every module previously listed
`ADAPTER-SEAM (no real provider)` has a real, dependency-satisfied, tested
integration -- see
[Architecture](../explanation/architecture.md#the-ecosystem-adapters-are-real-integrations-not-just-seams)
for the full evidence table.

Reference pages in this quadrant:

- [DSL reference](dsl.md) — the `a2a` section, `skill`, `hddl_operator`,
  `semantic_requests`, and compile-time verification.
- [Configuration](configuration.md) — every application config key and
  environment variable the library reads.
- [Telemetry events](telemetry.md) — the production event catalog with
  payloads.
- [Mix tasks](mix-tasks.md) — the 13 shipped tasks.
- [A2A endpoint contract](a2a-endpoint-contract.md) — the served HTTP
  wire surface: card, JSON-RPC, errors, streaming, auth.

The module rows below cover the dispatch-relevant public surface with its
real integration status; full module API detail lives in the generated
ExDoc module documentation (HexDocs).

## Core (dispatch path)

| Module | Description | Status |
| --- | --- | --- |
| [`AshA2A.Agent`](https://hexdocs.pm/ash_a2a/AshA2A.Agent.html) | Generates a supervised `A2A.Agent` GenServer for an `AshA2A`-extended resource/domain. | ALIVE |
| [`AshA2A.Dispatcher`](https://hexdocs.pm/ash_a2a/AshA2A.Dispatcher.html) | Dispatches an inbound `A2A.Message` to the Ash action a persisted skill maps to; the terminal execution layer `CommandBus.run/4` itself calls. | ALIVE |
| [`AshA2A.Info`](https://hexdocs.pm/ash_a2a/AshA2A.Info.html) | Introspection facade; derives the capability index from `Ash.Resource.Info.public_actions/1`, including real per-skill typed arguments. | ALIVE |
| [`AshA2A.CapabilityIndex`](https://hexdocs.pm/ash_a2a/AshA2A.CapabilityIndex.html) | Public facade over the derived Ash-to-A2A capability projection. | ALIVE |
| [`AshA2A.CapabilityIndex.Compiler`](https://hexdocs.pm/ash_a2a/AshA2A.CapabilityIndex.Compiler.html) | Derives the capability index from `Ash.Resource.Info.public_actions/1` plus residual overrides; derives real `AshA2A.Argument` entries from Ash action introspection. | ALIVE |
| [`AshA2A.CapabilityIndex.AgentCardBuilder`](https://hexdocs.pm/ash_a2a/AshA2A.CapabilityIndex.AgentCardBuilder.html) | Deterministically projects a compiled capability index into `A2A.AgentCard.t()`. | ALIVE |
| [`AshA2A.CapabilityIndex.Validator`](https://hexdocs.pm/ash_a2a/AshA2A.CapabilityIndex.Validator.html) | Fail-closed validation that every residual skill override names a real, public Ash action. | ALIVE |
| [`AshA2A.ContextResolver`](https://hexdocs.pm/ash_a2a/AshA2A.ContextResolver.html) | Resolves `actor`/`tenant`/`context`/`domain`/`history` from an `A2A.Message` at the trust boundary. | ALIVE |
| [`AshA2A.ExecutionContext`](https://hexdocs.pm/ash_a2a/AshA2A.ExecutionContext.html) | Struct holding the resolved, trust-boundary-crossed dispatch context built by `ContextResolver`. | ALIVE |
| [`AshA2A.Skill`](https://hexdocs.pm/ash_a2a/AshA2A.Skill.html) | Derived reference to one public Ash action exposed through A2A; also the DSL entity target. | ALIVE |
| [`AshA2A.Argument`](https://hexdocs.pm/ash_a2a/AshA2A.Argument.html) | Spark DSL entity for `a2a do skill ... do argument ... end end`; kept for source compatibility, ignored by compilation (real arguments are derived from Ash introspection, not this DSL entity). | ALIVE |
| [`AshA2A.Dsl`](https://hexdocs.pm/ash_a2a/AshA2A.Dsl.html) | Spark DSL extension defining the optional residual `a2a do skill ... end` override block and the `semantic_requests` opt-in flag. | ALIVE |
| [`AshA2A.Verify`](https://hexdocs.pm/ash_a2a/AshA2A.Verify.html) | Spark DSL verifier checking every override points at a real public Ash action. | ALIVE |
| [`AshA2A.ArchitectureVerifier`](https://hexdocs.pm/ash_a2a/AshA2A.ArchitectureVerifier.html) | Executable architecture-invariant checks behind `mix ash_a2a.verify_architecture` (CI gate). | ALIVE |
| [`AshA2A.Transformers.BuildCapabilityIndex`](https://hexdocs.pm/ash_a2a/AshA2A.Transformers.BuildCapabilityIndex.html) | Spark DSL transformer that persists residual overrides and subject kind (resource/domain) at compile time. | ALIVE |
| [`AshA2A.MetadataKey`](https://hexdocs.pm/ash_a2a/AshA2A.MetadataKey.html) | Shared atom-or-string map lookup helper used by `ContextResolver`, `Agent`, and `Dispatcher`. | ALIVE |
| [`AshA2A.Application`](https://hexdocs.pm/ash_a2a/AshA2A.Application.html) | OTP application starting the A2A agent supervisor and the configured receipt store (`Memory` by default, `Ekv` or a host-supplied module otherwise). | ALIVE |

## LLM resolution

| Module | Description | Status |
| --- | --- | --- |
| [`AshA2A.LLMProfiles`](https://hexdocs.pm/ash_a2a/AshA2A.LLMProfiles.html) | Resolves an abstract Ash action role (e.g. `:semantic_reasoner`) to a concrete `req_llm`/`ash_ai` model spec via `config :ash_a2a, :llm_profiles`. | ALIVE |

## Admission & receipts

As of v26.9.14, `AshA2A.Agent.__dispatch__` routes every `:change`/`:external_do`
skill through this layer by default -- it is no longer a parallel, opt-in-only route.
See [Architecture](../explanation/architecture.md).

| Module | Description | Status |
| --- | --- | --- |
| [`AshA2A.Authority`](https://hexdocs.pm/ash_a2a/AshA2A.Authority.html) | Explicit authority evidence bound to a principal and one capability; synthesized per call from the already-verified transport identity for default-path dispatch. | ALIVE (opt-in trigger) |
| [`AshA2A.CommandBus`](https://hexdocs.pm/ash_a2a/AshA2A.CommandBus.html) | Canonical receipted route from an admitted `AshA2A.Command` to the Ash dispatcher, enforcing capability/identity/replay checks. Default dispatch route for consequence-bearing skills. | ALIVE (opt-in trigger) |
| [`AshA2A.Command`](https://hexdocs.pm/ash_a2a/AshA2A.Command.html) | Consequence-bearing command envelope binding identity, capability id, admitted input, optional authority, and (since v26.9.15) `AshA2A.SemanticSubject` evidence; also carries an optional `:spg_identity` (`AshA2A.SpgIdentity`) whose token is folded into the deterministic fingerprint digest (since v26.9.25, d660a9e). | ALIVE (opt-in trigger) |
| [`AshA2A.Identity`](https://hexdocs.pm/ash_a2a/AshA2A.Identity.html) | Typed machine identity (`:principal`, `:agent`, `:task`, `:command`, `:execution`, `:runtime`) used across the boundary. | ALIVE (opt-in trigger) |
| [`AshA2A.SemanticSubject`](https://hexdocs.pm/ash_a2a/AshA2A.SemanticSubject.html) | Binds command/receipt identity to a semantic graph digest, generated-projection digest, and manufacturer digest. Identity/evidence only -- grants no authority. | ALIVE (opt-in trigger) |
| [`AshA2A.SpgIdentity`](https://hexdocs.pm/ash_a2a/AshA2A.SpgIdentity.html) | SPG evidence identity carried across commands, receipts, and OCEL projections; `graph_id`/`graph_version`/`node_id` required, `edge_id`/`projection_family` optional; `new/1` returns `{:ok, t()} | {:error, {:refused_spg_identity, field}}`. Evidence only -- grants neither capability nor authority. | ALIVE (opt-in trigger) |
| [`AshA2A.Receipt`](https://hexdocs.pm/ash_a2a/AshA2A.Receipt.html) | Replayable evidence struct for one `AshA2A.CommandBus` command attempt; `standing` is `:observed` (default store) or `:durable` (a store that declares `durable?/0`). | ALIVE (opt-in trigger) |
| [`AshA2A.ReceiptStore`](https://hexdocs.pm/ash_a2a/AshA2A.ReceiptStore.html) | Behaviour for replay-safe command receipt storage distinguishing replay from conflict. | ALIVE (opt-in trigger) |
| [`AshA2A.ReceiptStore.Memory`](https://hexdocs.pm/ash_a2a/AshA2A.ReceiptStore.Memory.html) | In-memory `GenServer` reference implementation of `AshA2A.ReceiptStore`; the default, started by `AshA2A.Application`. No persistence across a restart. | ALIVE (opt-in trigger) |
| [`AshA2A.ReceiptStore.Ekv`](https://hexdocs.pm/ash_a2a/AshA2A.ReceiptStore.Ekv.html) | Real on-disk-persisted `AshA2A.ReceiptStore` backed by `:ekv`; survives a process restart. Configure via `config :ash_a2a, :receipt_store, AshA2A.ReceiptStore.Ekv`. | ALIVE (opt-in trigger) |
| [`AshA2A.ReceiptStore.ActuationClaimLease`](https://hexdocs.pm/ash_a2a/AshA2A.ReceiptStore.ActuationClaimLease.html) | Abandoned-actuation (effect-claim) reclamation after the claim lease expires — ends permanent `:in_flight` refusals after a crash mid-DO (Memory and Ekv stores). | ALIVE |
| [`AshA2A.Receipt.Binding`](https://hexdocs.pm/ash_a2a/AshA2A.Receipt.Binding.html) | Complete receipt identity binding (RFC-SA2A-002 §40 Gate 9, §128 evidence-laundering posture). `AshA2A.Receipt` gained a `:binding` field, and `CommandBus.run/4` accepts a `:chain_predecessor` opt that binds each committed receipt into its evidence chain; wired through `CommandBus`, `Reconciliation`, `Postcondition`. | ALIVE (opt-in trigger) |
| [`AshA2A.Receipt.EvidenceChain`](https://hexdocs.pm/ash_a2a/AshA2A.Receipt.EvidenceChain.html) | Durable, hash-linked receipt evidence chain for offline replay (RFC-SA2A-001 S32; RFC-SA2A-002 §41 Gate 10, §92 B8). | PARTIAL (not default path) |
| [`AshA2A.Receipt.OfflineReplay`](https://hexdocs.pm/ash_a2a/AshA2A.Receipt.OfflineReplay.html) | Fresh offline replay engine over the evidence chain (RFC-SA2A-001 S32; RFC-SA2A-002 §41 Gate 10, §92 B8). | PARTIAL (not default path) |
| [`AshA2A.Receipt.Replay`](https://hexdocs.pm/ash_a2a/AshA2A.Receipt.Replay.html) | RFC-SA2A-001 S32 replay: reconstructs the semantic basis of an execution from its receipt without repeating the execution; consumed by `Semantic.Attestation` and the replay courts. | PARTIAL (not default path) |
| [`AshA2A.Authority.Grant`](https://hexdocs.pm/ash_a2a/AshA2A.Authority.Grant.html) | The grant decision layer: standing `grant/3`/`revoke/3`/`renew/3`/`granted?/3` plus enumeration `list_grants/2` (via the broker's OPTIONAL `list_grants/2` callback; third-party brokers without it degrade to `:error`) for admin/audit tooling. Closes the S29 authentication-vs-authority escalation. | ALIVE (opt-in trigger) |
| [`AshA2A.Authority.Broker`](https://hexdocs.pm/ash_a2a/AshA2A.Authority.Broker.html) | Broker behaviour for standing grants; shipped reference implementations `Broker.InMemory` (single node, dev/tests) and `Broker.Ekv` (durable). | ALIVE (opt-in trigger) |
| [`AshA2A.BrceAnchor`](https://hexdocs.pm/ash_a2a/AshA2A.BrceAnchor.html) | Sole-DO fence: a consequence-bearing dispatch is refused unless `CommandBus` handed over a pending receipt anchor bound to that exact capability. | ALIVE |
| [`AshA2A.ReceiptOutbox`](https://hexdocs.pm/ash_a2a/AshA2A.ReceiptOutbox.html) | Filesystem receipt journal: `:pending` receipt persisted before dispatch, finalized after — crash-recovery evidence. | ALIVE (opt-in trigger) |
| [`AshA2A.Reconciliation`](https://hexdocs.pm/ash_a2a/AshA2A.Reconciliation.html) | Post-crash durable-evidence classifier over outbox + store (RFC-SA2A-002 §70/§71/§94). | ALIVE (opt-in trigger) |
| [`AshA2A.KillSwitch`](https://hexdocs.pm/ash_a2a/AshA2A.KillSwitch.html) | Class-level halt primitive (`trip/3`, `tripped?/1`, authority-gated `reset/4`); application-started, consulted only by explicit host opt-in. | ALIVE |
| [`AshA2A.OnCancel`](https://hexdocs.pm/ash_a2a/AshA2A.OnCancel.html) | Behaviour for the `skill` entity's `on_cancel` Ash-side compensation hook. | ALIVE (opt-in trigger) |
| [`AshA2A.Reactor.ExecuteCommand`](https://hexdocs.pm/ash_a2a/AshA2A.Reactor.ExecuteCommand.html) | `Reactor.Step` adapter that calls `AshA2A.CommandBus` for one admitted command inside a Reactor. | PARTIAL (not default path) |
| [`AshA2A.Reactor.CommandWorkflow`](https://hexdocs.pm/ash_a2a/AshA2A.Reactor.CommandWorkflow.html) | Real multi-step `Reactor.run/2` DAG composing command execution; a deliberately unauthorized command halts the real run before any receipt commits. | PARTIAL (not default path) |
| [`AshA2A.Reactor.BuildCommand`](https://hexdocs.pm/ash_a2a/AshA2A.Reactor.BuildCommand.html) | `Reactor.Step` that constructs an `AshA2A.Command` from step inputs for `CommandWorkflow`. | PARTIAL (not default path) |
| [`AshA2A.Reactor.ConfirmReceipt`](https://hexdocs.pm/ash_a2a/AshA2A.Reactor.ConfirmReceipt.html) | `Reactor.Step` that asserts on a committed `AshA2A.Receipt` within `CommandWorkflow`. | PARTIAL (not default path) |
| [`AshA2A.Planning.Candidate`](https://hexdocs.pm/ash_a2a/AshA2A.Planning.Candidate.html) | Planner-output struct with candidate-only standing and no DO authority. | PARTIAL (not default path) |
| [`AshA2A.TaskLifecycle`](https://hexdocs.pm/ash_a2a/AshA2A.TaskLifecycle.html) | Adapter over host-owned `AshStateMachine` task truth; declares A2A task vocabulary. `:ash_state_machine` is now a real dependency with a real qualification test. | REAL_INTEGRATED (provider, opt-in) |

## Semantic pipeline (opt-in production surface)

Reached only when a resource declares `a2a do semantic_requests true end` AND the caller
sets `:semantic_request` message metadata -- see
[Enable semantic requests](../how-to/enable-semantic-requests.md).

| Module | Description | Status |
| --- | --- | --- |
| [`AshA2A.Semantic.Compiler`](https://hexdocs.pm/ash_a2a/AshA2A.Semantic.Compiler.html) | `compile/3` and `replan/4` -- the real closed-loop entry points: text/receipt-evidence in, an admitted `ExecutionPackage` out. | ALIVE (opt-in trigger) |
| [`AshA2A.Semantic.Source`](https://hexdocs.pm/ash_a2a/AshA2A.Semantic.Source.html) | Real source-span admission over raw caller text. | ALIVE (opt-in trigger) |
| [`AshA2A.Semantic.IR`](https://hexdocs.pm/ash_a2a/AshA2A.Semantic.IR.html) | Admitted semantic intermediate representation. | ALIVE (opt-in trigger) |
| [`AshA2A.Semantic.Admission`](https://hexdocs.pm/ash_a2a/AshA2A.Semantic.Admission.html) | Fail-closed admission gate over extracted semantic content. | ALIVE (opt-in trigger) |
| [`AshA2A.Semantic.Ontology`](https://hexdocs.pm/ash_a2a/AshA2A.Semantic.Ontology.html) | Prior-art-first RDF/RDFS/OWL/PROV-O/etc. namespace registry and grounding. | ALIVE (opt-in trigger) |
| [`AshA2A.Semantic.PlanningIR`](https://hexdocs.pm/ash_a2a/AshA2A.Semantic.PlanningIR.html) | Planning-ready intermediate representation, `with_observation/2` folds replan feedback in. | ALIVE (opt-in trigger) |
| [`AshA2A.Planning.SemanticSynthesis`](https://hexdocs.pm/ash_a2a/AshA2A.Planning.SemanticSynthesis.html) | LLM-synthesized HDDL/FOND candidate generation via the sanctioned DI seam (`generate_object`). | ALIVE (opt-in trigger) |
| [`AshA2A.Semantic.Schema`](https://hexdocs.pm/ash_a2a/AshA2A.Semantic.Schema.html) | Schema admission for synthesized candidates. | ALIVE (opt-in trigger) |
| [`AshA2A.Semantic.Vocabulary`](https://hexdocs.pm/ash_a2a/AshA2A.Semantic.Vocabulary.html) | Canonical capability re-admission vocabulary. | ALIVE (opt-in trigger) |
| [`AshA2A.Semantic.ExecutionPackage`](https://hexdocs.pm/ash_a2a/AshA2A.Semantic.ExecutionPackage.html) | `standing: :candidate, authority: :none`-fenced package; `to_reply/1` converts it to a real `Dispatcher.reply()`, never a DO. | ALIVE (opt-in trigger) |
| [`AshA2A.Semantic.Feedback`](https://hexdocs.pm/ash_a2a/AshA2A.Semantic.Feedback.html) | `from_receipt/2` projects a real committed `Receipt` into replan observation input. | ALIVE (opt-in trigger) |
| [`AshA2A.Semantic.PackageStore`](https://hexdocs.pm/ash_a2a/AshA2A.Semantic.PackageStore.html) | Correlates a package's content-addressed fingerprint back to the full struct `replan/4` needs; started alongside the default receipt store. | ALIVE (opt-in trigger) |
| [`AshA2A.Semantic.Refusal`](https://hexdocs.pm/ash_a2a/AshA2A.Semantic.Refusal.html) | Canonical S42 refusal taxonomy; `classify/1` maps ~60 native refusal codes into 18 classes. | ALIVE (opt-in trigger) |
| [`AshA2A.Semantic.Standing`](https://hexdocs.pm/ash_a2a/AshA2A.Semantic.Standing.html) | HMAC-sealed standing-ledger transitions; makes semantic `standing` unforgeable. | ALIVE (opt-in trigger) |
| [`AshA2A.Semantic.IrAdmissionSeal`](https://hexdocs.pm/ash_a2a/AshA2A.Semantic.IrAdmissionSeal.html) | Anti-forgery HMAC seal on `Semantic.IR`; hand-built IR is refused downstream. | ALIVE (opt-in trigger) |
| [`AshA2A.Semantic.MachineExperience`](https://hexdocs.pm/ash_a2a/AshA2A.Semantic.MachineExperience.html) | Compiles one piece of reusable machinery (rule, shape, plan, or generator) back from a resolved UNKNOWN, keyed by the semantic class it closes: `register/2`, `compile_back/3`, `unregister/3` (real no-op on an unknown class). Consumed by `Semantic.Unknown` on the replan path. | ALIVE (opt-in trigger) |
| [`AshA2A.Semantic.HookReactor`](https://hexdocs.pm/ash_a2a/AshA2A.Semantic.HookReactor.html) | Bounded Knowledge-Hook reactor (RFC-SA2A-002 §60-§63, §87, §90): hook admission → intent construction/idempotency → bounded evaluate → cascade ceiling binding. Reached via the Chicago hook benches/courts. | PARTIAL (not default path) |

## Ecosystem adapters (real, dependency-satisfied integrations)

Each is `Code.ensure_loaded?/1`-guarded and degrades to `:unsupported` if its provider
is absent, but as of v26.9.14 every one of these providers is a real, resolvable
dependency of this project with a real qualification test exercising it -- see
[Architecture](../explanation/architecture.md) for the exact test-file evidence per row.

| Module | Description | Status |
| --- | --- | --- |
| [`AshA2A.Delivery`](https://hexdocs.pm/ash_a2a/AshA2A.Delivery.html) | Provider-neutral struct observing that a command was handed to an async delivery substrate. | PARTIAL (not default path) |
| [`AshA2A.Delivery.Oban`](https://hexdocs.pm/ash_a2a/AshA2A.Delivery.Oban.html) | Real Oban delivery adapter; a real `Oban.Worker` reconstructs the admitted `Command` and re-admits through `CommandBus`. | REAL_INTEGRATED (provider, opt-in) |
| [`AshA2A.Delivery.ObanAuthority`](https://hexdocs.pm/ash_a2a/AshA2A.Delivery.ObanAuthority.html) | Oban `perform/1` delivery authority: re-verifies LIVE broker standing at delivery time (not enqueue time), so a revoked grant refuses the async execution. | REAL_INTEGRATED (provider, opt-in) |
| [`AshA2A.Topology.Group`](https://hexdocs.pm/ash_a2a/AshA2A.Topology.Group.html) | Real adapter for the `Group` process/topology registry, including real cross-node purge-on-death; mutations return `RuntimeReceipt`. | REAL_INTEGRATED (provider, opt-in) |
| [`AshA2A.Topology.Presence`](https://hexdocs.pm/ash_a2a/AshA2A.Topology.Presence.html) | Real adapter for a host application's `Phoenix.Presence` module; mutations return `RuntimeReceipt`. | REAL_INTEGRATED (provider, opt-in) |
| [`AshA2A.Durability.DurableServer`](https://hexdocs.pm/ash_a2a/AshA2A.Durability.DurableServer.html) | Real adapter for Phoenix `DurableServer` task runtimes, keyed by A2A TaskID; real single-node kill+restart proven, cross-node rehome still unexercised (disclosed gap). | REAL_INTEGRATED (provider, opt-in) |
| [`AshA2A.Execution.FLAME`](https://hexdocs.pm/ash_a2a/AshA2A.Execution.FLAME.html) | Real FLAME placement adapter (`FLAME.LocalBackend` proven); the placed closure still calls `CommandBus` for admission. | REAL_INTEGRATED (provider, opt-in) |
| [`AshA2A.RuntimeReceipt`](https://hexdocs.pm/ash_a2a/AshA2A.RuntimeReceipt.html) | Evidence struct for consequence-bearing runtime/provider operations (topology, durability, execution adapters). | PARTIAL (not default path) |

## Telemetry & evidence

| Module | Description | Status |
| --- | --- | --- |
| [`AshA2A.Telemetry.OcelForwarder`](https://hexdocs.pm/ash_a2a/AshA2A.Telemetry.OcelForwarder.html) | Best-effort OCEL v2 telemetry egress. Exactly one event per CommandBus-routed dispatch (dispatch-span and receipt-committed fields merged, deduplicated); a direct `Dispatcher.dispatch/6` caller still gets its own dispatch event. Observational only. | ALIVE |
| [`AshA2A.Telemetry.RouterCounters`](https://hexdocs.pm/ash_a2a/AshA2A.Telemetry.RouterCounters.html) | In-process `:counters`-backed RequestRouter tier-split instrument: `new/0`, `attach!/2` and `attach!/3`, `counts/1`, `detach/1`. `attach!/3`'s `:owner` option isolates sources per emitter: `:any` (default) counts every emitter -- the exact pre-existing union behavior -- while a pid counts only events emitted by that process. | PARTIAL (not default path) |
| [`AshA2A.SemanticProjection`](https://hexdocs.pm/ash_a2a/AshA2A.SemanticProjection.html) | Read-only projection of committed receipts and capabilities into machine-readable evidence; joins `ash_r2rml` mapping results when available (real, asserted mapping as of v26.9.14, not just the refusal path). Receipt metadata and projected OCEL events carry `spg_graph_id`, `spg_graph_version`, `spg_node_id`, `spg_edge_id`, and `spg_projection_family` when SPG identity is present (since v26.9.25, d660a9e). | PARTIAL (not default path) |
| [`AshA2A.Research.ERC`](https://hexdocs.pm/ash_a2a/AshA2A.Research.ERC.html) | Executable Research Claim receipt emitter; writes a machine-readable JSON receipt from this project's own test-run evidence. | PARTIAL (not default path) |

## GALL structured-work-fabric & receipt courts (v26.9.20)

Real code with real, passing Chicago-style tests, but none of these are called
by `AshA2A.Agent.__dispatch__`'s default path, `CommandBus`, or `Dispatcher` --
they are typed message/receipt shapes and a standalone reconciliation loop,
reached only via their own scripts/tests or explicit host wiring (same
"PARTIAL (not default path)" convention as the `Reactor.*` rows above).

| Module | Description | Status |
| --- | --- | --- |
| [`AshA2A.Gall.Capability`](https://hexdocs.pm/ash_a2a/AshA2A.Gall.Capability.html) | The closed GALL capability vocabulary (PRD §43.5): `Read/Write/Edit/Commit/Push/Publish/Deploy/Merge`, no extension point. | PARTIAL (not default path) |
| [`AshA2A.Gall.Checkpoint`](https://hexdocs.pm/ash_a2a/AshA2A.Gall.Checkpoint.html) | Typed GALL checkpoint message shape. | PARTIAL (not default path) |
| [`AshA2A.Gall.CommandReceipt`](https://hexdocs.pm/ash_a2a/AshA2A.Gall.CommandReceipt.html) | GALL-003 durable portable command receipt court: seals a command receipt independent of the issuing `ReceiptStore`. | PARTIAL (not default path) |
| [`AshA2A.Gall.EvidenceReceipt`](https://hexdocs.pm/ash_a2a/AshA2A.Gall.EvidenceReceipt.html) | Typed GALL evidence-receipt message shape. | PARTIAL (not default path) |
| [`AshA2A.Gall.Fields`](https://hexdocs.pm/ash_a2a/AshA2A.Gall.Fields.html) | Shared field-shape helpers for GALL message types. | PARTIAL (not default path) |
| [`AshA2A.Gall.Message`](https://hexdocs.pm/ash_a2a/AshA2A.Gall.Message.html) | GALL structured-work-fabric message envelope; `validate/2` enforces the capability child-subset rule (PRD §30). | PARTIAL (not default path) |
| [`AshA2A.Gall.ProcessIntervention`](https://hexdocs.pm/ash_a2a/AshA2A.Gall.ProcessIntervention.html) | GALL-029 finding admission and GALL-030 bounded intervention over `CommandBus`; findings remain evidence, never authority. | PARTIAL (not default path) |
| [`AshA2A.Gall.WorkLease`](https://hexdocs.pm/ash_a2a/AshA2A.Gall.WorkLease.html) | Typed GALL work-lease message shape. | PARTIAL (not default path) |
| [`AshA2A.Reconciliation.MapeK`](https://hexdocs.pm/ash_a2a/AshA2A.Reconciliation.MapeK.html) | Named Monitor/Analyze/Plan/Execute-over-shared-Knowledge loop built on `AshA2A.Reconciliation.classify/4`/`.reconcile/4`; purely additive, no default-path wiring. | PARTIAL (not default path) |
