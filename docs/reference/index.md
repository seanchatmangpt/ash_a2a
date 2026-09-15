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

As of v26.9.14, every module previously listed `ADAPTER-SEAM (no real provider)` has a
real, dependency-satisfied, tested integration -- see
[Architecture](../explanation/architecture.md#the-ecosystem-adapters-are-real-integrations-not-just-seams-as-of-v2691) for the full evidence table.

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
| [`AshA2A.Command`](https://hexdocs.pm/ash_a2a/AshA2A.Command.html) | Consequence-bearing command envelope binding identity, capability id, admitted input, optional authority, and (since v26.9.15) `AshA2A.SemanticSubject` evidence. | ALIVE (opt-in trigger) |
| [`AshA2A.Identity`](https://hexdocs.pm/ash_a2a/AshA2A.Identity.html) | Typed machine identity (`:principal`, `:agent`, `:task`, `:command`, `:execution`, `:runtime`) used across the boundary. | ALIVE (opt-in trigger) |
| [`AshA2A.SemanticSubject`](https://hexdocs.pm/ash_a2a/AshA2A.SemanticSubject.html) | Binds command/receipt identity to a semantic graph digest, generated-projection digest, and manufacturer digest. Identity/evidence only -- grants no authority. | ALIVE (opt-in trigger) |
| [`AshA2A.Receipt`](https://hexdocs.pm/ash_a2a/AshA2A.Receipt.html) | Replayable evidence struct for one `AshA2A.CommandBus` command attempt; `standing` is `:observed` (default store) or `:durable` (a store that declares `durable?/0`). | ALIVE (opt-in trigger) |
| [`AshA2A.ReceiptStore`](https://hexdocs.pm/ash_a2a/AshA2A.ReceiptStore.html) | Behaviour for replay-safe command receipt storage distinguishing replay from conflict. | ALIVE (opt-in trigger) |
| [`AshA2A.ReceiptStore.Memory`](https://hexdocs.pm/ash_a2a/AshA2A.ReceiptStore.Memory.html) | In-memory `GenServer` reference implementation of `AshA2A.ReceiptStore`; the default, started by `AshA2A.Application`. No persistence across a restart. | ALIVE (opt-in trigger) |
| [`AshA2A.ReceiptStore.Ekv`](https://hexdocs.pm/ash_a2a/AshA2A.ReceiptStore.Ekv.html) | Real on-disk-persisted `AshA2A.ReceiptStore` backed by `:ekv`; survives a process restart. Configure via `config :ash_a2a, :receipt_store, AshA2A.ReceiptStore.Ekv`. | ALIVE (opt-in trigger) |
| [`AshA2A.Reactor.ExecuteCommand`](https://hexdocs.pm/ash_a2a/AshA2A.Reactor.ExecuteCommand.html) | `Reactor.Step` adapter that calls `AshA2A.CommandBus` for one admitted command inside a Reactor. | PARTIAL (not default path) |
| [`AshA2A.Reactor.CommandWorkflow`](https://hexdocs.pm/ash_a2a/AshA2A.Reactor.CommandWorkflow.html) | Real multi-step `Reactor.run/2` DAG composing command execution; a deliberately unauthorized command halts the real run before any receipt commits. | PARTIAL (not default path) |
| [`AshA2A.Reactor.BuildCommand`](https://hexdocs.pm/ash_a2a/AshA2A.Reactor.BuildCommand.html) | `Reactor.Step` that constructs an `AshA2A.Command` from step inputs for `CommandWorkflow`. | PARTIAL (not default path) |
| [`AshA2A.Reactor.ConfirmReceipt`](https://hexdocs.pm/ash_a2a/AshA2A.Reactor.ConfirmReceipt.html) | `Reactor.Step` that asserts on a committed `AshA2A.Receipt` within `CommandWorkflow`. | PARTIAL (not default path) |
| [`AshA2A.Planning.Candidate`](https://hexdocs.pm/ash_a2a/AshA2A.Planning.Candidate.html) | Planner-output struct with candidate-only standing and no DO authority. | PARTIAL (not default path) |
| [`AshA2A.TaskLifecycle`](https://hexdocs.pm/ash_a2a/AshA2A.TaskLifecycle.html) | Adapter over host-owned `AshStateMachine` task truth; declares A2A task vocabulary. `:ash_state_machine` is now a real dependency with a real qualification test. | REAL_INTEGRATED (provider, opt-in) |

## Semantic pipeline (opt-in production surface, v26.9.14)

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

## Ecosystem adapters (real, dependency-satisfied integrations)

Each is `Code.ensure_loaded?/1`-guarded and degrades to `:unsupported` if its provider
is absent, but as of v26.9.14 every one of these providers is a real, resolvable
dependency of this project with a real qualification test exercising it -- see
[Architecture](../explanation/architecture.md) for the exact test-file evidence per row.

| Module | Description | Status |
| --- | --- | --- |
| [`AshA2A.Delivery`](https://hexdocs.pm/ash_a2a/AshA2A.Delivery.html) | Provider-neutral struct observing that a command was handed to an async delivery substrate. | PARTIAL (not default path) |
| [`AshA2A.Delivery.Oban`](https://hexdocs.pm/ash_a2a/AshA2A.Delivery.Oban.html) | Real Oban delivery adapter; a real `Oban.Worker` reconstructs the admitted `Command` and re-admits through `CommandBus`. | REAL_INTEGRATED (provider, opt-in) |
| [`AshA2A.Topology.Group`](https://hexdocs.pm/ash_a2a/AshA2A.Topology.Group.html) | Real adapter for the `Group` process/topology registry, including real cross-node purge-on-death; mutations return `RuntimeReceipt`. | REAL_INTEGRATED (provider, opt-in) |
| [`AshA2A.Topology.Presence`](https://hexdocs.pm/ash_a2a/AshA2A.Topology.Presence.html) | Real adapter for a host application's `Phoenix.Presence` module; mutations return `RuntimeReceipt`. | REAL_INTEGRATED (provider, opt-in) |
| [`AshA2A.Durability.DurableServer`](https://hexdocs.pm/ash_a2a/AshA2A.Durability.DurableServer.html) | Real adapter for Phoenix `DurableServer` task runtimes, keyed by A2A TaskID; real single-node kill+restart proven, cross-node rehome still unexercised (disclosed gap). | REAL_INTEGRATED (provider, opt-in) |
| [`AshA2A.Execution.FLAME`](https://hexdocs.pm/ash_a2a/AshA2A.Execution.FLAME.html) | Real FLAME placement adapter (`FLAME.LocalBackend` proven); the placed closure still calls `CommandBus` for admission. | REAL_INTEGRATED (provider, opt-in) |
| [`AshA2A.RuntimeReceipt`](https://hexdocs.pm/ash_a2a/AshA2A.RuntimeReceipt.html) | Evidence struct for consequence-bearing runtime/provider operations (topology, durability, execution adapters). | PARTIAL (not default path) |

## Telemetry & evidence

| Module | Description | Status |
| --- | --- | --- |
| [`AshA2A.Telemetry.OcelForwarder`](https://hexdocs.pm/ash_a2a/AshA2A.Telemetry.OcelForwarder.html) | Best-effort OCEL v2 telemetry egress. Exactly one event per CommandBus-routed dispatch (dispatch-span and receipt-committed fields merged, deduplicated); a direct `Dispatcher.dispatch/5` caller still gets its own dispatch event. Observational only. | ALIVE |
| [`AshA2A.SemanticProjection`](https://hexdocs.pm/ash_a2a/AshA2A.SemanticProjection.html) | Read-only projection of committed receipts and capabilities into machine-readable evidence; joins `ash_r2rml` mapping results when available (real, asserted mapping as of v26.9.14, not just the refusal path). | PARTIAL (not default path) |
| [`AshA2A.Research.ERC`](https://hexdocs.pm/ash_a2a/AshA2A.Research.ERC.html) | Executable Research Claim receipt emitter; writes a machine-readable JSON receipt from this project's own test-run evidence. | PARTIAL (not default path) |
