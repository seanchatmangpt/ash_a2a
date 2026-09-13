# Module Reference Index

Status legend:

- **ALIVE** — real code, wired into the default dispatch path, exercised by tests.
- **PARTIAL (not default path)** — real code, tested, but not called by
  `AshA2A.Agent.__dispatch__`'s default path; opt-in only.
- **ADAPTER-SEAM (no real provider)** — real adapter module, `Code.ensure_loaded?`-guarded,
  but its target dependency (Oban, `Group`, Phoenix Presence, `DurableServer`, FLAME,
  `AshStateMachine`) is not a real dependency of this project; self-degrades to
  `:unsupported`.

## Core (dispatch path)

| Module | Description | Status |
| --- | --- | --- |
| [`AshA2A.Agent`](https://hexdocs.pm/ash_a2a/AshA2A.Agent.html) | Generates a supervised `A2A.Agent` GenServer for an `AshA2A`-extended resource/domain. | ALIVE |
| [`AshA2A.Dispatcher`](https://hexdocs.pm/ash_a2a/AshA2A.Dispatcher.html) | Dispatches an inbound `A2A.Message` to the Ash action a persisted skill maps to. | ALIVE |
| [`AshA2A.Info`](https://hexdocs.pm/ash_a2a/AshA2A.Info.html) | Introspection facade; derives the capability index from `Ash.Resource.Info.public_actions/1`. | ALIVE |
| [`AshA2A.CapabilityIndex`](https://hexdocs.pm/ash_a2a/AshA2A.CapabilityIndex.html) | Public facade over the derived Ash-to-A2A capability projection. | ALIVE |
| [`AshA2A.CapabilityIndex.Compiler`](https://hexdocs.pm/ash_a2a/AshA2A.CapabilityIndex.Compiler.html) | Derives the capability index from `Ash.Resource.Info.public_actions/1` plus residual overrides. | ALIVE |
| [`AshA2A.CapabilityIndex.AgentCardBuilder`](https://hexdocs.pm/ash_a2a/AshA2A.CapabilityIndex.AgentCardBuilder.html) | Deterministically projects a compiled capability index into `A2A.AgentCard.t()`. | ALIVE |
| [`AshA2A.CapabilityIndex.Validator`](https://hexdocs.pm/ash_a2a/AshA2A.CapabilityIndex.Validator.html) | Fail-closed validation that every residual skill override names a real, public Ash action. | ALIVE |
| [`AshA2A.ContextResolver`](https://hexdocs.pm/ash_a2a/AshA2A.ContextResolver.html) | Resolves `actor`/`tenant`/`context`/`domain`/`history` from an `A2A.Message` at the trust boundary. | ALIVE |
| [`AshA2A.ExecutionContext`](https://hexdocs.pm/ash_a2a/AshA2A.ExecutionContext.html) | Struct holding the resolved, trust-boundary-crossed dispatch context built by `ContextResolver`. | ALIVE |
| [`AshA2A.Skill`](https://hexdocs.pm/ash_a2a/AshA2A.Skill.html) | Derived reference to one public Ash action exposed through A2A; also the DSL entity target. | ALIVE |
| [`AshA2A.Argument`](https://hexdocs.pm/ash_a2a/AshA2A.Argument.html) | Spark DSL entity for `a2a do skill ... do argument ... end end`; kept for source compatibility, ignored by compilation. | ALIVE |
| [`AshA2A.Dsl`](https://hexdocs.pm/ash_a2a/AshA2A.Dsl.html) | Spark DSL extension defining the optional residual `a2a do skill ... end` override block. | ALIVE |
| [`AshA2A.Verify`](https://hexdocs.pm/ash_a2a/AshA2A.Verify.html) | Spark DSL verifier checking every override points at a real public Ash action. | ALIVE |
| [`AshA2A.Transformers.BuildCapabilityIndex`](https://hexdocs.pm/ash_a2a/AshA2A.Transformers.BuildCapabilityIndex.html) | Spark DSL transformer that persists residual overrides and subject kind (resource/domain) at compile time. | ALIVE |
| [`AshA2A.MetadataKey`](https://hexdocs.pm/ash_a2a/AshA2A.MetadataKey.html) | Shared atom-or-string map lookup helper used by `ContextResolver`, `Agent`, and `Dispatcher`. | ALIVE |
| [`AshA2A.Application`](https://hexdocs.pm/ash_a2a/AshA2A.Application.html) | OTP application starting the A2A agent supervisor and the default in-memory receipt store. | ALIVE |

## LLM resolution

| Module | Description | Status |
| --- | --- | --- |
| [`AshA2A.LLMProfiles`](https://hexdocs.pm/ash_a2a/AshA2A.LLMProfiles.html) | Resolves an abstract Ash action role (e.g. `:semantic_reasoner`) to a concrete `req_llm`/`ash_ai` model spec via `config :ash_a2a, :llm_profiles`. | ALIVE |

## Admission & receipts (opt-in)

| Module | Description | Status |
| --- | --- | --- |
| [`AshA2A.Authority`](https://hexdocs.pm/ash_a2a/AshA2A.Authority.html) | Explicit authority evidence bound to a principal and one capability; constructed only after transport-level admission. | PARTIAL (not default path) |
| [`AshA2A.CommandBus`](https://hexdocs.pm/ash_a2a/AshA2A.CommandBus.html) | Canonical receipted route from an admitted `AshA2A.Command` to the Ash dispatcher, enforcing capability/identity/replay checks. | PARTIAL (not default path) |
| [`AshA2A.Command`](https://hexdocs.pm/ash_a2a/AshA2A.Command.html) | Consequence-bearing command envelope binding identity, capability id, admitted input, and optional authority. | PARTIAL (not default path) |
| [`AshA2A.Identity`](https://hexdocs.pm/ash_a2a/AshA2A.Identity.html) | Typed machine identity (`:principal`, `:agent`, `:task`, `:command`, `:execution`, `:runtime`) used across the boundary. | PARTIAL (not default path) |
| [`AshA2A.Receipt`](https://hexdocs.pm/ash_a2a/AshA2A.Receipt.html) | Replayable evidence struct for one `AshA2A.CommandBus` command attempt. | PARTIAL (not default path) |
| [`AshA2A.ReceiptStore`](https://hexdocs.pm/ash_a2a/AshA2A.ReceiptStore.html) | Behaviour for replay-safe command receipt storage distinguishing replay from conflict. | PARTIAL (not default path) |
| [`AshA2A.ReceiptStore.Memory`](https://hexdocs.pm/ash_a2a/AshA2A.ReceiptStore.Memory.html) | In-memory `GenServer` reference implementation of `AshA2A.ReceiptStore`, started by `AshA2A.Application`. | PARTIAL (not default path) |
| [`AshA2A.Reactor.ExecuteCommand`](https://hexdocs.pm/ash_a2a/AshA2A.Reactor.ExecuteCommand.html) | `Reactor.Step` adapter that calls `AshA2A.CommandBus` for one admitted command inside a Reactor. | PARTIAL (not default path) |
| [`AshA2A.Planning.Candidate`](https://hexdocs.pm/ash_a2a/AshA2A.Planning.Candidate.html) | Planner-output struct with candidate-only standing and no DO authority. | PARTIAL (not default path) |
| [`AshA2A.TaskLifecycle`](https://hexdocs.pm/ash_a2a/AshA2A.TaskLifecycle.html) | Adapter over host-owned `AshStateMachine` task truth; declares A2A task vocabulary but performs no transition itself. | ADAPTER-SEAM (no real provider) |

## Ecosystem adapters (seams only)

| Module | Description | Status |
| --- | --- | --- |
| [`AshA2A.Delivery`](https://hexdocs.pm/ash_a2a/AshA2A.Delivery.html) | Provider-neutral struct observing that a command was handed to an async delivery substrate. | PARTIAL (not default path) |
| [`AshA2A.Delivery.Oban`](https://hexdocs.pm/ash_a2a/AshA2A.Delivery.Oban.html) | Optional Oban delivery adapter recording a `Delivery`; requires the receiving worker to re-admit through `CommandBus`. | ADAPTER-SEAM (no real provider) |
| [`AshA2A.Topology.Group`](https://hexdocs.pm/ash_a2a/AshA2A.Topology.Group.html) | Optional adapter for the `Group` process/topology registry; mutations return `RuntimeReceipt`. | ADAPTER-SEAM (no real provider) |
| [`AshA2A.Topology.Presence`](https://hexdocs.pm/ash_a2a/AshA2A.Topology.Presence.html) | Adapter for a host application's `Phoenix.Presence` module; mutations return `RuntimeReceipt`. | ADAPTER-SEAM (no real provider) |
| [`AshA2A.Durability.DurableServer`](https://hexdocs.pm/ash_a2a/AshA2A.Durability.DurableServer.html) | Optional adapter for Phoenix `DurableServer` task runtimes, keyed by A2A TaskID. | ADAPTER-SEAM (no real provider) |
| [`AshA2A.Execution.FLAME`](https://hexdocs.pm/ash_a2a/AshA2A.Execution.FLAME.html) | Optional FLAME placement adapter; the placed closure still calls `CommandBus` for admission. | ADAPTER-SEAM (no real provider) |
| [`AshA2A.RuntimeReceipt`](https://hexdocs.pm/ash_a2a/AshA2A.RuntimeReceipt.html) | Evidence struct for consequence-bearing runtime/provider operations (topology, durability, execution adapters). | PARTIAL (not default path) |

## Telemetry & evidence

| Module | Description | Status |
| --- | --- | --- |
| [`AshA2A.Telemetry.OcelForwarder`](https://hexdocs.pm/ash_a2a/AshA2A.Telemetry.OcelForwarder.html) | Best-effort OCEL v2 telemetry egress for dispatch spans and committed `CommandBus` receipts; observational only. | ALIVE |
| [`AshA2A.SemanticProjection`](https://hexdocs.pm/ash_a2a/AshA2A.SemanticProjection.html) | Read-only projection of committed receipts and capabilities into machine-readable evidence; joins `ash_r2rml` mapping results when available. | PARTIAL (not default path) |
| [`AshA2A.Research.ERC`](https://hexdocs.pm/ash_a2a/AshA2A.Research.ERC.html) | Executable Research Claim receipt emitter; writes a machine-readable JSON receipt from this project's own test-run evidence. | PARTIAL (not default path) |
