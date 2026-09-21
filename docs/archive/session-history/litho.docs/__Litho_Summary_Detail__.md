# Project Analysis Summary Report (Full Version)

Generation Time: 2026-09-15 03:22:09 UTC

## Execution Timing Statistics

- **Total Execution Time**: 2859.52 seconds
- **Preprocessing Phase**: 503.27 seconds (17.6%)
- **Research Phase**: 933.54 seconds (32.6%)
- **Document Generation Phase**: 1422.71 seconds (49.8%)
- **Output Phase**: 0.00 seconds (0.0%)
- **Summary Generation Time**: 0.001 seconds

## Cache Performance Statistics and Savings

### Performance Metrics
- **Cache Hit Rate**: 0.0%
- **Total Operations**: 49
- **Cache Hits**: 0 times
- **Cache Misses**: 49 times
- **Cache Writes**: 50 times

### Savings
- **Inference Time Saved**: 0.0 seconds
- **Tokens Saved**: 0 input + 0 output = 0 total
- **Estimated Cost Savings**: $0.0000

## Core Research Data Summary

Complete content of four types of research materials according to Prompt template data integration rules:

### System Context Research Report
Provides core objectives, user roles, and system boundary information for the project.

```json
{
  "business_value": "Turns any Ash application into an A2A-compliant agent with zero hand-written protocol glue. Public actions become discoverable agent skills automatically, with fail-closed validation so overrides can describe or suppress but never invent capabilities. LLM output is treated strictly as untrusted evidence: every proposed capability is re-validated and every consequence-bearing action flows through a receipted command bus, giving teams a safe path to AI-driven planning over existing business logic.",
  "confidence_score": 8.6,
  "external_systems": [
    {
      "description": "The canonical capability source. Public actions on Ash resources and domains define what the agent can do.",
      "interaction_type": "Compile-time introspection via Ash.Resource.Info and runtime action invocation through the dispatcher",
      "name": "Ash Framework"
    },
    {
      "description": "Agent-to-agent wire protocol. External A2A clients and agents consume the generated AgentCard and send A2A.Message structs.",
      "interaction_type": "Message ingress/reply and discovery document publication",
      "name": "A2A Protocol ecosystem"
    },
    {
      "description": "External model services used to extract semantic candidates from raw text and propose HDDL/FOND plans for unknown boundaries. Output is always untrusted and re-validated.",
      "interaction_type": "Synchronous generate_object API calls, injectable for testing",
      "name": "LLM providers (via ReqLLM)"
    },
    {
      "description": "Rust planning library invoked through the native hddl_cli binary. Consumes domain and problem files, emits plans as JSON.",
      "interaction_type": "Subprocess invocation with file I/O, JSON on stdout, exit-code contract",
      "name": "ferroplan FOND HTN solver"
    },
    {
      "description": "Durable on-disk key-value store backing the production receipt store. Receipts survive process and node restarts.",
      "interaction_type": "Supervised storage backend started by AshA2A.Application from configuration",
      "name": "EKV"
    },
    {
      "description": "Durable job queue used as the delivery backend for command dispatch.",
      "interaction_type": "Optional delivery adapter",
      "name": "Oban"
    },
    {
      "description": "Elastic remote execution backend used to run command execution off the host node.",
      "interaction_type": "Optional execution adapter",
      "name": "FLAME"
    },
    {
      "description": "External telemetry/event sink receiving forwarded runtime events via the OCEL forwarder.",
      "interaction_type": "Telemetry event forwarding",
      "name": "OCEL telemetry target"
    },
    {
      "description": "DSL authoring framework on which the AshA2A extension and its sections are built.",
      "interaction_type": "Compile-time DSL extension mechanism",
      "name": "Spark"
    }
  ],
  "project_description": "An Elixir framework and Spark DSL extension for the Ash ecosystem. It projects public Ash resource actions into A2A (Agent-to-Agent) protocol skills, generates AgentCard discovery documents, and dispatches inbound A2A messages back to real Ash actions through a trust-boundary context resolver. It adds a receipted command bus for idempotent, replay-safe execution and a semantic compilation pipeline that turns raw text into admitted semantics, an RDF-style ontology, and HDDL/FOND plan candidates via LLM extraction. A native Rust CLI wraps the ferroplan FOND HTN solver for formal planning.",
  "project_name": "ash_a2a",
  "project_type": "Framework",
  "system_boundary": {
    "excluded_components": [
      "Host application Ash resources and domains (business logic)",
      "External A2A client applications and agent implementations",
      "LLM model providers themselves",
      "Ferroplan solver internals",
      "Storage and queue infrastructure operation (EKV instance, Oban tables, database)",
      "HTTP transport servers and network plumbing",
      "Any user interface"
    ],
    "included_components": [
      "AshA2A Spark DSL extension and residual skill overrides",
      "Capability index compiler, fail-closed validator, and AgentCard builder",
      "Dispatcher, context resolver, and execution context",
      "Command envelope, command bus, receipt model, and receipt stores (memory and EKV)",
      "Agent behaviour compiling resources into supervised A2A GenServers, plus durable server",
      "Semantic pipeline: source, IR, admission, ontology, planning IR, execution package, feedback",
      "Planning semantic synthesis for unknown boundaries",
      "Delivery (Oban) and execution (FLAME) adapters",
      "Topology presence and group management",
      "Mix tasks: install, architecture verification, EDS ledger",
      "Native Rust hddl_cli wrapper around ferroplan"
    ],
    "scope": "The library boundary spans everything from A2A message ingress to Ash action invocation and receipt persistence, plus the semantic compilation and planning pipeline. Host applications embed the framework, supply their own Ash resources, supervise generated agents, and configure storage and delivery backends."
  },
  "target_users": [
    {
      "description": "Developers with existing Ash resources who want to expose them as agent capabilities over the A2A protocol.",
      "name": "Elixir/Ash application developers",
      "needs": [
        "Zero-configuration capability projection from public Ash actions",
        "Optional DSL overrides for names, descriptions, tags, and exclusion",
        "Guaranteed alignment between advertised AgentCard and dispatch behavior",
        "Idempotent, replay-safe command execution with durable receipts"
      ]
    },
    {
      "description": "Engineers building multi-agent systems where agents discover and invoke each other's capabilities.",
      "name": "AI agent platform engineers",
      "needs": [
        "Deterministic AgentCard generation for discovery",
        "Argument schemas introspected from real actions, not declarations",
        "Enforced trust boundary between raw A2A message metadata and domain calls",
        "Supervised agent GenServers integrated into host supervision trees"
      ]
    },
    {
      "description": "Teams building systems where natural-language goals are compiled into formal plans and executed against real capabilities.",
      "name": "Semantic planning and agentic workflow teams",
      "needs": [
        "Deterministic admission gates for LLM-extracted semantics with full provenance",
        "Candidate-only plan synthesis that never carries authority",
        "Fingerprinted, replayable execution packages and feedback loops",
        "FOND/HTN planning integration with structured success/error contracts"
      ]
    }
  ]
}
```

### Domain Modules Research Report
Provides high-level domain division, module relationships, and core business process information.

```json
{
  "architecture_summary": "AshA2A is an Elixir framework and Spark DSL extension architected as a set of strictly separated domains around one central invariant: the advertised agent surface (A2A AgentCard) and the executed behavior (Ash action dispatch) are both projections of a single canonical source, Ash.Resource.Info.public_actions/1. Compile-time, the Capability Projection domain derives skills via a Spark transformer with fail-closed validation of residual overrides; runtime, the Message Dispatch domain enforces a named trust boundary (ContextResolver) before invoking Ash actions, and all consequence-bearing work is funneled through the Receipted Command Execution domain, whose CommandBus is the single sanctioned path and whose receipt stores (in-memory and durable EKV) guarantee idempotent, replay-safe execution. The Semantic Compilation domain applies a candidate-then-admit pattern to LLM output: everything the model proposes is authority-free evidence until a deterministic admission gate validates provenance, after which artifacts become fingerprinted, replayable packages projected into RDF-style ontologies and PlanningIR. Planning Synthesis extends this to unknown boundaries via LLM-proposed plans (always re-validated) and a native Rust bridge to the ferroplan FOND HTN solver. Agent Runtime & Lifecycle supervises compiled agents with durability and topology support, while Integration Adapters (Oban, FLAME, Reactor, OCEL telemetry) are interchangeable ports that all respect the CommandBus checks. Developer Tooling & Governance closes the loop with architecture verification tasks, evidence ledgers, and spec assets that keep code aligned with documented invariants. Overall this is a ports-and-adapters style, security-first framework design: deterministic derivation over generation, fail-closed validation at every boundary, and receipts/fingerprints as the universal evidence mechanism. A minor alignment note: receipt-related code is split between the command domain (receipt.ex, receipt_store) and the runtime domain (runtime_receipt.ex), a deliberate but potentially confusing distinction between command evidence and lifecycle evidence.",
  "business_flows": [
    {
      "description": "Compile-time-to-runtime flow that turns public Ash resource actions into discoverable A2A skills. The host attaches the AshA2A extension, the Spark transformer compiles a capability index from introspected public actions, residual overrides are fail-closed validated, and the deterministic AgentCard is published to A2A clients with a supervised agent backing it.",
      "entry_point": "Host application attaches the extension via `use Ash.Resource, extensions: [AshA2A]`; Spark compile-time transformer plus runtime AshA2A.Info API",
      "importance": 9.5,
      "involved_domains_count": 2,
      "name": "Capability Projection & AgentCard Discovery Flow",
      "steps": [
        {
          "code_entry_point": "lib/ash_a2a.ex",
          "domain_module": "Capability Projection & Discovery",
          "operation": "Register the a2a DSL section and optional residual skill overrides on the Ash resource or domain",
          "step": 1,
          "sub_module": "DSL Extension"
        },
        {
          "code_entry_point": "lib/ash_a2a/capability_index/compiler.ex",
          "domain_module": "Capability Projection & Discovery",
          "operation": "Introspect Ash.Resource.Info.public_actions/1 and derive canonical {resource, action} skills with layered overrides",
          "step": 2,
          "sub_module": "Capability Compiler"
        },
        {
          "code_entry_point": "lib/ash_a2a/capability_index/validator.ex",
          "domain_module": "Capability Projection & Discovery",
          "operation": "Validate overrides; reject references to private or nonexistent actions with structured refusals",
          "step": 3,
          "sub_module": "Fail-Closed Override Validator"
        },
        {
          "code_entry_point": "lib/ash_a2a/info.ex",
          "domain_module": "Capability Projection & Discovery",
          "operation": "Derive the current capability index on demand through the canonical introspection API",
          "step": 4,
          "sub_module": "Introspection Facade"
        },
        {
          "code_entry_point": "lib/ash_a2a/capability_index/agent_card_builder.ex",
          "domain_module": "Capability Projection & Discovery",
          "operation": "Project the compiled index into a deterministic A2A AgentCard with schemas introspected from real actions",
          "step": 5,
          "sub_module": "AgentCard Builder"
        },
        {
          "code_entry_point": "lib/ash_a2a/agent.ex",
          "domain_module": "Agent Runtime & Lifecycle",
          "operation": "Back the compiled index with a supervised A2A agent GenServer under the host supervision tree",
          "step": 6,
          "sub_module": "Agent Behaviour"
        }
      ]
    },
    {
      "description": "Core runtime flow: an A2A client sends an A2A.Message to a supervised agent. The message passes the trust-boundary context resolver, the skill is resolved from the verified capability index, consequence-bearing commands are admitted through the receipted CommandBus, the real Ash action executes, a receipt is persisted, and an A2A reply is returned.",
      "entry_point": "A2A.Message delivered to a supervised AshA2A.Agent GenServer or to the dispatcher function",
      "importance": 10.0,
      "involved_domains_count": 2,
      "name": "Inbound A2A Message Dispatch Flow",
      "steps": [
        {
          "code_entry_point": "AshA2A.ContextResolver.from_a2a_message/2",
          "domain_module": "Message Dispatch & Trust Boundary",
          "operation": "Convert inbound A2A.Message metadata into a validated ExecutionContext (actor, tenant) without leaking raw protocol metadata",
          "step": 1,
          "sub_module": "Context Resolver (Trust Boundary)"
        },
        {
          "code_entry_point": "lib/ash_a2a/dispatcher.ex",
          "domain_module": "Message Dispatch & Trust Boundary",
          "operation": "Look up the persisted, verified skill for the message via the capability index (never raw DSL entities)",
          "step": 2,
          "sub_module": "Dispatcher"
        },
        {
          "code_entry_point": "lib/ash_a2a/command_bus.ex",
          "domain_module": "Receipted Command Execution",
          "operation": "For consequence-bearing commands, admit the command and enforce capability, identity, and replay checks",
          "step": 3,
          "sub_module": "Command Bus"
        },
        {
          "code_entry_point": "lib/ash_a2a/dispatcher.ex",
          "domain_module": "Message Dispatch & Trust Boundary",
          "operation": "Invoke the mapped real Ash action with the resolved execution context",
          "step": 4,
          "sub_module": "Dispatcher"
        },
        {
          "code_entry_point": "lib/ash_a2a/receipt_store/ekv.ex",
          "domain_module": "Receipted Command Execution",
          "operation": "Persist a replayable receipt recording the attempt and observed outcome (in-memory or durable EKV)",
          "step": 5,
          "sub_module": "Receipt Store (Behaviour + Backends)"
        },
        {
          "code_entry_point": "lib/ash_a2a/dispatcher.ex",
          "domain_module": "Message Dispatch & Trust Boundary",
          "operation": "Return the A2A.Agent reply tuple to the calling client or agent",
          "step": 6,
          "sub_module": "Dispatcher"
        }
      ]
    },
    {
      "description": "Idempotent, replay-safe execution path used by delivery and execution adapters. A command arrives via an Oban job, FLAME worker, or Reactor step, is claimed atomically by the receipt store, checked and dispatched by the CommandBus, and its receipt persisted durably; retries with the same fingerprint replay the stored receipt while conflicting fingerprints are refused.",
      "entry_point": "Delivery adapter (Oban job), execution adapter (FLAME), or Reactor step submits a Command to AshA2A.CommandBus",
      "importance": 9.0,
      "involved_domains_count": 2,
      "name": "Receipted Command Execution Flow (Adapters)",
      "steps": [
        {
          "code_entry_point": "lib/ash_a2a/delivery/oban.ex",
          "domain_module": "Integration Adapters",
          "operation": "Enqueue the command as a durable Oban job for delivery into the command pipeline",
          "step": 1,
          "sub_module": "Delivery Adapters"
        },
        {
          "code_entry_point": "lib/ash_a2a/execution/flame.ex",
          "domain_module": "Integration Adapters",
          "operation": "Execute the command off-node via FLAME or within a Reactor workflow step calling the CommandBus",
          "step": 2,
          "sub_module": "Execution Adapters"
        },
        {
          "code_entry_point": "lib/ash_a2a/receipt_store.ex",
          "domain_module": "Receipted Command Execution",
          "operation": "Atomically claim the command id, distinguishing same-fingerprint replay from conflicting fingerprints",
          "step": 3,
          "sub_module": "Receipt Store (Behaviour + Backends)"
        },
        {
          "code_entry_point": "lib/ash_a2a/command_bus.ex",
          "domain_module": "Receipted Command Execution",
          "operation": "Verify capability, identity, and evidence, then route the admitted command to the dispatcher for Ash execution",
          "step": 4,
          "sub_module": "Command Bus"
        },
        {
          "code_entry_point": "lib/ash_a2a/receipt_store/ekv.ex",
          "domain_module": "Receipted Command Execution",
          "operation": "Commit the receipt with observed outcome to the durable EKV store so it survives restarts",
          "step": 5,
          "sub_module": "Receipt Store (Behaviour + Backends)"
        },
        {
          "code_entry_point": "lib/ash_a2a/command_bus.ex",
          "domain_module": "Receipted Command Execution",
          "operation": "On retry, return the stored receipt for matching fingerprints; refuse same-id/different-fingerprint conflicts",
          "step": 6,
          "sub_module": "Command Bus"
        }
      ]
    },
    {
      "description": "Closed-loop pipeline from raw text to a formal plan candidate. Raw evidence is anchored as a content-addressed Source, an LLM proposes a candidate semantic IR, the deterministic admission gate enforces provenance before admission, the admitted IR is projected into an RDF-style ontology and PlanningIR, the native ferroplan solver produces a plan candidate, and everything is bound into a fingerprinted ExecutionPackage.",
      "entry_point": "Raw text source submitted to AshA2A.Semantic.Compiler with injectable :generate_object (ReqLLM.generate_object/4 in production)",
      "importance": 9.0,
      "involved_domains_count": 2,
      "name": "Semantic Compilation Pipeline Flow",
      "steps": [
        {
          "code_entry_point": "lib/ash_a2a/semantic/source.ex",
          "domain_module": "Semantic Compilation",
          "operation": "Anchor raw text with media type, observation time, and provenance as a content-addressed Source",
          "step": 1,
          "sub_module": "Candidate Artifacts"
        },
        {
          "code_entry_point": "lib/ash_a2a/semantic/compiler.ex",
          "domain_module": "Semantic Compilation",
          "operation": "Invoke the LLM via generate_object to extract candidate semantics from the source",
          "step": 2,
          "sub_module": "Pipeline Compiler"
        },
        {
          "code_entry_point": "lib/ash_a2a/semantic/ir.ex",
          "domain_module": "Semantic Compilation",
          "operation": "Normalize the LLM-proposed map into the typed thirteen-collection candidate IR with standing ':candidate' and authority ':none'",
          "step": 3,
          "sub_module": "Candidate Artifacts"
        },
        {
          "code_entry_point": "lib/ash_a2a/semantic/admission.ex",
          "domain_module": "Semantic Compilation",
          "operation": "Deterministically validate required fields per collection and admit only fully provenanced candidates",
          "step": 4,
          "sub_module": "Admission Gate"
        },
        {
          "code_entry_point": "lib/ash_a2a/semantic/ontology.ex",
          "domain_module": "Semantic Compilation",
          "operation": "Project admitted IR into deterministic, fingerprinted RDF-style triples via the shared vocabulary",
          "step": 5,
          "sub_module": "Ontology Projection"
        },
        {
          "code_entry_point": "lib/ash_a2a/semantic/planning_ir.ex",
          "domain_module": "Semantic Compilation",
          "operation": "Manufacture PlanningIR with goals, objects, predicates, and nondeterminism markers for formal planning",
          "step": 6,
          "sub_module": "Candidate Artifacts"
        },
        {
          "code_entry_point": "native/hddl_cli/src/main.rs",
          "domain_module": "Planning Synthesis",
          "operation": "Solve the domain/problem files with the ferroplan FOND HTN solver and emit the plan as JSON under the exit-code contract",
          "step": 7,
          "sub_module": "Native FOND Planner Bridge"
        },
        {
          "code_entry_point": "lib/ash_a2a/semantic/execution_package.ex",
          "domain_module": "Semantic Compilation",
          "operation": "Bind source, IR, ontology, PlanningIR, and plan candidate into a content-fingerprinted ExecutionPackage with lineage",
          "step": 8,
          "sub_module": "Candidate Artifacts"
        }
      ]
    },
    {
      "description": "AI-assisted planning for goals outside known planning boundaries. A configured LLM role proposes HDDL/FOND artifacts and capability ids strictly as untrusted candidates; each proposal is re-validated against the real capability index, consequence-bearing actions are executed as receipted commands, and execution receipts are converted into authority-free feedback that closes the planning loop.",
      "entry_point": "Planning boundary cannot resolve a goal from known plans; AshA2A.Planning.SemanticSynthesis is invoked with the configured LLM profile",
      "importance": 8.5,
      "involved_domains_count": 3,
      "name": "LLM Plan Synthesis & Receipted Feedback Flow",
      "steps": [
        {
          "code_entry_point": "lib/ash_a2a/planning/semantic_synthesis.ex",
          "domain_module": "Planning Synthesis",
          "operation": "Have the configured LLM role propose HDDL/FOND artifacts and A2A capability ids as untrusted candidates",
          "step": 1,
          "sub_module": "Semantic Plan Synthesis"
        },
        {
          "code_entry_point": "lib/ash_a2a/planning/semantic_synthesis.ex",
          "domain_module": "Planning Synthesis",
          "operation": "Re-validate every proposed capability id through AshA2A.Info against the real capability index",
          "step": 2,
          "sub_module": "Semantic Plan Synthesis"
        },
        {
          "code_entry_point": "lib/ash_a2a/command.ex",
          "domain_module": "Receipted Command Execution",
          "operation": "Construct the consequence-bearing action as a Command bound to the semantic subject with content-derived fingerprint",
          "step": 3,
          "sub_module": "Command Envelope"
        },
        {
          "code_entry_point": "lib/ash_a2a/command_bus.ex",
          "domain_module": "Receipted Command Execution",
          "operation": "Execute the admitted command through the single sanctioned receipted route with all checks enforced",
          "step": 4,
          "sub_module": "Command Bus"
        },
        {
          "code_entry_point": "lib/ash_a2a/semantic/feedback.ex",
          "domain_module": "Semantic Compilation",
          "operation": "Convert execution receipts into typed, fingerprinted feedback observations with standing ':observed' and authority ':none' for re-planning",
          "step": 5,
          "sub_module": "Candidate Artifacts"
        }
      ]
    }
  ],
  "confidence_score": 8.8,
  "domain_modules": [
    {
      "code_paths": [
        "lib/ash_a2a.ex",
        "lib/ash_a2a/dsl.ex",
        "lib/ash_a2a/argument.ex",
        "lib/ash_a2a/verify.ex",
        "lib/ash_a2a/transformers/build_capability_index.ex",
        "lib/ash_a2a/capability_index.ex",
        "lib/ash_a2a/capability_index/compiler.ex",
        "lib/ash_a2a/capability_index/validator.ex",
        "lib/ash_a2a/capability_index/agent_card_builder.ex",
        "lib/ash_a2a/info.ex",
        "lib/ash_a2a/skill.ex"
      ],
      "complexity": 7.5,
      "description": "Core domain that turns public Ash resource actions into A2A protocol skills with zero hand-written protocol glue. It hosts the Spark DSL extension, the capability index compiler, the fail-closed override validator, and the deterministic AgentCard builder. Its central invariant is that capabilities are always derived from Ash.Resource.Info.public_actions/1; DSL overrides may describe or suppress existing capabilities but can never invent new ones, and dispatch can never diverge from the advertised AgentCard.",
      "domain_type": "Core Business Domain",
      "importance": 9.5,
      "name": "Capability Projection & Discovery",
      "sub_modules": [
        {
          "code_paths": [
            "lib/ash_a2a.ex",
            "lib/ash_a2a/dsl.ex",
            "lib/ash_a2a/argument.ex",
            "lib/ash_a2a/verify.ex"
          ],
          "description": "Top-level Spark DSL extension users attach via `use Ash.Resource, extensions: [AshA2A]`, declaring the residual `a2a` section with optional skill entities for A2A-only metadata.",
          "importance": 9.0,
          "key_functions": [
            "Attach AshA2A extension to Ash resources and domains",
            "Declare optional a2a skill overrides (display name, description, tags, exclusion)",
            "Verify extension configuration and compile-time rules"
          ],
          "name": "DSL Extension"
        },
        {
          "code_paths": [
            "lib/ash_a2a/capability_index/compiler.ex",
            "lib/ash_a2a/transformers/build_capability_index.ex",
            "lib/ash_a2a/skill.ex"
          ],
          "description": "Derives the canonical A2A skill set by introspecting public Ash actions, keyed by {resource, action} identity, and layering residual projection overrides on top; wired into Spark as a compile-time transformer.",
          "importance": 9.5,
          "key_functions": [
            "Introspect Ash.Resource.Info.public_actions/1 into skill definitions",
            "Compose residual overrides over the introspected base",
            "Build capability index during Spark compilation"
          ],
          "name": "Capability Compiler"
        },
        {
          "code_paths": [
            "lib/ash_a2a/capability_index/validator.ex"
          ],
          "description": "Safety gate of the capability pipeline that rejects any override referencing private actions or nonexistent {resource, action} pairs, protecting the integrity of the advertised agent surface.",
          "importance": 8.5,
          "key_functions": [
            "Fail-closed validation of residual A2A skill overrides",
            "Reject overrides naming private or nonexistent actions",
            "Return structured refusal with code and detail"
          ],
          "name": "Fail-Closed Override Validator"
        },
        {
          "code_paths": [
            "lib/ash_a2a/capability_index/agent_card_builder.ex"
          ],
          "description": "Final projection layer that deterministically converts a compiled capability index into the A2A AgentCard discovery document consumed by A2A clients, with argument schemas always introspected from real Ash actions.",
          "importance": 8.5,
          "key_functions": [
            "Project compiled index into deterministic A2A AgentCard struct",
            "Introspect argument schemas from real Ash actions",
            "Carry residual name/description/tag overrides onto canonical skill identities"
          ],
          "name": "AgentCard Builder"
        },
        {
          "code_paths": [
            "lib/ash_a2a/info.ex",
            "lib/ash_a2a/capability_index.ex"
          ],
          "description": "Public introspection API (AshA2A.Info and CapabilityIndex facade) that persists only residual overrides plus a resource-vs-domain flag and derives the current capability index on demand, keeping the index a projection rather than a second business model.",
          "importance": 8.5,
          "key_functions": [
            "capability_index* derivation through CapabilityIndex.Compiler",
            "Single canonical access path for dispatcher and planning components",
            "Keep wire projection and override validation separate"
          ],
          "name": "Introspection Facade"
        }
      ]
    },
    {
      "code_paths": [
        "lib/ash_a2a/dispatcher.ex",
        "lib/ash_a2a/context_resolver.ex",
        "lib/ash_a2a/execution_context.ex",
        "lib/ash_a2a/identity.ex",
        "lib/ash_a2a/authority.ex"
      ],
      "complexity": 8.0,
      "description": "Core runtime domain that receives inbound A2A messages and invokes real Ash actions. The context resolver is the named trust boundary: raw A2A message metadata never reaches Ash calls directly. The dispatcher resolves skills exclusively through the persisted, verified capability index, guaranteeing that what is advertised in the AgentCard is exactly what executes.",
      "domain_type": "Core Business Domain",
      "importance": 9.5,
      "name": "Message Dispatch & Trust Boundary",
      "sub_modules": [
        {
          "code_paths": [
            "lib/ash_a2a/dispatcher.ex"
          ],
          "description": "Core dispatch engine mapping an inbound A2A.Message to the real Ash action via the persisted capability index and returning an A2A.Agent reply tuple.",
          "importance": 9.5,
          "key_functions": [
            "Look up skills via AshA2A.Info (never raw DSL entities)",
            "Resolve execution context before invoking Ash actions",
            "Return A2A.Agent reply tuple"
          ],
          "name": "Dispatcher"
        },
        {
          "code_paths": [
            "lib/ash_a2a/context_resolver.ex"
          ],
          "description": "Trust boundary that converts inbound A2A.Message metadata into a validated ExecutionContext, extracting exactly the fields Ash actions accept (actor, tenant, etc.).",
          "importance": 9.0,
          "key_functions": [
            "from_a2a_message: validated conversion of message metadata",
            "Prevent raw protocol metadata from entering Ash calls",
            "Mandatory passage point for every dispatch path"
          ],
          "name": "Context Resolver (Trust Boundary)"
        },
        {
          "code_paths": [
            "lib/ash_a2a/execution_context.ex",
            "lib/ash_a2a/identity.ex",
            "lib/ash_a2a/authority.ex"
          ],
          "description": "Typed execution context and identity/authority models consumed by Ash actions, separating machine identity from granted authority.",
          "importance": 8.0,
          "key_functions": [
            "Model actor/tenant fields accepted by Ash actions",
            "Represent distinct machine identities",
            "Carry verified authority separately from identity"
          ],
          "name": "Execution Context Model"
        }
      ]
    },
    {
      "code_paths": [
        "lib/ash_a2a/command.ex",
        "lib/ash_a2a/command_bus.ex",
        "lib/ash_a2a/receipt.ex",
        "lib/ash_a2a/receipt_store.ex",
        "lib/ash_a2a/receipt_store/memory.ex",
        "lib/ash_a2a/receipt_store/ekv.ex"
      ],
      "complexity": 8.0,
      "description": "Core domain providing the single sanctioned path from an admitted Command to Ash action execution: the CommandBus. Every consequence-bearing action flows through capability, identity, replay, and evidence checks and produces a replayable receipt. The receipt store behaviour with in-memory and durable EKV backends underpins idempotent, replay-safe execution across the system.",
      "domain_type": "Core Business Domain",
      "importance": 9.0,
      "name": "Receipted Command Execution",
      "sub_modules": [
        {
          "code_paths": [
            "lib/ash_a2a/command.ex"
          ],
          "description": "Consequence-bearing command struct binding machine identities, a canonical capability id, admitted input, optional semantic subject, and verified authority, with a content-derived fingerprint.",
          "importance": 8.5,
          "key_functions": [
            "Bind capability id, admitted input, semantic subject, authority",
            "Content-only fingerprint so retries prove the same intent"
          ],
          "name": "Command Envelope"
        },
        {
          "code_paths": [
            "lib/ash_a2a/command_bus.ex"
          ],
          "description": "Canonical receipted route from an admitted Command to the Ash dispatcher; planning components and adapters may call it but cannot bypass its checks.",
          "importance": 9.5,
          "key_functions": [
            "Enforce capability, identity, replay, and evidence checks",
            "Route admitted commands to the dispatcher",
            "Produce receipts for every command attempt"
          ],
          "name": "Command Bus"
        },
        {
          "code_paths": [
            "lib/ash_a2a/receipt.ex",
            "lib/ash_a2a/receipt_store.ex",
            "lib/ash_a2a/receipt_store/memory.ex",
            "lib/ash_a2a/receipt_store/ekv.ex"
          ],
          "description": "Replay-safe receipt storage contract with atomic command-id claims, implemented by an in-memory backend for testing and a durable on-disk EKV backend for production deployments.",
          "importance": 8.5,
          "key_functions": [
            "Atomic command-id claim semantics",
            "Distinguish same-fingerprint replay from conflicting fingerprint",
            "Durable receipt persistence via EKV surviving restarts"
          ],
          "name": "Receipt Store (Behaviour + Backends)"
        }
      ]
    },
    {
      "code_paths": [
        "lib/ash_a2a/semantic/compiler.ex",
        "lib/ash_a2a/semantic/source.ex",
        "lib/ash_a2a/semantic/ir.ex",
        "lib/ash_a2a/semantic/admission.ex",
        "lib/ash_a2a/semantic/ontology.ex",
        "lib/ash_a2a/semantic/vocabulary.ex",
        "lib/ash_a2a/semantic/schema.ex",
        "lib/ash_a2a/semantic/planning_ir.ex",
        "lib/ash_a2a/semantic/execution_package.ex",
        "lib/ash_a2a/semantic/feedback.ex",
        "lib/ash_a2a/semantic_projection.ex",
        "lib/ash_a2a/semantic_subject.ex"
      ],
      "complexity": 9.0,
      "description": "Core domain implementing the closed-loop semantic pipeline that turns raw text into admitted semantics, an RDF-style ontology, and PlanningIR for formal planning. LLM output is always treated as untrusted candidate evidence with authority ':none'; a deterministic admission gate enforces full provenance before any artifact becomes admitted state, and every artifact is content-fingerprinted for replay.",
      "domain_type": "Core Business Domain",
      "importance": 8.5,
      "name": "Semantic Compilation",
      "sub_modules": [
        {
          "code_paths": [
            "lib/ash_a2a/semantic/compiler.ex"
          ],
          "description": "Central coordinator driving text through admitted semantics, ontology construction, PlanningIR manufacture, and plan-candidate generation, with an injectable ':generate_object' seam (ReqLLM in production, anonymous functions in tests).",
          "importance": 9.5,
          "key_functions": [
            "Orchestrate the full semantic compilation pipeline",
            "Invoke LLM generate_object for candidate extraction",
            "Dependency-injection seam replacing mocking libraries in tests"
          ],
          "name": "Pipeline Compiler"
        },
        {
          "code_paths": [
            "lib/ash_a2a/semantic/source.ex",
            "lib/ash_a2a/semantic/ir.ex",
            "lib/ash_a2a/semantic/planning_ir.ex",
            "lib/ash_a2a/semantic/execution_package.ex",
            "lib/ash_a2a/semantic/feedback.ex"
          ],
          "description": "Typed, candidate-only data models of the pipeline: content-addressed Source, thirteen-collection semantic IR, PlanningIR for HDDL/FOND, fingerprinted ExecutionPackage envelope, and authority-free Feedback derived from execution receipts.",
          "importance": 9.0,
          "key_functions": [
            "Normalize LLM maps into typed semantic IR",
            "Manufacture goals/objects/predicates/nondeterminism for planners",
            "Bind artifacts under content fingerprints with lineage"
          ],
          "name": "Candidate Artifacts"
        },
        {
          "code_paths": [
            "lib/ash_a2a/semantic/admission.ex"
          ],
          "description": "Deterministic gatekeeper validating candidate semantics against strict required-field contracts per collection, ensuring every admitted entity carries complete provenance via source_quote.",
          "importance": 8.5,
          "key_functions": [
            "Per-collection required-field validation",
            "Decide which LLM candidates become admitted state",
            "Enforce provenance completeness"
          ],
          "name": "Admission Gate"
        },
        {
          "code_paths": [
            "lib/ash_a2a/semantic/ontology.ex",
            "lib/ash_a2a/semantic/vocabulary.ex",
            "lib/ash_a2a/semantic/schema.ex"
          ],
          "description": "Projects admitted semantic IR into deterministic RDF-style triples via a shared vocabulary, suitable for semantic alignment and SPARQL spec queries.",
          "importance": 8.0,
          "key_functions": [
            "RDF-shaped triple projection of admitted IR",
            "Fingerprinted, admitted-only projections",
            "Shared vocabulary for deterministic output"
          ],
          "name": "Ontology Projection"
        },
        {
          "code_paths": [
            "lib/ash_a2a/semantic_projection.ex",
            "lib/ash_a2a/semantic_subject.ex"
          ],
          "description": "Supporting models for semantic subject identity and projection helpers shared across the pipeline and the command boundary.",
          "importance": 7.0,
          "key_functions": [
            "Semantic subject identity minting",
            "Cross-boundary semantic projection helpers"
          ],
          "name": "Semantic Support Models"
        }
      ]
    },
    {
      "code_paths": [
        "lib/ash_a2a/planning.ex",
        "lib/ash_a2a/planning/semantic_synthesis.ex",
        "lib/ash_a2a/llm_profiles.ex",
        "native/hddl_cli/Cargo.toml",
        "native/hddl_cli/src/main.rs"
      ],
      "complexity": 8.5,
      "description": "Supporting domain for AI-assisted planning over unknown boundaries. A configured LLM role proposes HDDL/FOND artifacts and A2A capability ids strictly as untrusted candidates; every proposal is re-validated via AshA2A.Info and every consequence-bearing action becomes a receipted command. A native Rust CLI bridges to the ferroplan FOND HTN solver for formal plan generation.",
      "domain_type": "Supporting Domain",
      "importance": 7.5,
      "name": "Planning Synthesis",
      "sub_modules": [
        {
          "code_paths": [
            "lib/ash_a2a/planning.ex",
            "lib/ash_a2a/planning/semantic_synthesis.ex",
            "lib/ash_a2a/llm_profiles.ex"
          ],
          "description": "LLM-driven synthesis of HDDL/FOND plan candidates and capability ids for goals outside known planning boundaries, with re-validation and command-based execution of consequences.",
          "importance": 8.5,
          "key_functions": [
            "Propose untrusted HDDL/FOND artifacts via configured LLM role",
            "Re-validate every proposed capability through AshA2A.Info",
            "Route consequence-bearing actions through CommandBus"
          ],
          "name": "Semantic Plan Synthesis"
        },
        {
          "code_paths": [
            "native/hddl_cli/Cargo.toml",
            "native/hddl_cli/src/main.rs"
          ],
          "description": "Rust hddl_cli binary wrapping the ferroplan library's solve_hddl FOND HTN solver, consuming domain/problem files and emitting JSON plans under a strict exit-code contract.",
          "importance": 8.0,
          "key_functions": [
            "Read domain and problem file paths from argv",
            "Invoke ferroplan solve_hddl",
            "Emit JSON plan (exit 0) or JSON error object (exit 1)"
          ],
          "name": "Native FOND Planner Bridge"
        }
      ]
    },
    {
      "code_paths": [
        "lib/ash_a2a/agent.ex",
        "lib/ash_a2a/application.ex",
        "lib/ash_a2a/durability/durable_server.ex",
        "lib/ash_a2a/task_lifecycle.ex",
        "lib/ash_a2a/runtime_receipt.ex",
        "lib/ash_a2a/topology/presence.ex",
        "lib/ash_a2a/topology/group.ex"
      ],
      "complexity": 7.0,
      "description": "Runtime domain that gives compiled capability indexes a live presence: the Agent behaviour compiles resources or domains into supervised A2A GenServers, the application wires supervision and receipt-store backends, and durability, task lifecycle, and topology modules keep agents resilient and cluster-aware across restarts.",
      "domain_type": "Supporting Domain",
      "importance": 7.5,
      "name": "Agent Runtime & Lifecycle",
      "sub_modules": [
        {
          "code_paths": [
            "lib/ash_a2a/agent.ex"
          ],
          "description": "`use AshA2A.Agent, resource_or_domain:` macro compiling a resource or domain into a runnable A2A Agent GenServer supervised by the host application.",
          "importance": 8.5,
          "key_functions": [
            "Compile capability index into supervised GenServer",
            "Receive A2A.Message structs under A2A.AgentSupervisor",
            "Expose agent card via the AgentCard builder"
          ],
          "name": "Agent Behaviour"
        },
        {
          "code_paths": [
            "lib/ash_a2a/application.ex"
          ],
          "description": "Supervision and configuration wiring, including receipt_store_children/0 that starts the configured receipt store backend.",
          "importance": 7.5,
          "key_functions": [
            "Compose agents and receipt store children from configuration",
            "Host-side supervision integration"
          ],
          "name": "Application Wiring"
        },
        {
          "code_paths": [
            "lib/ash_a2a/durability/durable_server.ex",
            "lib/ash_a2a/task_lifecycle.ex",
            "lib/ash_a2a/runtime_receipt.ex"
          ],
          "description": "Durable server and task lifecycle state management with runtime receipts, allowing agent work to survive process and node restarts.",
          "importance": 7.5,
          "key_functions": [
            "Durable agent server resilient to restarts",
            "Task lifecycle state tracking",
            "Runtime receipts for lifecycle evidence"
          ],
          "name": "Durability & Task Lifecycle"
        },
        {
          "code_paths": [
            "lib/ash_a2a/topology/presence.ex",
            "lib/ash_a2a/topology/group.ex"
          ],
          "description": "Cluster presence tracking and agent grouping built on runtime receipts for multi-node deployments.",
          "importance": 6.5,
          "key_functions": [
            "Node/agent presence tracking",
            "Agent group management"
          ],
          "name": "Topology"
        }
      ]
    },
    {
      "code_paths": [
        "lib/ash_a2a/delivery.ex",
        "lib/ash_a2a/delivery/oban.ex",
        "lib/ash_a2a/execution/flame.ex",
        "lib/ash_a2a/reactor/execute_command.ex",
        "lib/ash_a2a/telemetry/ocel_forwarder.ex"
      ],
      "complexity": 6.0,
      "description": "Infrastructure domain of pluggable adapters that connect the receipted command pipeline to external runtimes: Oban for durable delivery, FLAME for elastic off-node execution, Reactor for workflow-step execution, and an OCEL forwarder exporting receipts and dispatcher spans to external telemetry sinks. All adapters funnel through the CommandBus and never bypass its checks.",
      "domain_type": "Infrastructure Domain",
      "importance": 6.5,
      "name": "Integration Adapters",
      "sub_modules": [
        {
          "code_paths": [
            "lib/ash_a2a/delivery.ex",
            "lib/ash_a2a/delivery/oban.ex"
          ],
          "description": "Delivery layer with an Oban-backed adapter for durable, queued command dispatch.",
          "importance": 7.0,
          "key_functions": [
            "Enqueue commands as durable Oban jobs",
            "Deliver commands into the CommandBus"
          ],
          "name": "Delivery Adapters"
        },
        {
          "code_paths": [
            "lib/ash_a2a/execution/flame.ex",
            "lib/ash_a2a/reactor/execute_command.ex"
          ],
          "description": "Execution backends running command execution off the host node via FLAME and exposing command execution as a Reactor workflow step.",
          "importance": 7.0,
          "key_functions": [
            "Remote command execution via FLAME",
            "Reactor step invoking AshA2A.CommandBus"
          ],
          "name": "Execution Adapters"
        },
        {
          "code_paths": [
            "lib/ash_a2a/telemetry/ocel_forwarder.ex"
          ],
          "description": "OCEL forwarder exporting command receipts and dispatcher spans to external observability targets.",
          "importance": 6.5,
          "key_functions": [
            "Forward command bus receipts as OCEL events",
            "Forward dispatcher spans for runtime observability"
          ],
          "name": "Telemetry Forwarder"
        }
      ]
    },
    {
      "code_paths": [
        "lib/mix/tasks/ash_a2a.install.ex",
        "lib/mix/tasks/ash_a2a.verify_architecture.ex",
        "lib/mix/tasks/eds.ledger.ex",
        "lib/ash_a2a/architecture_verifier.ex",
        "lib/ash_a2a/research/erc.ex",
        "research/erc/",
        "priv/ggen/ash_a2a/ontology.ttl",
        "priv/ggen/ash_a2a/queries/spec.rq",
        "priv/ggen/ash_a2a/templates/extension.ex.eex",
        "bench/ash_a2a_bench.exs",
        "config/config.exs"
      ],
      "complexity": 5.5,
      "description": "Tool support domain for adopters and maintainers: Mix tasks for installation and architecture verification, an EDS evidence ledger over ERC research records, benchmarking of dispatcher/command-bus hot paths, and ggen spec assets (ontology.ttl, SPARQL queries, EEx scaffolding templates) that keep the codebase aligned with its documented architecture invariants.",
      "domain_type": "Tool Support Domain",
      "importance": 5.5,
      "name": "Developer Tooling & Governance",
      "sub_modules": [
        {
          "code_paths": [
            "lib/mix/tasks/ash_a2a.install.ex",
            "lib/mix/tasks/ash_a2a.verify_architecture.ex",
            "lib/ash_a2a/architecture_verifier.ex"
          ],
          "description": "Install scaffolding for host applications and automated verification that the codebase conforms to documented architecture rules.",
          "importance": 7.0,
          "key_functions": [
            "Scaffold AshA2A into a host app",
            "Run architecture invariant checks (mix ash_a2a.verify_architecture)"
          ],
          "name": "Mix Tasks & Architecture Verification"
        },
        {
          "code_paths": [
            "lib/mix/tasks/eds.ledger.ex",
            "lib/ash_a2a/research/erc.ex",
            "research/erc/"
          ],
          "description": "ERC evidence store and ledger task recording research decisions as structured JSON documents under research/erc.",
          "importance": 5.5,
          "key_functions": [
            "Read/write ERC-*.json evidence entries",
            "EDS ledger Mix task"
          ],
          "name": "Research & Evidence Ledger"
        },
        {
          "code_paths": [
            "priv/ggen/ash_a2a/ontology.ttl",
            "priv/ggen/ash_a2a/queries/spec.rq",
            "priv/ggen/ash_a2a/templates/extension.ex.eex",
            "bench/ash_a2a_bench.exs",
            "config/config.exs",
            "config/test.exs"
          ],
          "description": "Generated specification assets (ontology.ttl, spec.rq SPARQL queries, extension EEx templates) and benchmark scripts exercising dispatcher and command bus performance.",
          "importance": 5.5,
          "key_functions": [
            "SPARQL spec queries over the pack ontology",
            "EEx template-based scaffolding",
            "Benchmark dispatcher and command bus paths"
          ],
          "name": "Spec Assets & Benchmarks"
        }
      ]
    }
  ],
  "domain_relations": [
    {
      "description": "The dispatcher resolves skills exclusively through the persisted, verified capability index via AshA2A.Info, never by walking raw DSL entities, so dispatch can never diverge from the advertised AgentCard.",
      "from_domain": "Message Dispatch & Trust Boundary",
      "relation_type": "Service Call",
      "strength": 9.0,
      "to_domain": "Capability Projection & Discovery"
    },
    {
      "description": "The CommandBus is the single sanctioned path from an admitted command to the dispatcher; it invokes Ash actions only after capability, identity, replay, and evidence checks pass.",
      "from_domain": "Receipted Command Execution",
      "relation_type": "Service Call",
      "strength": 9.0,
      "to_domain": "Message Dispatch & Trust Boundary"
    },
    {
      "description": "LLM-proposed consequence-bearing actions are constructed as commands and must enter execution through AshA2A.CommandBus, never executed directly.",
      "from_domain": "Planning Synthesis",
      "relation_type": "Service Call",
      "strength": 7.0,
      "to_domain": "Receipted Command Execution"
    },
    {
      "description": "Every LLM-proposed A2A capability id is re-validated against the real capability index through AshA2A.Info before any use.",
      "from_domain": "Planning Synthesis",
      "relation_type": "Data Dependency",
      "strength": 6.0,
      "to_domain": "Capability Projection & Discovery"
    },
    {
      "description": "Semantic synthesis consumes fingerprinted PlanningIR and ExecutionPackage artifacts produced by the semantic compilation pipeline as its candidate inputs.",
      "from_domain": "Planning Synthesis",
      "relation_type": "Data Dependency",
      "strength": 7.0,
      "to_domain": "Semantic Compilation"
    },
    {
      "description": "PlanningIR artifacts flow into the native hddl_cli/ferroplan solver via file handoff to obtain formal FOND plan candidates.",
      "from_domain": "Semantic Compilation",
      "relation_type": "Data Dependency",
      "strength": 5.0,
      "to_domain": "Planning Synthesis"
    },
    {
      "description": "AshA2A.Application composes receipt store children from configuration, and the durable server relies on runtime receipts and task lifecycle state for resilience.",
      "from_domain": "Agent Runtime & Lifecycle",
      "relation_type": "Composition",
      "strength": 6.0,
      "to_domain": "Receipted Command Execution"
    },
    {
      "description": "The Agent behaviour backs a compiled capability index with a supervised GenServer and publishes its AgentCard through the AgentCard builder.",
      "from_domain": "Agent Runtime & Lifecycle",
      "relation_type": "Composition",
      "strength": 6.0,
      "to_domain": "Capability Projection & Discovery"
    },
    {
      "description": "Oban delivery jobs, FLAME remote execution, and Reactor steps all funnel command execution through AshA2A.CommandBus and its checks.",
      "from_domain": "Integration Adapters",
      "relation_type": "Service Call",
      "strength": 8.0,
      "to_domain": "Receipted Command Execution"
    },
    {
      "description": "The OCEL telemetry forwarder consumes dispatcher spans produced by the dispatch path for external observability.",
      "from_domain": "Integration Adapters",
      "relation_type": "Data Dependency",
      "strength": 4.0,
      "to_domain": "Message Dispatch & Trust Boundary"
    },
    {
      "description": "The architecture verifier and benchmark scripts exercise and enforce the dispatch/command-bus layering invariants documented in the PRD/ARD.",
      "from_domain": "Developer Tooling & Governance",
      "relation_type": "Governance Verification",
      "strength": 4.0,
      "to_domain": "Message Dispatch & Trust Boundary"
    },
    {
      "description": "SPARQL spec queries operate over the generated ontology.ttl of the semantic pack, and the ERC ledger records research evidence for the pipeline.",
      "from_domain": "Developer Tooling & Governance",
      "relation_type": "Data Dependency",
      "strength": 3.0,
      "to_domain": "Semantic Compilation"
    }
  ]
}
```

### Workflow Research Report
Contains static analysis results of the codebase and business process analysis.

```json
"# System Workflow Analysis\n\n**Project**: `ash_a2a` — An Elixir framework and Spark DSL extension that projects public Ash resource actions into A2A (Agent-to-Agent) protocol skills, with receipted command execution and a semantic compilation pipeline for formal planning.\n\n---\n\n## 1. Main Workflow\n\n- **Workflow Name**: Inbound A2A Message Dispatch Flow\n- **Importance**: 10.0 (highest in the system)\n- **Description**: This is the core runtime workflow of the framework. An external A2A client sends an `A2A.Message` to a supervised `AshA2A.Agent` GenServer. The message first crosses a named trust boundary (`ContextResolver`), which converts raw protocol metadata into a validated `ExecutionContext` containing only the fields Ash actions accept (actor, tenant, etc.). The dispatcher then resolves the target skill exclusively through the persisted, verified capability index — never by walking raw DSL entities — guaranteeing that what was advertised in the AgentCard is exactly what executes. Consequence-bearing work is funneled through the `CommandBus` with receipt-backed idempotency, the real Ash action executes, a replayable receipt is persisted, and an A2A reply tuple is returned to the caller.\n\n- **Flow Diagram**:\n\n```mermaid\ngraph TD\n    ClientMsg[\"A2A client sends A2A.Message\"] --> AgentGenServer[\"Supervised AshA2A.Agent GenServer receives message\"]\n    AgentGenServer --> ContextResolution[\"ContextResolver.from_a2a_message builds validated ExecutionContext\"]\n    ContextResolution --> SkillLookup[\"Dispatcher resolves skill via persisted capability index through AshA2A.Info\"]\n    SkillLookup --> SkillFound{\"Skill found?\"}\n    SkillFound -->|\"No\"| ErrorResponse[\"Return A2A error reply\"]\n    SkillFound -->|\"Yes\"| ConsequenceCheck{\"Consequence-bearing action?\"}\n    ConsequenceCheck -->|\"Yes\"| CommandAdmission[\"CommandBus enforces capability, identity, replay, and evidence checks\"]\n    CommandAdmission --> ClaimReceipt[\"ReceiptStore atomically claims command id\"]\n    ClaimReceipt --> ReplayCheck{\"Fingerprint outcome\"}\n    ReplayCheck -->|\"Same id, same fingerprint\"| StoredReceipt[\"Replay stored receipt for idempotent result\"]\n    ReplayCheck -->|\"Same id, different fingerprint\"| ConflictRefusal[\"Refuse conflicting retry\"]\n    ReplayCheck -->|\"Fresh claim\"| ActionInvocation[\"Dispatcher invokes real Ash action with resolved context\"]\n    ConsequenceCheck -->|\"No\"| ActionInvocation\n    ActionInvocation --> PersistReceipt[\"Persist replayable receipt with observed outcome\"]\n    PersistReceipt --> Reply[\"Return A2A.Agent reply tuple\"]\n    StoredReceipt --> Reply\n    ConflictRefusal --> Reply\n    ErrorResponse --> Reply\n```\n\n- **Key Steps**:\n  1. **Message Ingress** — A supervised GenServer (created via `use AshA2A.Agent, resource_or_domain:`) receives the `A2A.Message`.\n  2. **Trust Boundary Crossing** — `ContextResolver.from_a2a_message/2` is the mandatory passage point; raw A2A metadata never reaches Ash calls directly (PRD/ARD §3.5).\n  3. **Verified Skill Resolution** — Skills are looked up via `AshA2A.Info` against the persisted capability index, so dispatch can never diverge from the advertised AgentCard (PRD/ARD §3.2).\n  4. **Receipted Admission** — Consequence-bearing commands are admitted through `CommandBus`, the single sanctioned execution path, with atomic command-id claims in the receipt store.\n  5. **Ash Action Execution** — The dispatcher invokes the mapped, real Ash action with the resolved execution context.\n  6. **Receipt Persistence** — The attempt and observed outcome are recorded as a replayable `Receipt` (in-memory or durable EKV backend).\n  7. **Reply** — The caller receives an `A2A.Agent` reply tuple, whether execution succeeded, replayed, was refused, or errored.\n\n---\n\n## 2. Other Important Workflows\n\n### 2.1 Capability Projection & AgentCard Discovery Flow\n\n- **Description**: The compile-time-to-runtime flow that turns public Ash resource actions into discoverable A2A skills with zero hand-written protocol glue. The host attaches the AshA2A extension, a Spark transformer compiles a capability index from introspected public actions, residual DSL overrides are fail-closed validated (they may describe or suppress existing capabilities but can never invent new ones), and a deterministic AgentCard is published to A2A clients with a supervised agent backing it.\n\n- **Flow Diagram**:\n\n```mermaid\ngraph TD\n    AttachExt[\"Host attaches extension via use Ash.Resource with AshA2A\"] --> DeclareDSL[\"DSL registers a2a section with optional residual skill overrides\"]\n    DeclareDSL --> SparkTransform[\"Spark compile-time transformer triggers CapabilityIndex.Compiler\"]\n    SparkTransform --> Introspect[\"Introspect Ash.Resource.Info.public_actions\"]\n    Introspect --> DeriveSkills[\"Derive canonical skills keyed by resource and action pairs\"]\n    DeriveSkills --> OverridesPresent{\"Residual a2a overrides declared?\"}\n    OverridesPresent -->|\"Yes\"| ValidateOverrides[\"Validator fail-closed check: overrides must name real, public actions\"]\n    ValidateOverrides --> OverrideValid{\"Override valid?\"}\n    OverrideValid -->|\"No\"| Refusal[\"Structured refusal: compile fails\"]\n    OverrideValid -->|\"Yes\"| LayerOverrides[\"Layer A2A metadata overrides onto introspected base\"]\n    OverridesPresent -->|\"No\"| LayerOverrides\n    LayerOverrides --> PersistResidual[\"Persist only residual overrides plus resource-vs-domain flag\"]\n    PersistResidual --> DeriveIndex[\"AshA2A.Info derives current capability index on demand\"]\n    DeriveIndex --> BuildCard[\"AgentCardBuilder projects index into deterministic A2A AgentCard\"]\n    BuildCard --> Supervise[\"Agent behaviour backs index with supervised GenServer\"]\n    Supervise --> Publish[\"AgentCard published for A2A client discovery\"]\n```\n\n- **Key Guarantee**: Capability derivation always flows from `Ash.Resource.Info.public_actions/1`. The index is a projection, never a second business model, and argument schemas are always introspected from real actions rather than trusted from declarations.\n\n### 2.2 Receipted Command Execution Flow (Integration Adapters)\n\n- **Description**: The idempotent, replay-safe execution path used by delivery and execution adapters (Oban, FLAME, Reactor). A command is claimed atomically by the receipt store, checked and dispatched by the CommandBus, and its receipt persisted durably. Retries with the same content-derived fingerprint replay the stored receipt; conflicting fingerprints are refused.\n\n- **Flow Diagram**:\n\n```mermaid\ngraph TD\n    AdapterEntry[\"Adapter entry: Oban job, FLAME worker, or Reactor step\"] --> BuildCommand[\"Construct Command envelope with content-derived fingerprint\"]\n    BuildCommand --> BusReceive[\"CommandBus receives admitted command\"]\n    BusReceive --> EnforceChecks[\"Verify capability, identity, replay, and evidence\"]\n    EnforceChecks --> ChecksPass{\"Checks pass?\"}\n    ChecksPass -->|\"No\"| Reject[\"Reject with structured refusal\"]\n    ChecksPass -->|\"Yes\"| AtomicClaim[\"ReceiptStore atomically claims command id\"]\n    AtomicClaim --> ClaimResult{\"Claim result\"}\n    ClaimResult -->|\"Existing same fingerprint\"| Replay[\"Replay stored receipt\"]\n    ClaimResult -->|\"Existing conflicting fingerprint\"| Conflict[\"Refuse conflict\"]\n    ClaimResult -->|\"Fresh claim\"| Execute[\"Dispatcher executes real Ash action\"]\n    Execute --> CommitDurable[\"Commit receipt to durable EKV store\"]\n    CommitDurable --> ReturnReceipt[\"Return receipt and outcome to caller\"]\n    Replay --> ReturnReceipt\n    Conflict --> ReturnReceipt\n    Reject --> ReturnReceipt\n```\n\n- **Key Guarantee**: Fingerprint derivation uses only semantic command content, so retries carrying fresh transport timestamps still prove the same intent against the same manufactured subject. The durable EKV backend ensures receipts survive process and node restarts.\n\n### 2.3 Semantic Compilation Pipeline Flow\n\n- **Description**: A closed-loop pipeline from raw text to a formal FOND plan candidate. Raw evidence is anchored as a content-addressed `Source`, an LLM proposes a candidate semantic IR (always authority-free), a deterministic admission gate enforces full provenance before admission, admitted IR is projected into an RDF-style ontology and `PlanningIR`, the native ferroplan solver produces a plan candidate, and everything is bound into a fingerprinted `ExecutionPackage`.\n\n- **Flow Diagram**:\n\n```mermaid\ngraph TD\n    RawInput[\"Raw text submitted to Semantic.Compiler\"] --> AnchorSource[\"Anchor content-addressed Source with media type, observation time, provenance\"]\n    AnchorSource --> LLMExtract[\"Invoke LLM via injectable generate_object: ReqLLM.generate_object in production\"]\n    LLMExtract --> NormalizeIR[\"Normalize LLM map into typed candidate IR: standing candidate, authority none\"]\n    NormalizeIR --> AdmissionGate[\"Admission gate validates required fields per collection\"]\n    AdmissionGate --> Provenanced{\"Fully provenanced via source_quote?\"}\n    Provenanced -->|\"No\"| Refused[\"Candidate refused, nothing admitted\"]\n    Provenanced -->|\"Yes\"| AdmittedIR[\"Admitted semantic IR\"]\n    AdmittedIR --> OntologyTriples[\"Ontology projects admitted IR into fingerprinted RDF-style triples\"]\n    AdmittedIR --> PlanningIR[\"PlanningIR manufactured: goals, objects, predicates, nondeterminism markers\"]\n    PlanningIR --> Solver[\"Native hddl_cli invokes ferroplan FOND HTN solver\"]\n    Solver --> SolveOutcome{\"Exit code\"}\n    SolveOutcome -->|\"Exit 0\"| PlanJSON[\"Plan candidate emitted as JSON\"]\n    SolveOutcome -->|\"Exit 1\"| PlanError[\"JSON error object returned\"]\n    PlanJSON --> BindPackage[\"ExecutionPackage binds source, IR, ontology, PlanningIR, plan under content fingerprint\"]\n    BindPackage --> ReadyForPlanning[\"Coherent, replayable candidate bundle ready for planning and runtime boundaries\"]\n```\n\n- **Key Guarantee**: Everything the LLM proposes is untrusted evidence until the deterministic admission gate validates complete provenance. The `:generate_object` option is a dependency-injection seam (real `ReqLLM.generate_object/4` in production, anonymous functions in tests), avoiding mocking libraries.\n\n### 2.4 LLM Plan Synthesis & Receipted Feedback Flow\n\n- **Description**: AI-assisted planning for goals outside known planning boundaries. A configured LLM role proposes HDDL/FOND artifacts and A2A capability ids strictly as untrusted candidates; each proposal is re-validated against the real capability index, consequence-bearing actions are executed as receipted commands, and execution receipts are converted into authority-free feedback that closes the planning loop.\n\n- **Flow Diagram**:\n\n```mermaid\ngraph TD\n    UnknownGoal[\"Planning boundary cannot resolve goal from known plans\"] --> InvokeSynthesis[\"SemanticSynthesis invoked with configured LLM profile\"]\n    InvokeSynthesis --> LLMPropose[\"LLM proposes HDDL/FOND artifacts and A2A capability ids as untrusted candidates\"]\n    LLMPropose --> Revalidate[\"Re-validate every proposed capability id via AshA2A.Info against real index\"]\n    Revalidate --> AllValid{\"All proposed capabilities valid?\"}\n    AllValid -->|\"No\"| RejectProposal[\"Reject proposal with structured refusal\"]\n    AllValid -->|\"Yes\"| ConstructCommand[\"Construct Command bound to semantic subject with content-derived fingerprint\"]\n    ConstructCommand --> BusExecution[\"CommandBus executes admitted command through receipted route\"]\n    BusExecution --> ReceiptPersisted[\"Receipt persisted with observed outcome\"]\n    ReceiptPersisted --> ConvertFeedback[\"Feedback converts receipt into typed observation: standing observed, authority none\"]\n    ConvertFeedback --> CloseLoop[\"Fingerprint-tied feedback enables evidence-based re-planning\"]\n```\n\n- **Key Guarantee**: Security is a first-class concern — the model's output never carries authority, and any consequence-bearing action must be constructed as a command entering `AshA2A.CommandBus`, never executed directly.\n\n---\n\n## 3. Workflow Insights\n\n### Operational Patterns\n\n1. **Single Canonical Source Invariant**: The system's central design decision is that both the advertised surface (AgentCard) and the executed behavior (Ash action dispatch) are projections of one source — `Ash.Resource.Info.public_actions/1`. This makes \"advertised ≠ executed\" divergence structurally impossible rather than merely tested against.\n\n2. **Fail-Closed Validation at Every Boundary**: Every entry point refuses rather than degrades — the override validator rejects references to private or nonexistent actions; the admission gate refuses unprovenanced LLM candidates; the CommandBus refuses conflicting fingerprint retries; the solver CLI communicates failure via exit-code contract. Invalid input never \"partially succeeds.\"\n\n3. **Candidate-Then-Admit Pattern for AI Output**: LLM output follows a uniform lifecycle — proposed as authority-free, fingerprinted candidates (`:candidate` / `:none`), deterministically admitted with full provenance, then projected into derived artifacts. The same pattern governs semantic IR, plans, and capability proposals.\n\n4. **Receipts and Fingerprints as Universal Evidence**: Content-derived fingerprints and replayable receipts are the system-wide evidence mechanism, enabling idempotency (CommandBus), lineage (ExecutionPackage), re-planning (Feedback), and even cluster topology (presence tracking on runtime receipts).\n\n5. **Deterministic Derivation over Generation**: Wherever possible, artifacts are derived deterministically (AgentCard building, ontology triples, capability indexes) rather than authored, ensuring replayability and auditability.\n\n### Dependencies Between Workflows\n\n- **Dispatch depends on Capability Projection**: The dispatcher resolves skills exclusively through the persisted, verified index — this is the strongest coupling in the system (strength 9.0) and the mechanism that guarantees advertised/executed alignment.\n- **Command Execution gates everything consequential**: The CommandBus is the single sanctioned path; the dispatch flow, planning synthesis, and all integration adapters (Oban, FLAME, Reactor) funnel through it and cannot bypass its checks.\n- **Planning Synthesis spans three domains**: It consumes fingerprinted artifacts from Semantic Compilation, re-validates against Capability Projection, and executes through Receipted Command Execution, then feeds receipts back as authority-free observations — the only true closed loop in the system.\n- **Runtime & Lifecycle composes the rest**: Agent supervision, receipt-store wiring (`receipt_store_children/0`), and durability modules give the above workflows live, resilient presence.\n\n### Validation Against Documented Processes\n\n- All five documented business flows (domain research report) match the implemented code paths — entry points, trust boundary, and persistence layers align consistently.\n- **Noted alignment nuance**: Receipt-related code is deliberately split between the command domain (`receipt.ex`, `receipt_store/` — evidence of command attempts) and the runtime domain (`runtime_receipt.ex` — evidence of lifecycle state). Documentation should continue to emphasize this distinction to avoid confusion, as the two receipt types serve different invariants.\n- No discrepancies were found between the documented invariants (PRD/ARD §3.2, §3.5) and the observed workflow implementations.\n\n### Potential Optimization Opportunities\n\n- **LLM extraction latency** is the dominant cost in the Semantic Compilation pipeline; batching sources or caching admitted artifacts by content fingerprint (already supported by the content-addressed `Source` identity) could avoid redundant model invocations for identical inputs.\n- **Native solver subprocess overhead**: The `hddl_cli` bridge communicates via file I/O and process exit codes. For high-frequency planning, an in-process NIF or persistent solver process could reduce handoff cost, though the current file-based contract maximizes isolation and debuggability.\n- **Receipt store contention**: Atomic command-id claims are the serialization point of the CommandBus path; the EKV backend should be monitored under high-retry workloads, though the replay behavior itself already minimizes duplicate Ash executions.\n- **Capability index derivation** is computed on demand through `AshA2A.Info`; for hot dispatch paths, memoizing the derived index per compilation would be a safe optimization since derivation is deterministic."
```

### Code Insights Data
Code analysis results from preprocessing phase, including definitions of functions, classes, and modules.

```json
{
  "directory_insights": [
    {
      "file_count": 1,
      "file_insights": [
        {
          "code_purpose": "test",
          "dependencies": [
            {
              "dependency_type": "import",
              "is_external": true,
              "line_number": null,
              "name": ":timer",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "import",
              "is_external": true,
              "line_number": null,
              "name": "Mix",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "import",
              "is_external": false,
              "line_number": null,
              "name": "AshA2a",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "This script serves as a performance benchmark harness for the ash_a2a project, executed via 'mix run bench/ash_a2a_bench.exs'. It deliberately avoids external benchmarking libraries such as Benchee to keep the project's dependency footprint clean. It runs the application in the :dev Mix environment, performs a real warm-up loop, collects timed samples, and computes nearest-rank percentiles by hand.",
          "file_path": "/Users/sac/ash_a2a/bench/ash_a2a_bench.exs",
          "importance_score": 0.35,
          "interfaces": [
            {
              "description": null,
              "interface_type": "function",
              "name": "run",
              "parameters": [],
              "return_type": ":ok (prints latency percentile results to stdout)",
              "visibility": ""
            },
            {
              "description": null,
              "interface_type": "function",
              "name": "percentile",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "sorted_samples",
                  "param_type": "list(number())"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "p",
                  "param_type": "number()"
                }
              ],
              "return_type": "number()",
              "visibility": ""
            }
          ],
          "name": "ash_a2a_bench.exs",
          "responsibilities": [
            "Boot the ash_a2a application via mix run in the :dev environment",
            "Time ash_a2a operations with :timer.tc/1 for wall-clock latency",
            "Perform a warm-up loop before collecting measurements",
            "Compute p50/p95/p99 percentiles from sorted samples using the nearest-rank method",
            "Avoid external benchmark dependencies to keep the project dependency-free"
          ],
          "source_summary": "The script is a self-contained, dependency-free benchmark that uses :timer.tc/1 from the Erlang/Elixir stdlib to capture wall-clock execution times of ash_a2a operations. It includes documentation headers explaining how to run it, boots the app under Mix.env() == :dev via mix run, executes a warm-up loop before measurement, gathers a real sorted sample list, and manually computes p50/p95/p99 latencies using the nearest-rank method rather than simulating results.",
          "summary": "A standalone Elixir benchmark script that measures latency of the ash_a2a application using only standard library timing facilities, reporting percentile statistics."
        }
      ],
      "importance_score": 0.3,
      "key_files": [
        "ash_a2a_bench.exs"
      ],
      "name": "bench",
      "path": "/Users/sac/ash_a2a/bench",
      "purpose": "other",
      "subdirectory_count": 0,
      "summary": "The bench directory contains a lightweight, dependency-free benchmarking script for the ash_a2a Elixir project. Its single file measures wall-clock latency of ash_a2a operations using only Erlang's :timer.tc/1, computing p50/p95/p99 percentiles from real samples after a warm-up phase, without adding external dependencies like Benchee."
    },
    {
      "file_count": 1,
      "file_insights": [
        {
          "code_purpose": "config",
          "dependencies": [
            {
              "dependency_type": "import",
              "is_external": true,
              "line_number": null,
              "name": "Config",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "include",
              "is_external": false,
              "line_number": null,
              "name": "test.exs",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "This file is the entry point for application configuration in the Mix build system and is evaluated automatically when the project is compiled or run. It configures a global default for the Ash framework so string length validations count codepoints, and it delegates to test.exs for test-environment overrides. Although minimal in content, it is essential infrastructure that all runtime configuration flows through.",
          "file_path": "/Users/sac/ash_a2a/config/config.exs",
          "importance_score": 0.4,
          "interfaces": [
            {
              "description": null,
              "interface_type": "function",
              "name": "config_env",
              "parameters": [],
              "return_type": "atom",
              "visibility": ""
            },
            {
              "description": null,
              "interface_type": "macro",
              "name": "import_config",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "file",
                  "param_type": "string"
                }
              ],
              "return_type": "void",
              "visibility": ""
            }
          ],
          "name": "config.exs",
          "responsibilities": [
            "Bootstrap application configuration for the Mix project",
            "Set global Ash framework defaults (string length counted in codepoints)",
            "Detect the current runtime environment via config_env()",
            "Conditionally import environment-specific configuration from test.exs"
          ],
          "source_summary": "The file imports the Config module, then sets the :ash application option default_string_length_count to :codepoints, ensuring Ash measures string lengths in Unicode codepoints. Finally, it checks config_env() and conditionally calls import_config \"test.exs\" to merge test-specific configuration when the MIX_ENV is set to test.",
          "summary": "Root Mix configuration file for the Elixir project that sets framework-level defaults and imports environment-specific configuration."
        }
      ],
      "importance_score": 0.4,
      "key_files": [
        "config.exs"
      ],
      "name": "config",
      "path": "/Users/sac/ash_a2a/config",
      "purpose": "config",
      "subdirectory_count": 0,
      "summary": "The config directory contains the root Mix configuration for this Elixir project, which appears to use the Ash declarative application framework. Its single file, config.exs, bootstraps application-wide configuration by setting a global Ash option (string length counted in codepoints) and conditionally loading environment-specific settings from test.exs when running in the test environment."
    },
    {
      "file_count": 1,
      "file_insights": [
        {
          "code_purpose": "plugin",
          "dependencies": [
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "Ash",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "import",
              "is_external": true,
              "line_number": null,
              "name": "Ash.Resource.Info",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "Spark",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "This file declares the AshA2A extension that users attach via `use Ash.Resource, extensions: [AshA2A]`. It enables zero-configuration capability discovery by automatically projecting every public action from Ash.Resource.Info.public_actions/1 into an A2A skill, while allowing an optional `a2a` DSL block to override metadata or suppress specific actions.",
          "file_path": "/Users/sac/ash_a2a/lib/ash_a2a.ex",
          "importance_score": 0.95,
          "interfaces": [
            {
              "description": null,
              "interface_type": "dsl_section",
              "name": "a2a",
              "parameters": [],
              "return_type": "Spark DSL section",
              "visibility": ""
            },
            {
              "description": null,
              "interface_type": "dsl_entity",
              "name": "skill",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "name",
                  "param_type": "atom"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "action_kind",
                  "param_type": "atom"
                }
              ],
              "return_type": "A2A skill definition",
              "visibility": ""
            },
            {
              "description": null,
              "interface_type": "module",
              "name": "extensions",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "resource",
                  "param_type": "module"
                }
              ],
              "return_type": "AshA2A extension attached via use Ash.Resource",
              "visibility": ""
            }
          ],
          "name": "ash_a2a.ex",
          "responsibilities": [
            "Expose AshA2A as a Spark DSL extension for Ash resources",
            "Automatically project all public resource actions into A2A skills",
            "Define the `a2a` DSL section with `skill` entities for metadata overrides and action suppression",
            "Document extension usage, configuration semantics, and versioning (v26.9.12)"
          ],
          "source_summary": "Contains the AshA2A module whose moduledoc documents version v26.9.12's zero-configuration capability discovery. It explains that all public resource actions are automatically projected into A2A skills, and that an optional `a2a` block with `skill` entities (e.g., `skill :search, :read do description ... end`) can override A2A-specific metadata such as descriptions or suppress otherwise-public actions.",
          "summary": "Defines the AshA2A Spark DSL extension that projects public Ash resource actions into A2A protocol skills, serving as the top-level entry point of the library."
        }
      ],
      "importance_score": 0.9,
      "key_files": [
        "ash_a2a.ex"
      ],
      "name": "lib",
      "path": "/Users/sac/ash_a2a/lib",
      "purpose": "core",
      "subdirectory_count": 2,
      "summary": "The lib directory is the core of an Elixir library that integrates the Ash Framework with the A2A (Agent-to-Agent) protocol. The single top-level file ash_a2a.ex defines the AshA2A Spark DSL extension, which resources attach to automatically project their public actions into discoverable A2A skills, with subdirectories presumably containing supporting implementation modules for that projection pipeline."
    },
    {
      "file_count": 26,
      "file_insights": [
        {
          "code_purpose": "agent",
          "dependencies": [
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "A2A.Agent",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "A2A.AgentSupervisor",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "alias",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.Dispatcher",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "Provides a `use AshA2A.Agent, resource_or_domain:` macro so a compiled capability index is backed by an actual supervised process rather than just a synchronous dispatcher function. Host applications supervise the generated agent under A2A.AgentSupervisor and send A2A.Message structs to it.",
          "file_path": "/Users/sac/ash_a2a/lib/ash_a2a/agent.ex",
          "importance_score": 0.85,
          "interfaces": [
            {
              "description": null,
              "interface_type": "macro",
              "name": "use AshA2A.Agent",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "resource_or_domain",
                  "param_type": "module()"
                }
              ],
              "return_type": "module()",
              "visibility": ""
            }
          ],
          "name": "agent.ex",
          "responsibilities": [
            "Generate a supervised A2A agent GenServer from an Ash resource or domain",
            "Route inbound A2A messages into the AshA2A dispatch pipeline",
            "Integrate with A2A.AgentSupervisor for lifecycle management"
          ],
          "source_summary": "Defines the AshA2A.Agent module whose moduledoc shows a MyApp.EchoAgent example using `use AshA2A.Agent, resource_or_domain: MyApp.Echo` and supervision under A2A.AgentSupervisor. It bridges the persisted capability index and dispatcher into a live, message-receiving GenServer.",
          "summary": "Implements the AshA2A.Agent behaviour that compiles an Ash resource or domain into a runnable A2A.Agent GenServer."
        },
        {
          "code_purpose": "entry",
          "dependencies": [
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "A2A.AgentSupervisor",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "alias",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.Telemetry.OcelForwarder",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "alias",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.ReceiptStore",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "The package entry point builds its supervision tree from `config :ash_a2a, :agents`, starts the default receipt store, and attaches telemetry. Host applications may replace the :receipt_store with another AshA2A.ReceiptStore implementation that owns its own supervision.",
          "file_path": "/Users/sac/ash_a2a/lib/ash_a2a/application.ex",
          "importance_score": 0.7,
          "interfaces": [
            {
              "description": null,
              "interface_type": "function",
              "name": "start",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "type",
                  "param_type": "atom()"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "args",
                  "param_type": "keyword()"
                }
              ],
              "return_type": "{:ok, pid()}",
              "visibility": ""
            }
          ],
          "name": "application.ex",
          "responsibilities": [
            "Start the application supervision tree",
            "Launch configured A2A agents",
            "Start the default replay receipt store",
            "Attach telemetry forwarding"
          ],
          "source_summary": "Implements start/2, reading configured agents from application env, starting A2A.AgentSupervisor children plus the default replay receipt store, and attaching the AshA2A.Telemetry.OcelForwarder as noted in comments.",
          "summary": "OTP application callback that starts the A2A agent supervisor and the default replay receipt store."
        },
        {
          "code_purpose": "test",
          "dependencies": [
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "Ash.Resource",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "Because mix.exs only adds test/support to elixirc_paths in the :test environment, the architecture verifier needs its own in-lib fixture resource. This file supplies that minimal Ash.Resource so verification can run in any environment.",
          "file_path": "/Users/sac/ash_a2a/lib/ash_a2a/architecture_verifier.ex",
          "importance_score": 0.4,
          "interfaces": [],
          "name": "architecture_verifier.ex",
          "responsibilities": [
            "Provide a minimal Ash resource fixture for architecture verification",
            "Enable verifier checks regardless of elixirc_paths environment"
          ],
          "source_summary": "Declares AshA2A.ArchitectureVerifier.Fixture.Resource with SPDX headers and a moduledoc explaining it is the real minimal fixture used instead of test/support fixtures when compiled outside :test.",
          "summary": "Defines a minimal, real Ash.Resource fixture private to the AshA2A.ArchitectureVerifier checks."
        },
        {
          "code_purpose": "model",
          "dependencies": [
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "Spark.Dsl.Entity",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "Exists as a structural prerequisite so the :skill entity can declare `entities: [@argument]` and accept nested do...end blocks. Field population and validation against the real Ash action's arguments is deliberately not performed here.",
          "file_path": "/Users/sac/ash_a2a/lib/ash_a2a/argument.ex",
          "importance_score": 0.5,
          "interfaces": [],
          "name": "argument.ex",
          "responsibilities": [
            "Declare the DSL argument entity structure",
            "Allow skill entities to accept nested argument blocks",
            "Preserve source compatibility with older declarations"
          ],
          "source_summary": "Defines the @argument Spark.Dsl.Entity struct. The moduledoc states it remains accepted for source compatibility with pre-v26.9.12 declarations and that actual validation of declared arguments happens elsewhere.",
          "summary": "Spark DSL entity target for the nested `argument` block inside `a2a do skill ... end` declarations."
        },
        {
          "code_purpose": "model",
          "dependencies": [
            {
              "dependency_type": "alias",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.Identity",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "A typed evidence record, not a bearer-token verifier; it never manufactures trust. It is constructed only after a transport or host authority broker has admitted the caller, with :transport_verified used for identities already checked by A2A.Plug.Auth.",
          "file_path": "/Users/sac/ash_a2a/lib/ash_a2a/authority.ex",
          "importance_score": 0.6,
          "interfaces": [],
          "name": "authority.ex",
          "responsibilities": [
            "Represent verified authority evidence per capability",
            "Bind principal identity to capability grants",
            "Prevent trust manufacturing at construction sites"
          ],
          "source_summary": "Defines an @enforce_keys struct with token_id, subject, capability_id, source, and issued_at fields, aliasing AshA2A.Identity for the principal subject type.",
          "summary": "Struct binding explicit authority evidence to a principal and a single capability."
        },
        {
          "code_purpose": "module",
          "dependencies": [
            {
              "dependency_type": "alias",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.CapabilityIndex.Compiler",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "alias",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.Info",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "alias",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.Skill",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "alias",
              "is_external": true,
              "line_number": null,
              "name": "Ash.Resource.Info",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "Keeps wire projection and residual-override validation separate while ensuring the capability index is never authored or persisted as a second business model. Derivation always flows through AshA2A.Info and the CapabilityIndex.Compiler from Ash.Resource.Info.public_actions/1.",
          "file_path": "/Users/sac/ash_a2a/lib/ash_a2a/capability_index.ex",
          "importance_score": 0.85,
          "interfaces": [
            {
              "description": null,
              "interface_type": "function",
              "name": "build",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "resource_or_domain",
                  "param_type": "module()"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "opts",
                  "param_type": "keyword()"
                }
              ],
              "return_type": "{:ok, [AshA2A.Skill.t()]} | {:error, [refusal()]}",
              "visibility": ""
            }
          ],
          "name": "capability_index.ex",
          "responsibilities": [
            "Expose the derived capability index to callers",
            "Separate wire projection from override validation",
            "Guarantee capabilities come only from Ash introspection"
          ],
          "source_summary": "Declares skill and refusal types (@type skill :: AshA2A.Skill.t(), @type refusal map) and exposes builder functions that project public Ash actions into A2A skills, delegating derivation to AshA2A.CapabilityIndex.Compiler.",
          "summary": "Public facade for the derived Ash-to-A2A capability projection."
        },
        {
          "code_purpose": "model",
          "dependencies": [
            {
              "dependency_type": "alias",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.Identity",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "alias",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.Authority",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "alias",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.SemanticSubject",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "Binds distinct machine identities, a canonical capability id, the admitted input, and optional semantic subject and verified authority into one envelope. Its fingerprint is derived only from semantic command content so retries with fresh transport timestamps still prove the same intent against the same manufactured subject.",
          "file_path": "/Users/sac/ash_a2a/lib/ash_a2a/command.ex",
          "importance_score": 0.8,
          "interfaces": [],
          "name": "command.ex",
          "responsibilities": [
            "Encapsulate one consequence-bearing command intent",
            "Carry distinct machine identities and capability id",
            "Provide semantic fingerprint for idempotent retries",
            "Attach optional semantic subject and authority evidence"
          ],
          "source_summary": "Defines the AshA2A.Command struct with enforced keys covering identity references, capability id, input, semantic subject, authority, and a semantically derived fingerprint used for replay detection downstream.",
          "summary": "Consequence-bearing command envelope struct for the AshA2A boundary."
        },
        {
          "code_purpose": "service",
          "dependencies": [
            {
              "dependency_type": "alias",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.Command",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "alias",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.Authority",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "alias",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.Identity",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "alias",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.Receipt",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "alias",
              "is_external": true,
              "line_number": null,
              "name": "A2A.Message",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "Planning components and provider adapters may call this module but cannot bypass its capability, identity, replay, or evidence checks. It is the single sanctioned path from an admitted command to command execution and receipt production.",
          "file_path": "/Users/sac/ash_a2a/lib/ash_a2a/command_bus.ex",
          "importance_score": 0.9,
          "interfaces": [
            {
              "description": null,
              "interface_type": "function",
              "name": "run",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "command",
                  "param_type": "AshA2A.Command.t()"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "message",
                  "param_type": "A2A.Message.t()"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "receipt_store",
                  "param_type": "module()"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "opts",
                  "param_type": "keyword()"
                }
              ],
              "return_type": "{:ok, AshA2A.Receipt.t()} | {:error, map()}",
              "visibility": ""
            }
          ],
          "name": "command_bus.ex",
          "responsibilities": [
            "Route admitted commands to the Ash dispatcher",
            "Enforce capability, identity, and replay checks",
            "Claim command ids atomically via the receipt store",
            "Produce receipts for every command attempt"
          ],
          "source_summary": "Exposes run/4 accepting an AshA2A.Command, the originating A2A.Message, a receipt store module, and options, returning {:ok, Receipt.t()} or {:error, map()}; aliases Authority, Command, Identity, and Receipt to perform checks before dispatch.",
          "summary": "Canonical receipted route from an admitted Command to the Ash dispatcher."
        },
        {
          "code_purpose": "middleware",
          "dependencies": [
            {
              "dependency_type": "alias",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.ExecutionContext",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "alias",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.Skill",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "alias",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.MetadataKey",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "alias",
              "is_external": true,
              "line_number": null,
              "name": "A2A.Message",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "This is the trust boundary named in the ash_a2a PRD/ARD §3.5: raw A2A message metadata must never be passed directly into Ash calls. Every dispatch path goes through from_a2a_message first, which extracts exactly the fields Ash actions accept (actor, tenant, etc.).",
          "file_path": "/Users/sac/ash_a2a/lib/ash_a2a/context_resolver.ex",
          "importance_score": 0.85,
          "interfaces": [
            {
              "description": null,
              "interface_type": "function",
              "name": "from_a2a_message",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "message",
                  "param_type": "A2A.Message.t()"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "skill",
                  "param_type": "AshA2A.Skill.t()"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "resource_or_domain",
                  "param_type": "module()"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "opts",
                  "param_type": "keyword()"
                }
              ],
              "return_type": "{:ok, AshA2A.ExecutionContext.t()} | {:error, map()}",
              "visibility": ""
            }
          ],
          "name": "context_resolver.ex",
          "responsibilities": [
            "Filter raw A2A metadata to Ash-accepted fields",
            "Resolve actor and tenant into an execution context",
            "Serve as the mandatory trust boundary for all dispatch paths"
          ],
          "source_summary": "Implements from_a2a_message/4 (and helpers) that read only allowlisted fields from message metadata, validate them, and construct an ExecutionContext via AshA2A.ExecutionContext, refusing raw passthrough.",
          "summary": "Trust-boundary resolver that converts an inbound A2A.Message into a validated AshA2A.ExecutionContext."
        },
        {
          "code_purpose": "model",
          "dependencies": [
            {
              "dependency_type": "alias",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.Command",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "alias",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.Identity",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "A delivery is explicitly not an execution receipt, and provider ids are not A2A task ids. It records that handoff occurred without asserting any consequence or completion.",
          "file_path": "/Users/sac/ash_a2a/lib/ash_a2a/delivery.ex",
          "importance_score": 0.55,
          "interfaces": [],
          "name": "delivery.ex",
          "responsibilities": [
            "Record async delivery handoff to providers",
            "Keep delivery identity distinct from receipts and task ids",
            "Carry provider references and status metadata"
          ],
          "source_summary": "Defines an @enforce_keys struct with delivery_id, command_id, provider, status, and recorded_at, plus optional task_id, provider_ref, and metadata, aliasing Command and Identity.",
          "summary": "Provider-neutral observation that a command was handed to an async delivery substrate."
        },
        {
          "code_purpose": "service",
          "dependencies": [
            {
              "dependency_type": "alias",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.Info",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "alias",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.ContextResolver",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "alias",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.CommandBus",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "alias",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.MetadataKey",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "alias",
              "is_external": true,
              "line_number": null,
              "name": "A2A.Message",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "import",
              "is_external": true,
              "line_number": null,
              "name": "Ash",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "Per the ash_a2a PRD/ARD §3.2 and §3.5, skills are looked up in the persisted, verified capability index via AshA2A.Info, never by walking raw DSL entities, so dispatch can never diverge from the advertised AgentCard. It resolves the execution context through ContextResolver before invoking Ash actions.",
          "file_path": "/Users/sac/ash_a2a/lib/ash_a2a/dispatcher.ex",
          "importance_score": 0.95,
          "interfaces": [
            {
              "description": null,
              "interface_type": "function",
              "name": "dispatch",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "message",
                  "param_type": "A2A.Message.t()"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "resource_or_domain",
                  "param_type": "module()"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "skill_id",
                  "param_type": "String.t()"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "receipt_store",
                  "param_type": "module()"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "opts",
                  "param_type": "keyword()"
                }
              ],
              "return_type": "{:ok, term()} | {:error, map()}",
              "visibility": ""
            }
          ],
          "name": "dispatcher.ex",
          "responsibilities": [
            "Resolve skills from the persisted verified capability index",
            "Cross the trust boundary via ContextResolver",
            "Invoke the canonical Ash action for the skill",
            "Return A2A.Agent-compatible reply tuples",
            "Keep dispatch aligned with the advertised AgentCard"
          ],
          "source_summary": "Implements dispatch/5: it resolves the skill from the capability index, builds an ExecutionContext via ContextResolver, invokes the mapped Ash action (create/read/action), and shapes the result into an A2A.Agent reply tuple, mapping errors to A2A-compatible responses.",
          "summary": "Core engine that dispatches an inbound A2A.Message to the real Ash action mapped by a persisted skill and returns an A2A.Agent reply tuple."
        },
        {
          "code_purpose": "plugin",
          "dependencies": [
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "Spark.Dsl",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "alias",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.Skill",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "alias",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.Argument",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "Public Ash actions require no skill declaration; the skill entity is an optional override locator for A2A-only metadata such as display name, description, tags, or exclusion. It cannot manufacture a capability: the referenced action must already exist and be public in Ash.",
          "file_path": "/Users/sac/ash_a2a/lib/ash_a2a/dsl.ex",
          "importance_score": 0.85,
          "interfaces": [
            {
              "description": null,
              "interface_type": "dsl_section",
              "name": "a2a (DSL section)",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "skill",
                  "param_type": "entity"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "argument",
                  "param_type": "entity"
                }
              ],
              "return_type": "Spark.Dsl.Section.t()",
              "visibility": ""
            }
          ],
          "name": "dsl.ex",
          "responsibilities": [
            "Define the AshA2A Spark DSL schema",
            "Accept residual override skill declarations",
            "Reject capability manufacturing via DSL",
            "Maintain backwards-compatible argument syntax"
          ],
          "source_summary": "Defines the `a2a` DSL section with a nested `skill` entity and, for backwards source compatibility with pre-v26.9.12 declarations, a deliberately inert nested `argument` entity.",
          "summary": "Spark DSL extension section declaring residual A2A projection configuration with optional skill entities."
        },
        {
          "code_purpose": "model",
          "dependencies": [
            {
              "dependency_type": "alias",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.ContextResolver",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "Built exclusively by AshA2A.ContextResolver.from_a2a_message, never constructed directly from raw A2A.Message metadata at call sites (PRD/ARD §3.5). Its field shape mirrors the opts AshAi.Tool.Execution.build_opts/2 feeds into Ash changeset/query/action-input constructors.",
          "file_path": "/Users/sac/ash_a2a/lib/ash_a2a/execution_context.ex",
          "importance_score": 0.7,
          "interfaces": [],
          "name": "execution_context.ex",
          "responsibilities": [
            "Represent validated dispatch execution context",
            "Mirror Ash call opts shape (actor, tenant)",
            "Guarantee construction only via ContextResolver"
          ],
          "source_summary": "Defines an @enforce_keys struct holding actor, tenant, and related Ash call opts so downstream Ash invocations receive exactly validated fields produced by the ContextResolver.",
          "summary": "Struct for the resolved, trust-boundary-crossed execution context of a single A2A skill dispatch."
        },
        {
          "code_purpose": "model",
          "dependencies": [],
          "detailed_description": "Kinds such as principal, agent, task, and command are distinct: a task id is not an agent id and none imply a principal. The tagged value is small enough to pass through A2A metadata, Reactor context, Oban arguments, topology providers, and receipts without creating a second identity system.",
          "file_path": "/Users/sac/ash_a2a/lib/ash_a2a/identity.ex",
          "importance_score": 0.65,
          "interfaces": [
            {
              "description": null,
              "interface_type": "function",
              "name": "new",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "kind",
                  "param_type": "atom()"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "value",
                  "param_type": "String.t()"
                }
              ],
              "return_type": "t()",
              "visibility": ""
            }
          ],
          "name": "identity.ex",
          "responsibilities": [
            "Model distinct machine identity kinds",
            "Provide a portable tagged identity value",
            "Prevent cross-kind identity confusion"
          ],
          "source_summary": "Declares @kinds [:principal, :agent, :task, :command, ...] and constructors/accessors for building and inspecting tagged identities used across commands, receipts, and deliveries.",
          "summary": "Typed machine identity tagged value for the A2A execution boundary with deliberately non-interchangeable kinds."
        },
        {
          "code_purpose": "module",
          "dependencies": [
            {
              "dependency_type": "alias",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.CapabilityIndex.Compiler",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "alias",
              "is_external": true,
              "line_number": null,
              "name": "Spark.Dsl.Extension",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "alias",
              "is_external": true,
              "line_number": null,
              "name": "Ash.Resource.Info",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "Since v26.9.12 Ash is the canonical capability source: the extension persists only residual A2A overrides plus a resource-vs-domain flag, and every capability_index* call derives the current index through AshA2A.CapabilityIndex.Compiler from Ash.Resource.Info.public_actions/1.",
          "file_path": "/Users/sac/ash_a2a/lib/ash_a2a/info.ex",
          "importance_score": 0.85,
          "interfaces": [
            {
              "description": null,
              "interface_type": "function",
              "name": "capability_index",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "dsl_or_resource",
                  "param_type": "Spark.Dsl.t() | module()"
                }
              ],
              "return_type": "{:ok, [AshA2A.Skill.t()]} | {:error, :not_compiled}",
              "visibility": ""
            }
          ],
          "name": "info.ex",
          "responsibilities": [
            "Expose extension introspection functions",
            "Derive capability indexes from public Ash actions",
            "Report not_compiled states fail-closed",
            "Preserve only residual overrides in persisted DSL state"
          ],
          "source_summary": "Exposes capability_index functions for resources and domains, delegating to CapabilityIndex.Compiler, and defines a not_compiled error type for use before the extension's persisted state exists.",
          "summary": "Introspection API for the AshA2A extension, deriving capability indexes from public Ash actions."
        },
        {
          "code_purpose": "config",
          "dependencies": [
            {
              "dependency_type": "alias",
              "is_external": true,
              "line_number": null,
              "name": "req_llm",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "Ash actions declare abstract roles (e.g. :semantic_reasoner), and `config :ash_a2a, :llm_profiles` maps those roles to concrete req_llm/ash_ai model specs and call options. This seals capability semantics from provider identity: A2ACapabilityIdentity != ModelProviderIdentity, so switching providers is purely a config change.",
          "file_path": "/Users/sac/ash_a2a/lib/ash_a2a/llm_profiles.ex",
          "importance_score": 0.6,
          "interfaces": [
            {
              "description": null,
              "interface_type": "function",
              "name": "resolve",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "role",
                  "param_type": "atom()"
                }
              ],
              "return_type": "{:ok, map()} | {:error, :unknown_role}",
              "visibility": ""
            }
          ],
          "name": "llm_profiles.ex",
          "responsibilities": [
            "Resolve abstract LLM roles to provider specs",
            "Keep capability semantics independent of providers",
            "Validate configured llm_profiles entries"
          ],
          "source_summary": "Implements lookup and validation of configured LLM profiles by role, resolving role atoms to provider/model strings plus call options for use by semantic capabilities.",
          "summary": "Role-based LLM provider resolution mapping abstract action roles to concrete model specs at runtime."
        },
        {
          "code_purpose": "util",
          "dependencies": [],
          "detailed_description": "Consolidates the atom-or-string lookup pattern previously hand-rolled with three different orderings across AshA2A.ContextResolver, AshA2A.Agent, and AshA2A.Dispatcher, giving one consistent, tested implementation.",
          "file_path": "/Users/sac/ash_a2a/lib/ash_a2a/metadata_key.ex",
          "importance_score": 0.45,
          "interfaces": [
            {
              "description": null,
              "interface_type": "function",
              "name": "fetch",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "map",
                  "param_type": "map()"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "key",
                  "param_type": "atom()"
                }
              ],
              "return_type": "{:ok, term()} | :error",
              "visibility": ""
            }
          ],
          "name": "metadata_key.ex",
          "responsibilities": [
            "Provide consistent atom/string key lookup",
            "Deduplicate lookup logic across modules"
          ],
          "source_summary": "Provides a fetch function that tries Atom.to_string conversion: it fetches the atom key first and falls back to the key's string form, returning :error when neither is present.",
          "summary": "Shared helper for atom-key map lookup with string-key fallback."
        },
        {
          "code_purpose": "model",
          "dependencies": [],
          "detailed_description": "A planning candidate references capabilities but carries standing: :candidate and authority: :none, so plans can never execute anything directly. Admitted skills are listed separately for downstream admission checks.",
          "file_path": "/Users/sac/ash_a2a/lib/ash_a2a/planning.ex",
          "importance_score": 0.5,
          "interfaces": [
            {
              "description": null,
              "interface_type": "function",
              "name": "new",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "planner",
                  "param_type": "atom()"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "plan",
                  "param_type": "map()"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "capability_ids",
                  "param_type": "list(String.t())"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "opts",
                  "param_type": "keyword()"
                }
              ],
              "return_type": "t()",
              "visibility": ""
            }
          ],
          "name": "planning.ex",
          "responsibilities": [
            "Represent planner output as candidates only",
            "Carry plan fingerprint for traceability",
            "Explicitly deny authority to plans"
          ],
          "source_summary": "Defines an @enforce_keys struct with planner, plan, capability_ids, and fingerprint, plus defaults for standing, authority, and admitted_skills, and a new/4 constructor.",
          "summary": "Defines the planner output Candidate struct with candidate-only standing and no execution authority."
        },
        {
          "code_purpose": "model",
          "dependencies": [
            {
              "dependency_type": "alias",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.Command",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "alias",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.Identity",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "Receipt identity is distinct from command, task, agent, semantic subject, and execution identity. It records what was attempted and the observed reply shape, inferring success only from the returned outcome; its :standing field is evidence about the store's durability, not the command.",
          "file_path": "/Users/sac/ash_a2a/lib/ash_a2a/receipt.ex",
          "importance_score": 0.75,
          "interfaces": [],
          "name": "receipt.ex",
          "responsibilities": [
            "Record evidence of each command attempt",
            "Track durable persistence standing",
            "Support same-fingerprint replay detection",
            "Keep receipt identity separate from other identities"
          ],
          "source_summary": "Defines the AshA2A.Receipt struct with a t:standing/0 type capturing persistence durability tiers, plus fields describing the attempt, fingerprint, and observed reply shape.",
          "summary": "Struct for replayable evidence of one AshA2A command attempt."
        },
        {
          "code_purpose": "module",
          "dependencies": [
            {
              "dependency_type": "alias",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.Command",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "alias",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.Receipt",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "Implementations own the atomic command-id claim and must distinguish same-id/same-fingerprint replay from same-id/different-fingerprint conflict. This contract underpins idempotent command execution across the system.",
          "file_path": "/Users/sac/ash_a2a/lib/ash_a2a/receipt_store.ex",
          "importance_score": 0.75,
          "interfaces": [
            {
              "description": null,
              "interface_type": "callback",
              "name": "claim",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "command",
                  "param_type": "AshA2A.Command.t()"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "opts",
                  "param_type": "keyword()"
                }
              ],
              "return_type": "{:execute, AshA2A.Identity.t()} | {:replay, AshA2A.Receipt.t()} | {:error, :command_conflict | :in_flight}",
              "visibility": ""
            }
          ],
          "name": "receipt_store.ex",
          "responsibilities": [
            "Define the receipt storage behaviour contract",
            "Specify atomic command-id claim semantics",
            "Distinguish replay from command conflict",
            "Allow swappable store implementations"
          ],
          "source_summary": "Defines the claim_result type ({:execute, Identity.t()} | {:replay, Receipt.t()} | {:error, :command_conflict | :in_flight}) and the claim/2 callback plus related storage callbacks for persisting receipts.",
          "summary": "Behaviour for replay-safe command receipt storage with atomic command-id claims."
        },
        {
          "code_purpose": "model",
          "dependencies": [
            {
              "dependency_type": "alias",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.Identity",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "Runtime receipts deliberately carry only observed provider standing; they do not confer Ash domain standing, A2A task completion, command execution, or authority. This keeps provider-level evidence from being over-interpreted downstream.",
          "file_path": "/Users/sac/ash_a2a/lib/ash_a2a/runtime_receipt.ex",
          "importance_score": 0.55,
          "interfaces": [],
          "name": "runtime_receipt.ex",
          "responsibilities": [
            "Record provider operation evidence",
            "Restrict receipts to observed provider standing",
            "Prevent standing escalation to domain or task level"
          ],
          "source_summary": "Defines an @enforce_keys struct with receipt_id, provider, operation, subject, status, and recorded_at, plus optional reply shape and metadata, aliasing AshA2A.Identity for subjects.",
          "summary": "Evidence struct for consequence-bearing runtime/provider operations."
        },
        {
          "code_purpose": "service",
          "dependencies": [
            {
              "dependency_type": "alias",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.Identity",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "alias",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.Receipt",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "alias",
              "is_external": true,
              "line_number": null,
              "name": "ash_r2rml",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "Projects committed receipts and canonical capabilities into machine-readable evidence and, when ash_r2rml is available, joins capabilities to that package's public mapping_result/1 inspection surface. It never executes SPARQL, mutates RDF, or grants command authority.",
          "file_path": "/Users/sac/ash_a2a/lib/ash_a2a/semantic_projection.ex",
          "importance_score": 0.6,
          "interfaces": [
            {
              "description": null,
              "interface_type": "function",
              "name": "receipt_projection",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "receipt",
                  "param_type": "AshA2A.Receipt.t()"
                }
              ],
              "return_type": "map()",
              "visibility": ""
            }
          ],
          "name": "semantic_projection.ex",
          "responsibilities": [
            "Project committed receipts into machine-readable evidence",
            "Project canonical capabilities deterministically",
            "Optionally join ash_r2rml mapping inspection",
            "Remain read-only with no authority effects"
          ],
          "source_summary": "Provides receipt and capability projection functions with @specs referencing Identity and Receipt, emitting deterministic projections suitable for downstream semantic tooling.",
          "summary": "Read-only, deterministic semantic/process projection of canonical AshA2A evidence."
        },
        {
          "code_purpose": "model",
          "dependencies": [],
          "detailed_description": "Grants no capability and no authority. A command may carry the subject so retries and replay are scoped to the exact semantic graph and generated projection that produced the capability surface in use.",
          "file_path": "/Users/sac/ash_a2a/lib/ash_a2a/semantic_subject.ex",
          "importance_score": 0.5,
          "interfaces": [],
          "name": "semantic_subject.ex",
          "responsibilities": [
            "Bind semantic graph and projection digests to commands",
            "Scope retries to exact semantic provenance",
            "Remain evidence-only with no authority"
          ],
          "source_summary": "Defines an @enforce_keys struct with graph_digest, projection_digest, and manufacturer_digest fields capturing content digests of the semantic graph, its projection, and manufacturer.",
          "summary": "Struct binding exact semantic/manufacture identity to an A2A command as evidence only."
        },
        {
          "code_purpose": "model",
          "dependencies": [
            {
              "dependency_type": "alias",
              "is_external": true,
              "line_number": null,
              "name": "Ash.Resource",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "Not a second action model: its {resource, action} pair points back to the canonical Ash.Resource action, while id, name, description, and tags are A2A projection data. The same struct is also the target of the optional `a2a do skill ... end` residual-override DSL for backwards compatibility.",
          "file_path": "/Users/sac/ash_a2a/lib/ash_a2a/skill.ex",
          "importance_score": 0.7,
          "interfaces": [],
          "name": "skill.ex",
          "responsibilities": [
            "Reference canonical Ash actions for A2A exposure",
            "Carry A2A projection metadata",
            "Serve as the residual-override DSL entity target"
          ],
          "source_summary": "Defines the AshA2A.Skill struct with identification fields (id, resource, action), projection metadata (name, description, tags), and optional legacy fields such as arguments and Spark metadata.",
          "summary": "Struct representing one public Ash action exposed through A2A."
        },
        {
          "code_purpose": "module",
          "dependencies": [
            {
              "dependency_type": "alias",
              "is_external": true,
              "line_number": null,
              "name": "AshStateMachine",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "The A2A task vocabulary is declared here for interoperability, but transition legality comes from AshStateMachine.possible_next_states/1,2 when that extension is installed. This module never performs a transition itself.",
          "file_path": "/Users/sac/ash_a2a/lib/ash_a2a/task_lifecycle.ex",
          "importance_score": 0.55,
          "interfaces": [
            {
              "description": null,
              "interface_type": "function",
              "name": "states",
              "parameters": [],
              "return_type": "list(atom())",
              "visibility": ""
            },
            {
              "description": null,
              "interface_type": "function",
              "name": "possible_next_states",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "task",
                  "param_type": "struct()"
                }
              ],
              "return_type": "list(atom())",
              "visibility": ""
            }
          ],
          "name": "task_lifecycle.ex",
          "responsibilities": [
            "Declare the canonical A2A task state set",
            "Validate transitions via AshStateMachine",
            "Delegate transition legality to host state machines"
          ],
          "source_summary": "Declares @states [:submitted, :working, :input_required, :auth_required, :completed, :failed, :canceled, :rejected] and exposes specs for listing states and validating legal next states via AshStateMachine.",
          "summary": "Adapter over host-owned AshStateMachine task truth declaring the canonical A2A task state vocabulary."
        },
        {
          "code_purpose": "plugin",
          "dependencies": [
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "Spark.Dsl.Verifier",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "alias",
              "is_external": true,
              "line_number": null,
              "name": "Ash.Resource.Info",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "It does not validate a hand-authored capability model; it checks only that each optional override points at a real public Ash action, since the actual capability set is always derived from Ash introspection.",
          "file_path": "/Users/sac/ash_a2a/lib/ash_a2a/verify.ex",
          "importance_score": 0.7,
          "interfaces": [
            {
              "description": null,
              "interface_type": "function",
              "name": "verify",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "dsl",
                  "param_type": "Spark.Dsl.t()"
                }
              ],
              "return_type": ":ok | {:error, Spark.Error.DslError.t()}",
              "visibility": ""
            }
          ],
          "name": "verify.ex",
          "responsibilities": [
            "Verify override skill targets exist and are public",
            "Fail closed on invalid residual overrides",
            "Keep capability truth with Ash introspection"
          ],
          "source_summary": "Uses Spark.Dsl.Verifier and implements verify/1, reading persisted :ash_a2a_skill_overrides and erroring when an override references an action that does not exist or is not public.",
          "summary": "Fail-closed Spark DSL verifier for residual A2A projection overrides."
        }
      ],
      "importance_score": 0.96,
      "key_files": [
        "dispatcher.ex",
        "command_bus.ex",
        "dsl.ex",
        "info.ex",
        "capability_index.ex"
      ],
      "name": "ash_a2a",
      "path": "/Users/sac/ash_a2a/lib/ash_a2a",
      "purpose": "other",
      "subdirectory_count": 12,
      "summary": "This is the core source directory of the ash_a2a Elixir package, which exposes Ash Framework resources and domains as A2A (Agent-to-Agent) protocol agents. It defines the Spark DSL extension for residual A2A overrides (dsl.ex, argument.ex, verify.ex), derives the capability index from public Ash actions (info.ex, capability_index.ex, skill.ex), and routes inbound A2A messages through a trust boundary (context_resolver.ex, execution_context.ex) into real Ash actions via a receipted command bus (command.ex, command_bus.ex, dispatcher.ex, receipt.ex, receipt_store.ex). Supporting structs and helpers model identity, authority, delivery, planning, LLM profiles, semantic projection, and task lifecycle, giving the package a complete, security-focused agent integration layer."
    },
    {
      "file_count": 3,
      "file_insights": [
        {
          "code_purpose": "module",
          "dependencies": [
            {
              "dependency_type": "alias",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.Argument",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "alias",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.Skill",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "alias",
              "is_external": true,
              "line_number": null,
              "name": "Spark.Dsl.Extension",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "Ash.Resource.Info",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "This module acts as the central compiler of the capability index, taking an Ash resource or domain module and producing the canonical set of A2A skills. Its input set is strictly Ash.Resource.Info.public_actions/1, ensuring only genuinely public actions become agent capabilities. Optional 'a2a skill' declarations are treated as residual projection overrides keyed by the canonical {resource, action} identity, layered on top of the introspected base.",
          "file_path": "/Users/sac/ash_a2a/lib/ash_a2a/capability_index/compiler.ex",
          "importance_score": 0.92,
          "interfaces": [
            {
              "description": null,
              "interface_type": "function",
              "name": "compile",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "module",
                  "param_type": "module()"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "kind",
                  "param_type": ":resource | :domain"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "overrides",
                  "param_type": "[AshA2A.Skill.t()]"
                }
              ],
              "return_type": "[AshA2A.Skill.t()]",
              "visibility": ""
            }
          ],
          "name": "compiler.ex",
          "responsibilities": [
            "Introspect public Ash actions from resources or domains via Ash.Resource.Info.public_actions/1",
            "Map Ash actions and their arguments into A2A Skill and Argument structs",
            "Apply residual A2A skill overrides keyed by the canonical {resource, action} identity",
            "Ensure the compiler never fabricates business semantics beyond what Ash exposes"
          ],
          "source_summary": "Defines the AshA2A.CapabilityIndex.Compiler module with a compile/3 function accepting a module, a :resource or :domain kind, and a list of Skill overrides. It aliases AshA2A.Argument, AshA2A.Skill, and Spark.Dsl.Extension, introspects public Ash actions, and merges override declarations to produce the final skill list with argument definitions sourced from real Ash actions.",
          "summary": "Derives the A2A capability index (skills) from canonical Ash resource/domain introspection. It is the heart of the module, converting public Ash actions into A2A skill definitions without inventing business semantics."
        },
        {
          "code_purpose": "util",
          "dependencies": [
            {
              "dependency_type": "type_use",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.Skill",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "Ash.Resource.Info",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "This module acts as the safety gate for the capability pipeline, enforcing that override declarations in the A2A DSL cannot advertise capabilities that do not exist in Ash. It rejects any override referencing private actions or nonexistent {resource, action} pairs, returning structured refusal information with a code and detail. This fail-closed design protects the integrity of the agent's advertised surface.",
          "file_path": "/Users/sac/ash_a2a/lib/ash_a2a/capability_index/validator.ex",
          "importance_score": 0.82,
          "interfaces": [
            {
              "description": null,
              "interface_type": "function",
              "name": "validate",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "skills",
                  "param_type": "[AshA2A.Skill.t() | map()]"
                }
              ],
              "return_type": "{:ok, [AshA2A.Skill.t()]} | {:error, [%{code: atom(), detail: String.t()}]}",
              "visibility": ""
            }
          ],
          "name": "validator.ex",
          "responsibilities": [
            "Validate that every {resource, action} override pair references a real public Ash action",
            "Reject overrides that attempt to create capabilities that do not exist",
            "Keep private Ash actions internal even when explicitly named in the A2A DSL",
            "Return structured refusal information (code and detail) for invalid overrides"
          ],
          "source_summary": "Defines the AshA2A.CapabilityIndex.Validator module with a type for skills (either AshA2A.Skill.t() or a map) and a refusal type of %{code: atom(), detail: String.t()}. Its validate/1 function checks each override against real public Ash actions and produces either a validated result or refusal entries, keeping private actions internal even when explicitly named in the DSL.",
          "summary": "Performs fail-closed validation of residual A2A skill overrides, guaranteeing that every {resource, action} pair names a real, public Ash action. Overrides may describe or suppress existing capabilities but can never create new ones."
        },
        {
          "code_purpose": "util",
          "dependencies": [
            {
              "dependency_type": "type_use",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.Skill",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "A2A.AgentCard",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "use",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.CapabilityIndex.Compiler",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "This module is the final projection layer of the capability pipeline, converting validated skills into the A2A protocol's AgentCard format used for agent discovery. It guarantees deterministic output so the same capability index always yields the same card, and argument schemas are always introspected from the real Ash actions rather than trusted from declarations. It depends on the compiler's canonical skill identity as its input contract.",
          "file_path": "/Users/sac/ash_a2a/lib/ash_a2a/capability_index/agent_card_builder.ex",
          "importance_score": 0.85,
          "interfaces": [
            {
              "description": null,
              "interface_type": "function",
              "name": "build_agent_card",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "skills",
                  "param_type": "[AshA2A.Skill.t()]"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "opts",
                  "param_type": "keyword()"
                }
              ],
              "return_type": "A2A.AgentCard.t()",
              "visibility": ""
            }
          ],
          "name": "agent_card_builder.ex",
          "responsibilities": [
            "Project the compiled capability index into an A2A.AgentCard.t() struct",
            "Use canonical {resource, action} identities from the Compiler as skill ids",
            "Apply residual A2A overrides for names, descriptions, and tags only",
            "Introspect argument schemas from real Ash actions for deterministic output"
          ],
          "source_summary": "Defines the AshA2A.CapabilityIndex.AgentCardBuilder module with a skill type alias and a build_agent_card/2 function that accepts a list of AshA2A.Skill.t() structs and keyword options, returning an A2A.AgentCard.t(). It maps skill ids from the canonical {resource, action} identity produced by the Compiler, applies residual overrides for names/descriptions/tags, and projects introspected arguments into the card's skill definitions.",
          "summary": "Deterministically projects a compiled capability index into an A2A AgentCard struct, the discovery document consumed by A2A clients. Skill identities come from the compiler's canonical {resource, action} pairs while names, descriptions, and tags may carry residual A2A overrides."
        }
      ],
      "importance_score": 0.88,
      "key_files": [
        "compiler.ex",
        "validator.ex",
        "agent_card_builder.ex"
      ],
      "name": "capability_index",
      "path": "/Users/sac/ash_a2a/lib/ash_a2a/capability_index",
      "purpose": "other",
      "subdirectory_count": 0,
      "summary": "The capability_index directory is the core derivation engine of the AshA2A library, responsible for translating Ash framework resource introspection into the A2A (Agent-to-Agent) protocol's capability surface. The compiler derives skills from public Ash actions, the validator enforces fail-closed semantics so overrides can only describe or suppress existing capabilities, and the agent card builder deterministically projects the compiled index into an A2A AgentCard. Together these files form the canonical pipeline that guarantees the advertised agent capabilities always reflect real Ash actions."
    },
    {
      "file_count": 1,
      "file_insights": [
        {
          "code_purpose": "plugin",
          "dependencies": [
            {
              "dependency_type": "import",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.Authority",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "import",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.Command",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "import",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.Delivery",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "import",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.Identity",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "Oban",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "Code (Elixir stdlib)",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "This file implements the Oban-based delivery adapter for the AshA2A framework, allowing delivery of A2A tasks to be handled asynchronously through the Oban job queue. It acts as an optional integration layer: when Oban is available it can be used as the delivery backend, and it establishes the contract that downstream Oban workers must rebuild an admitted command and invoke the CommandBus rather than treating job metadata as A2A protocol state.",
          "file_path": "/Users/sac/ash_a2a/lib/ash_a2a/delivery/oban.ex",
          "importance_score": 0.6,
          "interfaces": [
            {
              "description": null,
              "interface_type": "function",
              "name": "available?",
              "parameters": [],
              "return_type": "boolean()",
              "visibility": ""
            }
          ],
          "name": "oban.ex",
          "responsibilities": [
            "Provide an optional Oban-based backend for the AshA2A delivery mechanism",
            "Record delivery by inserting jobs into the Oban queue",
            "Detect at runtime whether Oban is available via available?/0",
            "Enforce that Oban job ids are never promoted to A2A TaskIDs or execution receipts",
            "Delegate actual execution to workers that reconstruct admitted commands and call AshA2A.CommandBus"
          ],
          "source_summary": "Defines the AshA2A.Delivery.Oban module, documented as an optional Oban delivery adapter. It aliases core AshA2A modules (Authority, Command, Delivery, Identity) and exposes an available?/0 function that checks whether Oban (and a related Oban module) are loadable at runtime, gating use of this adapter on the presence of the Oban dependency.",
          "summary": "Optional Oban delivery adapter for AshA2A that decouples delivery recording from actual command execution via background job processing."
        }
      ],
      "importance_score": 0.6,
      "key_files": [
        "oban.ex"
      ],
      "name": "delivery",
      "path": "/Users/sac/ash_a2a/lib/ash_a2a/delivery",
      "purpose": "other",
      "subdirectory_count": 0,
      "summary": "The delivery directory holds the optional Oban-backed delivery adapter for the AshA2A A2A protocol implementation. Its single file, oban.ex, bridges the framework's delivery mechanism with the Oban background job queue, enforcing the invariant that queue insertion only records delivery and that Oban job ids are never promoted to A2A TaskIDs or execution receipts; workers must instead reconstruct an admitted command and dispatch it through AshA2A.CommandBus."
    },
    {
      "file_count": 1,
      "file_insights": [
        {
          "code_purpose": "module",
          "dependencies": [
            {
              "dependency_type": "use",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.RuntimeReceipt",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "import",
              "is_external": true,
              "line_number": null,
              "name": "DurableServer",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "import",
              "is_external": true,
              "line_number": null,
              "name": "DurableServer.Supervisor",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "use",
              "is_external": false,
              "line_number": null,
              "name": ":ash_a2a application config",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "This file implements the integration point between the AshA2A runtime and Phoenix's DurableServer task runtime, enabling durable, restart-safe task execution. It explicitly separates the stable task identity (the A2A TaskID used as the DurableServer key) from provider-owned state such as PIDs, storage locks, and node placement. Mutating lifecycle operations deliberately return AshA2A.RuntimeReceipt, making it clear that durability actions neither execute Ash commands nor guarantee task completion.",
          "file_path": "/Users/sac/ash_a2a/lib/ash_a2a/durability/durable_server.ex",
          "importance_score": 0.6,
          "interfaces": [
            {
              "description": null,
              "interface_type": "function",
              "name": "task lifecycle operations",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "task_id",
                  "param_type": "A2A TaskID (used as DurableServer key)"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "opts",
                  "param_type": "keyword list"
                }
              ],
              "return_type": "AshA2A.RuntimeReceipt",
              "visibility": ""
            },
            {
              "description": null,
              "interface_type": "function",
              "name": "provider resolution",
              "parameters": [],
              "return_type": "DurableServer provider module (defaults to DurableServer.Supervisor)",
              "visibility": ""
            }
          ],
          "name": "durable_server.ex",
          "responsibilities": [
            "Adapt AshA2A task lifecycle operations to the Phoenix DurableServer runtime",
            "Map A2A TaskIDs to stable DurableServer keys for durable task identity",
            "Resolve the DurableServer provider from application config with DurableServer.Supervisor as the default",
            "Return AshA2A.RuntimeReceipt for mutating lifecycle operations without implying Ash command execution or task completion",
            "Keep provider-owned state (PID, storage locks, node placement) opaque to callers"
          ],
          "source_summary": "Defines the AshA2A.Durability.DurableServer module with a moduledoc describing its adapter role. It defaults the underlying provider to DurableServer.Supervisor and supports host-level override via the :ash_a2a, :durable_server_provider application configuration. Its API revolves around task lifecycle operations keyed by the A2A TaskID, all returning AshA2A.RuntimeReceipt values.",
          "summary": "Optional adapter module that bridges AshA2A task lifecycle operations to a Phoenix DurableServer runtime, using the A2A TaskID as the stable durable-server key."
        }
      ],
      "importance_score": 0.6,
      "key_files": [
        "durable_server.ex"
      ],
      "name": "durability",
      "path": "/Users/sac/ash_a2a/lib/ash_a2a/durability",
      "purpose": "other",
      "subdirectory_count": 0,
      "summary": "The durability directory provides an optional persistence/coordination layer for the AshA2A agent framework by adapting task lifecycle operations to Phoenix's DurableServer task runtime. Its single module maps A2A TaskIDs to stable durable-server keys so task state can survive process restarts, while keeping provider details (PID, storage locks, node placement) abstracted and returning AshA2A.RuntimeReceipt for mutating operations rather than implying command execution or task completion."
    },
    {
      "file_count": 1,
      "file_insights": [
        {
          "code_purpose": "plugin",
          "dependencies": [
            {
              "dependency_type": "import",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.Command",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "import",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.RuntimeReceipt",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "use",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.CommandBus",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "FLAME",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "This module integrates the FLAME elastic compute library with the AshA2A execution pipeline. It acts as an adapter layer: FLAME only chooses where a closure runs, while the remote closure re-enters AshA2A.CommandBus, ensuring security and consistency fences are enforced on every node. Placement itself is captured as an AshA2A.RuntimeReceipt for auditability.",
          "file_path": "/Users/sac/ash_a2a/lib/ash_a2a/execution/flame.ex",
          "importance_score": 0.65,
          "interfaces": [
            {
              "description": null,
              "interface_type": "function",
              "name": "available?",
              "parameters": [],
              "return_type": "boolean()",
              "visibility": ""
            },
            {
              "description": null,
              "interface_type": "function",
              "name": "place",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "command",
                  "param_type": "AshA2A.Command.t()"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "fun",
                  "param_type": "function()"
                }
              ],
              "return_type": "term()",
              "visibility": ""
            }
          ],
          "name": "flame.ex",
          "responsibilities": [
            "Check whether FLAME-based remote placement is available at runtime",
            "Place receipted AshA2A command closures onto remote FLAME nodes",
            "Ensure remote execution routes through AshA2A.CommandBus to preserve admission/replay/receipt semantics",
            "Represent placement operations as AshA2A.RuntimeReceipt records for auditability"
          ],
          "source_summary": "Defines the AshA2A.Execution.FLAME module with a moduledoc clarifying that FLAME placement adds no independent capability or dispatch semantics. It aliases AshA2A.Command and AshA2A.RuntimeReceipt, and exposes an availability check via @spec available?() :: boolean(), with placement functions that dispatch receipted commands through AshA2A.CommandBus on remote FLAME nodes.",
          "summary": "Optional FLAME placement adapter that runs receipted AshA2A commands on remote nodes without granting independent capability or dispatch authority. Remote closures call back into AshA2A.CommandBus so the same admission/replay/receipt fence applies everywhere."
        }
      ],
      "importance_score": 0.62,
      "key_files": [
        "flame.ex"
      ],
      "name": "execution",
      "path": "/Users/sac/ash_a2a/lib/ash_a2a/execution",
      "purpose": "other",
      "subdirectory_count": 0,
      "summary": "The 'execution' directory contains an optional FLAME (elastic distributed execution) placement adapter for the AshA2A backend project. Its single file, flame.ex, wraps remote closure placement so that commands dispatched onto other nodes still pass through AshA2A.CommandBus, preserving the same admission/replay/receipt guarantees, with placement events recorded as AshA2A.RuntimeReceipt entries. It is backend infrastructure glue rather than core business logic, since it is explicitly optional and delegates all authority to the existing command bus."
    },
    {
      "file_count": 1,
      "file_insights": [
        {
          "code_purpose": "specificfeature",
          "dependencies": [
            {
              "dependency_type": "import",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.Planning.Candidate",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "import",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.Info",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "import",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.CommandBus",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "This module provides the AI-assisted planning capability of the AshA2A framework: an LLM role generates proposed plans (HDDL/FOND artifacts) and canonical A2A capability identifiers for goals that fall outside known planning boundaries. Security is a first-class concern: the model's output never carries authority, every proposed capability is re-validated through AshA2A.Info, and any consequence-bearing action must be constructed as a command entering AshA2A.CommandBus.",
          "file_path": "/Users/sac/ash_a2a/lib/ash_a2a/planning/semantic_synthesis.ex",
          "importance_score": 0.75,
          "interfaces": [
            {
              "description": null,
              "interface_type": "function",
              "name": "synthesize",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "input",
                  "param_type": "planning goal/boundary input"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "opts",
                  "param_type": "keyword()"
                }
              ],
              "return_type": "{:ok, AshA2A.Planning.Candidate.t()} | {:error, term()}",
              "visibility": ""
            }
          ],
          "name": "semantic_synthesis.ex",
          "responsibilities": [
            "Synthesize semantic plans for UNKNOWN planning boundaries using a configured LLM role",
            "Propose HDDL/FOND planning artifacts and canonical A2A capability ids as AshA2A.Planning.Candidate results",
            "Enforce the security model by re-resolving LLM-proposed capabilities through AshA2A.Info",
            "Ensure consequence-bearing actions are constructed as commands routed through AshA2A.CommandBus rather than executed directly"
          ],
          "source_summary": "The file defines the AshA2A.Planning.SemanticSynthesis module, whose documentation establishes the synthesis workflow and its trust boundaries: the LLM proposes plans and capability ids, but results are constrained to the AshA2A.Planning.Candidate shape. The excerpt is truncated at the module boundary, so the visible content consists of the module header and its security-focused moduledoc describing candidate-only LLM output, capability re-resolution via AshA2A.Info, and command gating via AshA2A.CommandBus.",
          "summary": "Implements semantic plan synthesis for UNKNOWN boundaries by having a configured LLM role propose HDDL/FOND artifacts and A2A capability ids, which are returned only as untrusted planning candidates."
        }
      ],
      "importance_score": 0.74,
      "key_files": [
        "semantic_synthesis.ex"
      ],
      "name": "planning",
      "path": "/Users/sac/ash_a2a/lib/ash_a2a/planning",
      "purpose": "other",
      "subdirectory_count": 0,
      "summary": "The planning directory implements LLM-assisted semantic plan synthesis for the A2A agent framework, targeting UNKNOWN planning boundaries. Its single file, semantic_synthesis.ex, acts as the bridge between AI-generated HDDL/FOND planning artifacts and the system's security model: LLM proposals are reduced to untrusted AshA2A.Planning.Candidate structs, capabilities are re-resolved authoritatively via AshA2A.Info, and consequence-bearing actions must still pass through AshA2A.CommandBus."
    },
    {
      "file_count": 1,
      "file_insights": [
        {
          "code_purpose": "specificfeature",
          "dependencies": [
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "Reactor.Step",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "use",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.CommandBus",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "require",
              "is_external": true,
              "line_number": null,
              "name": "Map",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "This file defines AshA2A.Reactor.ExecuteCommand, a step adapter implementing the Reactor.Step behavior. It serves as the bridge between Reactor workflow orchestration and the AshA2A command boundary, allowing A2A command handling to be embedded in larger reactive workflows. The module explicitly enforces the architectural rule that Reactor steps coordinate but never bypass the CommandBus or call AshA2A.Dispatcher directly.",
          "file_path": "/Users/sac/ash_a2a/lib/ash_a2a/reactor/execute_command.ex",
          "importance_score": 0.62,
          "interfaces": [
            {
              "description": null,
              "interface_type": "callback",
              "name": "run",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "arguments",
                  "param_type": "map"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "context",
                  "param_type": "map"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "options",
                  "param_type": "keyword list"
                }
              ],
              "return_type": "{:ok, term} | {:error, term}",
              "visibility": ""
            }
          ],
          "name": "execute_command.ex",
          "responsibilities": [
            "Implement the Reactor.Step behavior for AshA2A command execution",
            "Extract command and message payloads from Reactor step arguments",
            "Delegate command execution to AshA2A.CommandBus",
            "Preserve the architectural boundary preventing Reactor from calling AshA2A.Dispatcher directly"
          ],
          "source_summary": "The module uses the Reactor.Step behavior and implements the run/3 callback. Inside run, it extracts the :command and :message keys from the arguments map (via Map.fetch!) along with a resource or domain argument, then routes execution through AshA2A.CommandBus rather than the dispatcher. The moduledoc documents the design intent: Reactor coordinates the step while the CommandBus retains sole command execution authority.",
          "summary": "A Reactor step adapter that wraps AshA2A command execution so it can be invoked as a step within Reactor workflows, delegating all work to the AshA2A.CommandBus."
        }
      ],
      "importance_score": 0.62,
      "key_files": [
        "execute_command.ex"
      ],
      "name": "reactor",
      "path": "/Users/sac/ash_a2a/lib/ash_a2a/reactor",
      "purpose": "other",
      "subdirectory_count": 0,
      "summary": "The 'reactor' directory provides the integration layer between the AshA2A agent-to-agent framework and the Reactor workflow engine. It exposes AshA2A command execution as a composable Reactor step, deliberately routing all execution through AshA2A.CommandBus so Reactor acts only as an orchestrator without gaining independent authority over command dispatch."
    },
    {
      "file_count": 2,
      "file_insights": [
        {
          "code_purpose": "dao",
          "dependencies": [
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "EKV",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "import",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.ReceiptStore",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "import",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.Application",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "import",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.Command",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "import",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.Receipt",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "This file implements the production-grade storage backend for command receipts, backed by the EKV hex package (~> 0.4). Unlike the in-memory variant, receipts written here survive process and node restarts, making it the durable choice for real deployments. It expects the EKV instance to already be started and supervised under a configured :name, which AshA2A.Application.receipt_store_children/0 wires up automatically based on application configuration.",
          "file_path": "/Users/sac/ash_a2a/lib/ash_a2a/receipt_store/ekv.ex",
          "importance_score": 0.8,
          "interfaces": [
            {
              "description": null,
              "interface_type": "function",
              "name": "claim",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "command",
                  "param_type": "AshA2A.Command.t()"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "opts",
                  "param_type": "keyword()"
                }
              ],
              "return_type": "{:ok, AshA2A.Receipt.t()} | {:error, term()}",
              "visibility": ""
            },
            {
              "description": null,
              "interface_type": "function",
              "name": "commit",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "command",
                  "param_type": "AshA2A.Command.t()"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "opts",
                  "param_type": "keyword()"
                }
              ],
              "return_type": ":ok | {:error, term()}",
              "visibility": ""
            },
            {
              "description": null,
              "interface_type": "function",
              "name": "start_link",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "opts",
                  "param_type": "keyword()"
                }
              ],
              "return_type": "{:ok, pid()} | {:error, term()}",
              "visibility": ""
            }
          ],
          "name": "ekv.ex",
          "responsibilities": [
            "Persist command claim/commit receipt state to an on-disk EKV instance",
            "Implement the AshA2A.ReceiptStore behaviour for durable storage",
            "Integrate with the application supervision tree via a configured :name for the EKV process",
            "Ensure receipts survive process and node restarts"
          ],
          "source_summary": "The module documents itself as an EKV-backed durable receipt store and notes it is wired into the supervision tree via AshA2A.Application.receipt_store_children/0 when the :ash_a2a :receipt_store configuration selects it. It fulfills the AshA2A.ReceiptStore behaviour by translating claim/commit receipt operations into reads and writes against the configured EKV instance, keyed so a receipt survives restarts.",
          "summary": "Defines AshA2A.ReceiptStore.Ekv, a durable receipt store that persists command claim/commit state to an on-disk EKV key-value instance."
        },
        {
          "code_purpose": "dao",
          "dependencies": [
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "GenServer",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "import",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.ReceiptStore",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "import",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.Command",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "import",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.Identity",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "import",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.Receipt",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "This file provides a simple in-process receipt store implemented as a GenServer, holding receipts in a plain map as its state. It serves as the reference implementation of the AshA2A.ReceiptStore behaviour, suited for local development, testing, and runtime composition where durability across restarts is not required. Its state is not persisted, so all receipts are lost when the process or node stops.",
          "file_path": "/Users/sac/ash_a2a/lib/ash_a2a/receipt_store/memory.ex",
          "importance_score": 0.6,
          "interfaces": [
            {
              "description": null,
              "interface_type": "function",
              "name": "start_link",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "opts",
                  "param_type": "keyword()"
                }
              ],
              "return_type": "{:ok, pid()} | {:error, term()}",
              "visibility": ""
            },
            {
              "description": null,
              "interface_type": "function",
              "name": "init",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "state",
                  "param_type": "map()"
                }
              ],
              "return_type": "{:ok, map()}",
              "visibility": ""
            },
            {
              "description": null,
              "interface_type": "function",
              "name": "claim",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "command",
                  "param_type": "AshA2A.Command.t()"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "opts",
                  "param_type": "keyword()"
                }
              ],
              "return_type": "{:ok, AshA2A.Receipt.t()} | {:error, term()}",
              "visibility": ""
            }
          ],
          "name": "memory.ex",
          "responsibilities": [
            "Store command receipts in an in-process GenServer map state",
            "Implement the AshA2A.ReceiptStore behaviour for in-memory use",
            "Support named or unnamed GenServer startup via the :name option",
            "Handle claim (and related commit) operations via synchronous GenServer calls"
          ],
          "source_summary": "The module starts a GenServer whose state is a map, with start_link/1 allowing a custom process name via the :name option (defaulting to the module itself). It implements the ReceiptStore behaviour with a claim/2 callback that delegates through GenServer.call to a {:claim, command, ...} message handler, resolving the target server from opts, and aliases AshA2A's Command, Identity, and Receipt structs for its operations.",
          "summary": "Defines AshA2A.ReceiptStore.Memory, an in-memory GenServer-based reference implementation of the receipt store behaviour for local/runtime composition."
        }
      ],
      "importance_score": 0.75,
      "key_files": [
        "ekv.ex",
        "memory.ex"
      ],
      "name": "receipt_store",
      "path": "/Users/sac/ash_a2a/lib/ash_a2a/receipt_store",
      "purpose": "other",
      "subdirectory_count": 0,
      "summary": "The receipt_store directory contains pluggable storage implementations for command receipts in the AshA2A (Agent-to-Agent protocol) library. Both files implement the AshA2A.ReceiptStore behaviour to persist command claim/commit state: ekv.ex provides a durable, restart-surviving store backed by an on-disk EKV key-value instance, while memory.ex provides a lightweight in-process GenServer-based store for local development and runtime composition. Together they form the persistence layer that guarantees idempotent, at-least-once command processing across store backends."
    },
    {
      "file_count": 1,
      "file_insights": [
        {
          "code_purpose": "tool",
          "dependencies": [
            {
              "dependency_type": "import",
              "is_external": true,
              "line_number": null,
              "name": "Jason",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "import",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.Research",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "This module bridges formal research methodology (Executable Design Science) and the ash_a2a codebase by emitting structured, machine-verifiable receipts for claims. It deliberately scopes claims to only what the project's own test suite can actually assert, avoiding overclaiming. As a single-file research utility, it plays a supporting documentation/evidence role rather than a functional role in the A2A protocol itself.",
          "file_path": "/Users/sac/ash_a2a/lib/ash_a2a/research/erc.ex",
          "importance_score": 0.35,
          "interfaces": [
            {
              "description": null,
              "interface_type": "function",
              "name": "emit",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "result",
                  "param_type": "map()"
                }
              ],
              "return_type": "map()",
              "visibility": ""
            }
          ],
          "name": "erc.ex",
          "responsibilities": [
            "Model the EDSResult tuple structure (Claim, Artifact, Experiment, Environment, Execution, Evidence, Falsifier, Analysis, Reproduction)",
            "Emit machine-readable JSON receipts documenting research claims about the codebase",
            "Restrict claims to assertions the ash_a2a test suite can actually verify",
            "Keep claim evaluation logic separate from receipt recording"
          ],
          "source_summary": "Defines the AshA2A.Research.ERC module whose moduledoc explains its purpose as an Executable Research Claim receipt emitter, mirroring the nine-element EDSResult tuple (Claim, Artifact, Experiment, Environment, Execution, Evidence, Falsifier, Analysis, Reproduction). The module focuses on recording evidence as machine-readable JSON receipts scoped to ash_a2a's self-assertable test suite behavior, explicitly separating claim evaluation from claim recording.",
          "summary": "Implements the Executable Research Claim (ERC) receipt emitter, the concrete minimal implementation of the EDSResult tuple from the Executable Design Science charter. It records research claims as real machine-readable JSON receipts without deciding whether the claims hold."
        }
      ],
      "importance_score": 0.35,
      "key_files": [
        "erc.ex"
      ],
      "name": "research",
      "path": "/Users/sac/ash_a2a/lib/ash_a2a/research",
      "purpose": "other",
      "subdirectory_count": 0,
      "summary": "The research directory contains a single Elixir module, AshA2A.Research.ERC, which implements the Executable Research Claim (ERC) receipt emitter. It translates the Executable Design Science (EDS) result tuple - Claim, Artifact, Experiment, Environment, Execution, Evidence, Falsifier, Analysis, Reproduction - into concrete machine-readable JSON receipts scoped to what the ash_a2a test suite can assert about itself. This is auxiliary research/evidence infrastructure rather than core business logic, sitting apart from the library's main A2A protocol modules."
    },
    {
      "file_count": 10,
      "file_insights": [
        {
          "code_purpose": "service",
          "dependencies": [
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "ReqLLM",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "alias",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.Semantic.Admission",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "alias",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.Semantic.IR",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "alias",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.Semantic.Ontology",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "alias",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.Semantic.PlanningIR",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "alias",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.Semantic.Schema",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "This is the central pipeline coordinator of the semantic subsystem. It drives text through admitted semantics, ontology construction, PlanningIR manufacture, and final plan-candidate generation. It exposes a dependency-injection seam via the ':generate_object' opt, a real 4-arity function argument that defaults to ReqLLM.generate_object/4 in production and is replaced by anonymous functions in tests, avoiding mocking libraries.",
          "file_path": "/Users/sac/ash_a2a/lib/ash_a2a/semantic/compiler.ex",
          "importance_score": 0.95,
          "interfaces": [
            {
              "description": null,
              "interface_type": "function",
              "name": "compile",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "source",
                  "param_type": "AshA2A.Semantic.Source.t()"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "opts",
                  "param_type": "keyword() (incl. :generate_object)"
                }
              ],
              "return_type": "AshA2A.Semantic.ExecutionPackage.t()",
              "visibility": ""
            }
          ],
          "name": "compiler.ex",
          "responsibilities": [
            "Orchestrate the multi-stage semantic compilation pipeline end to end",
            "Invoke LLM structured extraction through an injectable 4-arity generate_object function",
            "Coordinate admission, ontology projection, and planning IR manufacturing",
            "Produce final plan candidates for downstream planning/runtime boundaries"
          ],
          "source_summary": "The module documents the end-to-end pipeline (text -> admitted semantics -> ontology -> PlanningIR -> HDDL/FOND candidate) and explicitly explains that the ':generate_object' option is a dependency-injection test seam defaulting to the real ReqLLM.generate_object/4, since live network LLM calls are not viable in tests.",
          "summary": "Orchestrates the full closed-loop semantic compilation pipeline from raw text to an HDDL/FOND plan candidate."
        },
        {
          "code_purpose": "model",
          "dependencies": [],
          "detailed_description": "IR is the central data model of the semantic subsystem: a candidate-only snapshot of everything extracted from one source, always with standing ':candidate' and authority ':none'. It provides field metadata and a from_map constructor that normalizes LLM-proposed maps into the typed struct, serving as the input contract for Admission, Ontology, and PlanningIR.",
          "file_path": "/Users/sac/ash_a2a/lib/ash_a2a/semantic/ir.ex",
          "importance_score": 0.9,
          "interfaces": [
            {
              "description": null,
              "interface_type": "function",
              "name": "from_map",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "source_id",
                  "param_type": "String.t()"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "proposed",
                  "param_type": "map()"
                }
              ],
              "return_type": "AshA2A.Semantic.IR.t()",
              "visibility": ""
            },
            {
              "description": null,
              "interface_type": "function",
              "name": "fields",
              "parameters": [],
              "return_type": "list(atom())",
              "visibility": ""
            },
            {
              "description": null,
              "interface_type": "function",
              "name": "items",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "ir",
                  "param_type": "AshA2A.Semantic.IR.t()"
                }
              ],
              "return_type": "list({atom(), map()})",
              "visibility": ""
            }
          ],
          "name": "ir.ex",
          "responsibilities": [
            "Model candidate semantic assertions across 13 typed collections",
            "Enforce source_id identity and default standing/authority (candidate/none)",
            "Normalize raw proposed maps into the typed IR struct via from_map",
            "Expose field and item iteration used by downstream projections"
          ],
          "source_summary": "Declares @fields covering entities, relations, events, goals, constraints, capabilities, authorities, observations, uncertainties, exclusions, temporal_relations, causal_hypotheses, and unresolved; enforces source_id, defaults standing to :candidate and authority to :none, and offers from_map/2 plus field/item accessors used by Schema, Ontology, and Admission.",
          "summary": "Defines the core candidate semantic state structure holding thirteen typed assertion collections extracted from a single source."
        },
        {
          "code_purpose": "service",
          "dependencies": [
            {
              "dependency_type": "alias",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.Semantic.IR",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "alias",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.Semantic.Source",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "Admission acts as the deterministic quality gate of the pipeline, deciding which LLM-proposed semantic candidates are allowed to become admitted state. It declares strict required-field contracts per collection so every admitted entity, relation, goal, constraint, capability, and authority carries complete provenance via source_quote.",
          "file_path": "/Users/sac/ash_a2a/lib/ash_a2a/semantic/admission.ex",
          "importance_score": 0.88,
          "interfaces": [
            {
              "description": null,
              "interface_type": "function",
              "name": "admit",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "candidate",
                  "param_type": "AshA2A.Semantic.IR.t()"
                }
              ],
              "return_type": "admission result (admitted | rejected)",
              "visibility": ""
            }
          ],
          "name": "admission.ex",
          "responsibilities": [
            "Validate required fields for each IR collection deterministically",
            "Reject incomplete candidates lacking source_quote provenance",
            "Admit only well-formed semantic state into downstream projections"
          ],
          "source_summary": "Aliases IR and Source and defines an @required map specifying mandatory fields for entities (id, kind, type, label, source_quote), relations (id, kind, subject, predicate, object, source_quote), goals/constraints/capabilities (id, kind, description, source_quote), and authorities (id, kind, subject, scope, mode, source_quote).",
          "summary": "Deterministic gatekeeper that validates candidate semantic state against required per-collection fields before admission."
        },
        {
          "code_purpose": "model",
          "dependencies": [
            {
              "dependency_type": "alias",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.Semantic.IR",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "alias",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.Semantic.Ontology",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "PlanningIR translates admitted semantic state and its ontology fingerprint into structures consumable by the formal planner. It carries goals, objects, predicates, constraints, task candidates, and nondeterminism markers, and like all semantic artifacts is fingerprinted, admitted-standing, and authority-free.",
          "file_path": "/Users/sac/ash_a2a/lib/ash_a2a/semantic/planning_ir.ex",
          "importance_score": 0.86,
          "interfaces": [
            {
              "description": null,
              "interface_type": "function",
              "name": "from_ontology",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "ir",
                  "param_type": "AshA2A.Semantic.IR.t()"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "ontology",
                  "param_type": "AshA2A.Semantic.Ontology.t()"
                }
              ],
              "return_type": "AshA2A.Semantic.PlanningIR.t()",
              "visibility": ""
            }
          ],
          "name": "planning_ir.ex",
          "responsibilities": [
            "Project admitted semantics into formal planning primitives",
            "Link the projection to its source ontology via ontology_fingerprint",
            "Capture nondeterminism and exclusions relevant to FOND planning",
            "Maintain fingerprinted, authority-free candidate provenance"
          ],
          "source_summary": "Enforces ontology_fingerprint, goals, objects, predicates, and fingerprint keys; defaults constraints, task_candidates, nondeterminism, observations, exclusions to empty lists with standing :admitted and authority :none, deriving the whole projection from admitted IR/Ontology inputs.",
          "summary": "Manufactures a formal-planning projection (goals, objects, predicates, nondeterminism) from admitted semantics for HDDL/FOND planning."
        },
        {
          "code_purpose": "model",
          "dependencies": [
            {
              "dependency_type": "alias",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.Planning.Candidate",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "alias",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.Semantic.IR",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "alias",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.Semantic.Ontology",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "alias",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.Semantic.PlanningIR",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "alias",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.Semantic.Source",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "ExecutionPackage is the immutable output envelope of the compiler, binding the source, semantic IR, ontology, PlanningIR, and plan candidate together under a content fingerprint. It supports lineage via parent_fingerprint and carries feedback and standing so downstream boundaries can consume a coherent, replayable candidate bundle.",
          "file_path": "/Users/sac/ash_a2a/lib/ash_a2a/semantic/execution_package.ex",
          "importance_score": 0.84,
          "interfaces": [
            {
              "description": null,
              "interface_type": "struct",
              "name": "struct",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "source",
                  "param_type": "AshA2A.Semantic.Source.t()"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "semantic_ir",
                  "param_type": "AshA2A.Semantic.IR.t()"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "ontology",
                  "param_type": "AshA2A.Semantic.Ontology.t()"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "planning_ir",
                  "param_type": "AshA2A.Semantic.PlanningIR.t()"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "plan_candidate",
                  "param_type": "AshA2A.Planning.Candidate.t()"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "fingerprint",
                  "param_type": "String.t()"
                }
              ],
              "return_type": "AshA2A.Semantic.ExecutionPackage.t()",
              "visibility": ""
            }
          ],
          "name": "execution_package.ex",
          "responsibilities": [
            "Aggregate all compilation artifacts into one immutable bundle",
            "Track content identity via fingerprint and lineage via parent_fingerprint",
            "Carry accumulated feedback and standing for closed-loop refinement",
            "Serve as the sole contract consumed by planning/runtime boundaries"
          ],
          "source_summary": "Defines @enforce_keys for source, semantic_ir, ontology, planning_ir, plan_candidate, and fingerprint; the struct additionally holds parent_fingerprint, a feedback list, and a standing field, aliased to AshA2A.Planning.Candidate and the Semantic modules.",
          "summary": "Candidate-only bundle aggregating all artifacts of one semantic compilation for consumption by planning/runtime boundaries."
        },
        {
          "code_purpose": "model",
          "dependencies": [
            {
              "dependency_type": "alias",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.Semantic.IR",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "alias",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.Semantic.Vocabulary",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "Ontology converts admitted semantic IR into RDF-style triples using the shared Vocabulary, producing a deterministic, fingerprinted projection suitable for semantic alignment. It enforces that only admitted, authority-free IR can be projected, preserving the pipeline's security invariants.",
          "file_path": "/Users/sac/ash_a2a/lib/ash_a2a/semantic/ontology.ex",
          "importance_score": 0.8,
          "interfaces": [
            {
              "description": null,
              "interface_type": "function",
              "name": "from_ir",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "ir",
                  "param_type": "AshA2A.Semantic.IR.t()"
                }
              ],
              "return_type": "AshA2A.Semantic.Ontology.t()",
              "visibility": ""
            }
          ],
          "name": "ontology.ex",
          "responsibilities": [
            "Project admitted IR into RDF-shaped triples deterministically",
            "Enforce admitted/authority-free preconditions via pattern matching",
            "Dedupe and track item ids for fingerprint computation"
          ],
          "source_summary": "from_ir/1 pattern-matches on IR with standing :admitted and authority :none, collects item ids into a MapSet, and builds the triple set and fingerprint into an enforced-keys struct (source_id, triples, fingerprint) with standing :admitted and authority :none.",
          "summary": "Builds a deterministic RDF-shaped triple projection of an admitted SemanticIR with a content fingerprint."
        },
        {
          "code_purpose": "model",
          "dependencies": [],
          "detailed_description": "Source represents the raw input evidence (text with media type, observation time, and provenance) feeding the compiler. Its identity is derived from content so identical admitted inputs can be replayed without minting new semantic subjects, making it evidence rather than executable authority.",
          "file_path": "/Users/sac/ash_a2a/lib/ash_a2a/semantic/source.ex",
          "importance_score": 0.78,
          "interfaces": [
            {
              "description": null,
              "interface_type": "constructor",
              "name": "new",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "attrs",
                  "param_type": "map() (id, text, media_type, provenance required)"
                }
              ],
              "return_type": "AshA2A.Semantic.Source.t()",
              "visibility": ""
            }
          ],
          "name": "source.ex",
          "responsibilities": [
            "Model immutable source evidence with media type and provenance",
            "Derive content-based identity for deterministic replay",
            "Prevent sources from carrying executable authority"
          ],
          "source_summary": "Enforces id, text, media_type, and provenance keys on the struct (with optional observed_at), and documents via moduledoc that sources are content-based evidence, not executable authority, enabling replay of the same admitted input.",
          "summary": "Immutable, content-addressed source material struct that anchors semantic compilation to provable evidence."
        },
        {
          "code_purpose": "model",
          "dependencies": [
            {
              "dependency_type": "alias",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.Receipt",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "alias",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.SemanticProjection",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "alias",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.Semantic.ExecutionPackage",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "Feedback closes the compilation loop by converting execution receipts into typed observations tied to a package fingerprint. Each record is fingerprinted and carries standing ':observed' with authority ':none', enabling re-planning based on real outcomes while preserving the pipeline's authority invariants.",
          "file_path": "/Users/sac/ash_a2a/lib/ash_a2a/semantic/feedback.ex",
          "importance_score": 0.74,
          "interfaces": [
            {
              "description": null,
              "interface_type": "function",
              "name": "from_receipt",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "receipt",
                  "param_type": "AshA2A.Receipt.t()"
                }
              ],
              "return_type": "AshA2A.Semantic.Feedback.t()",
              "visibility": ""
            }
          ],
          "name": "feedback.ex",
          "responsibilities": [
            "Convert execution receipts into typed planning feedback",
            "Bind feedback to its originating package fingerprint",
            "Keep feedback authority-free (:none) by design"
          ],
          "source_summary": "Enforces package_fingerprint, receipt_id, observation, and fingerprint on the struct (standing defaults :observed, authority :none), and provides from_receipt/1 to build a Feedback from an AshA2A.Receipt via SemanticProjection, referencing the ExecutionPackage.",
          "summary": "Typed receipt evidence fed back into semantic planning, strictly without granting authority."
        },
        {
          "code_purpose": "types",
          "dependencies": [
            {
              "dependency_type": "alias",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.Semantic.IR",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "Schema programmatically derives a strict JSON-schema-like object from the IR field list, requiring every collection to be an array of assertion items and constraining authority to the single enum value 'none'. It guarantees LLM outputs conform to the IR's shape before from_map normalization.",
          "file_path": "/Users/sac/ash_a2a/lib/ash_a2a/semantic/schema.ex",
          "importance_score": 0.72,
          "interfaces": [
            {
              "description": null,
              "interface_type": "function",
              "name": "extraction",
              "parameters": [],
              "return_type": "map() (JSON-schema style structured-output contract)",
              "visibility": ""
            }
          ],
          "name": "schema.ex",
          "responsibilities": [
            "Generate the structured-output schema for LLM extraction",
            "Mirror IR field definitions as array-of-assertion contracts",
            "Hard-constrain authority to 'none' at the schema level",
            "Reject unknown properties via additionalProperties false"
          ],
          "source_summary": "Builds a 'collections' map from IR.fields() where each field maps to an array-of-assertion schema, then assembles a top-level object with additionalProperties false, all collections as required, and an authority property restricted to enum [\"none\"].",
          "summary": "Defines the JSON structured-output contract the LLM must satisfy during semantic extraction."
        },
        {
          "code_purpose": "config",
          "dependencies": [],
          "detailed_description": "Vocabulary anchors ontology projections to established public namespaces (RDF, RDFS, OWL, PROV, Time, ODRL, SKOS, Schema.org) rather than ad-hoc terms, supporting semantic alignment and interoperability. It serves as the shared term registry used when Ontology materializes triples.",
          "file_path": "/Users/sac/ash_a2a/lib/ash_a2a/semantic/vocabulary.ex",
          "importance_score": 0.62,
          "interfaces": [
            {
              "description": null,
              "interface_type": "function",
              "name": "prefixes",
              "parameters": [],
              "return_type": "map(String.t(), String.t())",
              "visibility": ""
            }
          ],
          "name": "vocabulary.ex",
          "responsibilities": [
            "Register standard semantic namespace prefixes and URIs",
            "Provide lookup of prior-art terms for ontology projection",
            "Promote interoperability over ad-hoc vocabulary invention"
          ],
          "source_summary": "Defines an @prefixes map associating short prefixes (rdf, rdfs, owl, prov, time, odrl, skos, schema) with their canonical namespace URIs, described as a prior-art-first registry for semantic alignment.",
          "summary": "Prior-art-first namespace registry mapping semantic prefixes to standard RDF/OWL/PROV/ODRL/SKOS vocabularies."
        }
      ],
      "importance_score": 0.92,
      "key_files": [
        "compiler.ex",
        "ir.ex",
        "admission.ex",
        "planning_ir.ex",
        "execution_package.ex"
      ],
      "name": "semantic",
      "path": "/Users/sac/ash_a2a/lib/ash_a2a/semantic",
      "purpose": "other",
      "subdirectory_count": 0,
      "summary": "The 'semantic' directory is the core closed-loop semantic compilation engine of AshA2A: it converts immutable, content-addressed source text into LLM-extracted candidate semantic IR, deterministically gates (admits) that state, projects it into RDF-shaped ontologies and formal planning IR (HDDL/FOND), and bundles everything into fingerprinted execution packages that can be refined via typed receipt feedback. Data structures (IR, Source, Ontology, PlanningIR, ExecutionPackage, Feedback) flow through transformation gates (Admission, Compiler) under a shared RDF vocabulary and a strict structured-output schema, enforcing a security posture where semantics are always 'candidate' evidence with authority ':none'."
    },
    {
      "file_count": 1,
      "file_insights": [
        {
          "code_purpose": "middleware",
          "dependencies": [
            {
              "dependency_type": "require",
              "is_external": true,
              "line_number": null,
              "name": "Logger",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": ":telemetry",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "This module acts as a telemetry handler observing the AshA2A command execution pipeline. It registers handler IDs for dispatch stop events and command receipt commits, converting them into OCEL v2 event log entries. It is explicitly observational, adding replay, identity, and standing evidence from the canonical CommandBus without changing command behavior.",
          "file_path": "/Users/sac/ash_a2a/lib/ash_a2a/telemetry/ocel_forwarder.ex",
          "importance_score": 0.55,
          "interfaces": [
            {
              "description": null,
              "interface_type": "function",
              "name": "attach",
              "parameters": [],
              "return_type": ":ok",
              "visibility": ""
            },
            {
              "description": null,
              "interface_type": "function",
              "name": "detach",
              "parameters": [],
              "return_type": ":ok",
              "visibility": ""
            },
            {
              "description": null,
              "interface_type": "function",
              "name": "handle_event",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "event",
                  "param_type": "[atom()]"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "measurements",
                  "param_type": "map()"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "metadata",
                  "param_type": "map()"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "config",
                  "param_type": "term()"
                }
              ],
              "return_type": ":ok",
              "visibility": ""
            }
          ],
          "name": "ocel_forwarder.ex",
          "responsibilities": [
            "Capture raw dispatch telemetry spans via registered handlers",
            "Emit OCEL v2 event records for committed AshA2A command receipts",
            "Provide replay, identity, and standing evidence as observational logs",
            "Forward events on a best-effort basis without impacting command execution"
          ],
          "source_summary": "Defines the AshA2A.Telemetry.OcelForwarder module whose moduledoc describes best-effort OCEL v2 egress for dispatch spans and command receipt events. It requires Elixir's Logger and declares module attributes holding unique telemetry handler IDs for dispatch stop and receipt commit events, which are used to register observational event handlers.",
          "summary": "Implements best-effort OCEL v2 telemetry egress, forwarding raw dispatch spans and committed AshA2A command receipts as observational event logs."
        }
      ],
      "importance_score": 0.55,
      "key_files": [
        "ocel_forwarder.ex"
      ],
      "name": "telemetry",
      "path": "/Users/sac/ash_a2a/lib/ash_a2a/telemetry",
      "purpose": "other",
      "subdirectory_count": 0,
      "summary": "The telemetry directory provides observability infrastructure for the AshA2A project, exporting execution events in OCEL (Object-Centric Event Log) v2 format. Its single file, ocel_forwarder.ex, attaches telemetry handlers to capture raw dispatch spans and committed command receipts, forwarding them as purely observational event logs without affecting command behavior. It serves as a best-effort egress layer connecting internal AshA2A command execution to external audit and analysis tooling."
    },
    {
      "file_count": 2,
      "file_insights": [
        {
          "code_purpose": "module",
          "dependencies": [
            {
              "dependency_type": "alias",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.Identity",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "alias",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.RuntimeReceipt",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "runtime_check",
              "is_external": true,
              "line_number": null,
              "name": "Group",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "Code",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "This module bridges AshA2A to an optional 'Group' registry module in the host application, allowing agents to be organized into process/topology groups. It is designed for safe optional integration: it checks whether the Group module is loaded before use, and all mutating operations return RuntimeReceipt evidence rather than implying any Ash domain state or authority. This keeps cluster topology strictly auxiliary to the A2A task lifecycle.",
          "file_path": "/Users/sac/ash_a2a/lib/ash_a2a/topology/group.ex",
          "importance_score": 0.38,
          "interfaces": [
            {
              "description": null,
              "interface_type": "function",
              "name": "available?",
              "parameters": [],
              "return_type": "boolean()",
              "visibility": ""
            },
            {
              "description": null,
              "interface_type": "function",
              "name": "key",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "identity",
                  "param_type": "Identity.t()"
                }
              ],
              "return_type": "term()",
              "visibility": ""
            }
          ],
          "name": "group.ex",
          "responsibilities": [
            "Detect availability of the host Group registry module at runtime",
            "Derive topology group keys from AshA2A agent identities",
            "Expose ephemeral group membership observations",
            "Return RuntimeReceipt evidence for group mutations without implying domain state or authority"
          ],
          "source_summary": "Defines AshA2A.Topology.Group with an available?/0 guard implemented via Code.ensure_loaded?(Group) so the adapter works whether or not the host provides the Group module. It aliases AshA2A.Identity and AshA2A.RuntimeReceipt and includes a key/1 function (taking an Identity.t) that derives registry keys from agent identity; mutation paths are documented to return RuntimeReceipt evidence.",
          "summary": "Optional adapter for the host application's Group process/topology registry, used to observe and participate in process groups keyed by A2A agent identity. Mutations return RuntimeReceipt evidence and reads are treated as ephemeral observations only."
        },
        {
          "code_purpose": "module",
          "dependencies": [
            {
              "dependency_type": "alias",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.Identity",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "alias",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.RuntimeReceipt",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "Phoenix.Presence",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "This module integrates AshA2A with the host application's Phoenix.Presence so that agent presence (online/heartbeat status across nodes) can be observed as ephemeral topology. It enforces a clear boundary: presence never owns Ash domain state, A2A TaskID lifecycle, authority, or command execution standing. Availability is checked per-module so the adapter can be used with whichever host Presence module is configured.",
          "file_path": "/Users/sac/ash_a2a/lib/ash_a2a/topology/presence.ex",
          "importance_score": 0.42,
          "interfaces": [
            {
              "description": null,
              "interface_type": "function",
              "name": "available?",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "presence_module",
                  "param_type": "module()"
                }
              ],
              "return_type": "boolean()",
              "visibility": ""
            }
          ],
          "name": "presence.ex",
          "responsibilities": [
            "Check whether a host module implements Phoenix.Presence before use",
            "Expose ephemeral presence reads via the host Presence projection",
            "Wrap track/update/untrack provider mutations to return RuntimeReceipt evidence",
            "Preserve the boundary that presence carries no task lifecycle, authority, or command execution standing"
          ],
          "source_summary": "Defines AshA2A.Topology.Presence with an available?/1 function that verifies a given module is a usable Phoenix.Presence implementation. It aliases AshA2A.Identity and AshA2A.RuntimeReceipt and wraps track/update/untrack operations so provider mutations produce RuntimeReceipt evidence, while read functions project the host Presence state for ephemeral topology observation.",
          "summary": "Adapter for a host application's Phoenix.Presence module that treats presence as strictly ephemeral topology. Track/update/untrack operations are provider mutations returning RuntimeReceipt evidence, while reads return the host Presence projection."
        }
      ],
      "importance_score": 0.42,
      "key_files": [
        "presence.ex",
        "group.ex"
      ],
      "name": "topology",
      "path": "/Users/sac/ash_a2a/lib/ash_a2a/topology",
      "purpose": "other",
      "subdirectory_count": 0,
      "summary": "The topology directory contains thin integration adapters that expose ephemeral runtime topology information (process groups and Phoenix Presence) to the AshA2A library without letting it own domain state. Both files follow a strict pattern: read operations return ephemeral observations, while mutations (track/untrack, join/leave) return AshA2A.RuntimeReceipt evidence, and availability checks degrade gracefully when host modules are absent. Together they provide optional cluster-awareness plumbing that supports A2A agent discovery but carries no task lifecycle or authority semantics."
    },
    {
      "file_count": 1,
      "file_insights": [
        {
          "code_purpose": "plugin",
          "dependencies": [
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "Spark.Dsl.Transformer",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "import",
              "is_external": true,
              "line_number": null,
              "name": "Spark.Dsl.Transformer",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "This file implements a compile-time transformer behaviour (Spark.Dsl.Transformer) that runs as part of the AshA2A extension's DSL processing pipeline. It acts as a thin compatibility shim: although named BuildCapabilityIndex, version v26.9.12 stripped it of its original capability-manufacturing logic, leaving only persistence of leftover skill overrides and the subject kind. The actual capability index is computed later from a resource's public actions by the separate CapabilityIndex.Compiler module.",
          "file_path": "/Users/sac/ash_a2a/lib/ash_a2a/transformers/build_capability_index.ex",
          "importance_score": 0.5,
          "interfaces": [
            {
              "description": null,
              "interface_type": "callback_function",
              "name": "after?",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "other_transformers",
                  "param_type": "list(module())"
                }
              ],
              "return_type": "boolean()",
              "visibility": ""
            },
            {
              "description": null,
              "interface_type": "callback_function",
              "name": "transform",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "dsl",
                  "param_type": "Spark.Dsl.t()"
                }
              ],
              "return_type": "{:ok, Spark.Dsl.t()} | {:error, term()} (inferred, source truncated)",
              "visibility": ""
            }
          ],
          "name": "build_capability_index.ex",
          "responsibilities": [
            "Implement the Spark DSL transformer behaviour for the AshA2A extension pipeline",
            "Persist residual A2A skill overrides onto the DSL state at compile time",
            "Persist the subject kind in the extension's persisted DSL state",
            "Declare transformer ordering by returning false from after?/1",
            "Serve as a deprecated compatibility layer after capability index building moved to CapabilityIndex.Compiler"
          ],
          "source_summary": "The module AshA2A.Transformers.BuildCapabilityIndex uses the Spark.Dsl.Transformer behaviour and implements the after?/1 callback to return false, meaning it runs early (not after other transformers) in the transformer ordering. A truncated @impl callback (most likely transform/1) performs the actual DSL state mutation to store residual A2A skill overrides and the subject kind. The moduledoc documents the design change stating that the real capability index is derived from Ash.Resource.Info.public_actions/1 by AshA2A.CapabilityIndex.Compiler.",
          "summary": "A Spark DSL transformer for the AshA2A extension that persists residual A2A skill overrides and the subject kind during DSL compilation. Its historical capability-index-building role has been removed, with that responsibility delegated to AshA2A.CapabilityIndex.Compiler."
        }
      ],
      "importance_score": 0.5,
      "key_files": [
        "build_capability_index.ex"
      ],
      "name": "transformers",
      "path": "/Users/sac/ash_a2a/lib/ash_a2a/transformers",
      "purpose": "other",
      "subdirectory_count": 0,
      "summary": "The 'transformers' directory contains compile-time Spark DSL transformers for the AshA2A extension, which hook into the Ash framework's DSL processing pipeline to transform extension state when resources compile. Its single file, build_capability_index.ex, is a legacy transformer that since v26.9.12 no longer builds a capability model itself; it now only persists residual A2A skill overrides and the subject kind, deferring real capability index derivation to AshA2A.CapabilityIndex.Compiler based on Ash.Resource.Info.public_actions/1."
    },
    {
      "file_count": 3,
      "file_insights": [
        {
          "code_purpose": "command",
          "dependencies": [
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "Mix.Task",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "import",
              "is_external": false,
              "line_number": null,
              "name": "AshA2A.ArchitectureVerifier",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "This Mix task serves as an automated architecture enforcement gate for CI pipelines. It delegates to the AshA2A.ArchitectureVerifier module to run a fixed set of executable checks against real compiled code, ensuring structural invariants of the ash_a2a codebase are upheld.",
          "file_path": "/Users/sac/ash_a2a/lib/mix/tasks/ash_a2a.verify_architecture.ex",
          "importance_score": 0.6,
          "interfaces": [
            {
              "description": null,
              "interface_type": "function",
              "name": "run",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "argv",
                  "param_type": "list(String.t())"
                }
              ],
              "return_type": "void",
              "visibility": ""
            }
          ],
          "name": "ash_a2a.verify_architecture.ex",
          "responsibilities": [
            "Run executable architecture-invariant checks against compiled project code",
            "Act as a machine-checkable CI quality gate",
            "Delegate check logic to AshA2A.ArchitectureVerifier",
            "Report architecture violations to CI"
          ],
          "source_summary": "Declares Mix.Tasks.AshA2a.VerifyArchitecture with a @shortdoc labeling it as a CI-gate runner and a moduledoc explaining it runs a small, fixed set of real executable checks via AshA2A.ArchitectureVerifier against the project's own compiled code.",
          "summary": "Defines the `mix ash_a2a.verify_architecture` task, a CI gate that executes real, machine-checkable architecture-invariant checks against the repo's compiled code."
        },
        {
          "code_purpose": "command",
          "dependencies": [
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "Igniter",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "Igniter.Mix.Task",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "import",
              "is_external": true,
              "line_number": null,
              "name": "Mix",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "Follows the ash-extension-core-pack `install.ex.tmpl` template pattern, mirroring the dual-branch structure of ash_r2rml's installer. The file is gated by `Code.ensure_loaded?(Igniter)` per convention v26.9.10 so it compiles safely and behaves correctly whether or not the Igniter dependency is present.",
          "file_path": "/Users/sac/ash_a2a/lib/mix/tasks/ash_a2a.install.ex",
          "importance_score": 0.55,
          "interfaces": [
            {
              "description": null,
              "interface_type": "function",
              "name": "igniter",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "igniter",
                  "param_type": "Igniter.t()"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "argv",
                  "param_type": "list(String.t())"
                }
              ],
              "return_type": "Igniter.t()",
              "visibility": ""
            }
          ],
          "name": "ash_a2a.install.ex",
          "responsibilities": [
            "Scaffold and configure AshA2A into consuming projects via Igniter",
            "Gate installer behavior on Code.ensure_loaded?(Igniter)",
            "Follow the standardized ash-extension-core-pack installer template",
            "Support dual-branch execution depending on Igniter availability"
          ],
          "source_summary": "Defines an Igniter.Mix.Task installer with MIT SPDX headers that conditionally activates Igniter-driven code generation and modification logic; comments reference the originating template and a real-world sibling installer (ash_r2rml.install.ex) as the structural model.",
          "summary": "Igniter-based installer Mix task (`mix ash_a2a.install`) that scaffolds the AshA2A library into a host project, with the whole file gated by runtime detection of Igniter."
        },
        {
          "code_purpose": "command",
          "dependencies": [
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "Mix.Task",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "require",
              "is_external": false,
              "line_number": null,
              "name": "research/erc/ receipt files",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "A reporting Mix task that aggregates ERC receipt files into a per-claim ledger showing each claim id, its current evidence state, and dependencies. It explicitly avoids fabricating output, printing a real 'no receipts' line instead of an empty table when no receipts exist yet.",
          "file_path": "/Users/sac/ash_a2a/lib/mix/tasks/eds.ledger.ex",
          "importance_score": 0.45,
          "interfaces": [
            {
              "description": null,
              "interface_type": "function",
              "name": "run",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "argv",
                  "param_type": "list(String.t())"
                }
              ],
              "return_type": "void",
              "visibility": ""
            }
          ],
          "name": "eds.ledger.ex",
          "responsibilities": [
            "Read ERC receipt files from the research/erc/ directory",
            "Aggregate receipts into one ledger row per distinct claim id",
            "Display each claim's current evidence state and dependencies",
            "Print an honest 'no receipts' message when the ledger is empty"
          ],
          "source_summary": "Declares Mix.Tasks.Eds.Ledger with `use Mix.Task`, a moduledoc documenting ledger semantics (one row per distinct claim id, evidence state, dependencies, reading real receipt files under research/erc/), a @shortdoc, and an @impl run implementation.",
          "summary": "Defines the `mix eds.ledger` task, which prints the repo's real ERC (Executable Research Claim) ledger by reading receipt files under `research/erc/`, with honest handling of an empty ledger."
        }
      ],
      "importance_score": 0.48,
      "key_files": [
        "ash_a2a.verify_architecture.ex",
        "ash_a2a.install.ex",
        "eds.ledger.ex"
      ],
      "name": "tasks",
      "path": "/Users/sac/ash_a2a/lib/mix/tasks",
      "purpose": "other",
      "subdirectory_count": 0,
      "summary": "This directory contains Mix task (CLI command) definitions for the ash_a2a Elixir project: an Igniter-based installer task, an architecture-invariant verification task used as a CI gate, and a reporting task that prints the repo's ERC (Executable Research Claim) ledger. Together they provide developer tooling and quality-gate infrastructure rather than core business logic, with the installer and verifier delegating to library modules like AshA2A.ArchitectureVerifier."
    },
    {
      "file_count": 1,
      "file_insights": [
        {
          "code_purpose": "config",
          "dependencies": [
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "ferroplan",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "This manifest configures the standalone hddl_cli binary crate (version 0.1.0, edition 2021), whose sole purpose is to wrap the ferroplan HDDL planner behind a simple command-line interface. It documents the architectural decision to invoke the planner as a subprocess rather than linking it in-process via a NIF from ash_a2a's mix.exs. It also pins the ferroplan dependency to the exact commit used by beam4pm's ferroplan submodule, ensuring reproducible planner behavior across builds.",
          "file_path": "/Users/sac/ash_a2a/native/hddl_cli/Cargo.toml",
          "importance_score": 0.55,
          "interfaces": [],
          "name": "Cargo.toml",
          "responsibilities": [
            "Declare the hddl_cli binary crate metadata (name, version, edition)",
            "Pin the ferroplan dependency to the exact commit used by beam4pm's ferroplan submodule",
            "Document the subprocess-based integration rationale versus an in-process NIF dependency",
            "Define the CLI contract: HDDL domain/problem paths via argv, JSON UniversalPlan or error object on stdout"
          ],
          "source_summary": "The file declares package metadata (name hddl_cli, version 0.1.0, edition 2021) along with a detailed description explaining that the binary parses two HDDL file paths (domain, problem) from argv, calls ferroplan::solve_hddl from the canonical ferroplan repository, and prints the real UniversalPlan or a JSON error object on stdout. It further explains the rationale for choosing a subprocess over an in-process NIF/dependency referenced from ash_a2a's mix.exs, and pins ferroplan to the commit carried by beam4pm's submodule.",
          "summary": "Rust package manifest defining the hddl_cli binary crate, its metadata, and its pinned ferroplan planner dependency."
        }
      ],
      "importance_score": 0.68,
      "key_files": [
        "Cargo.toml"
      ],
      "name": "hddl_cli",
      "path": "/Users/sac/ash_a2a/native/hddl_cli",
      "purpose": "other",
      "subdirectory_count": 1,
      "summary": "The hddl_cli directory contains a small standalone Rust binary crate that acts as a subprocess bridge between the Elixir-based ash_a2a application and the Rust ferroplan HDDL planner. Its Cargo.toml declares a binary that reads domain and problem HDDL file paths from argv, delegates solving to ferroplan::solve_hddl (pinned to the exact commit carried by beam4pm's ferroplan submodule), and prints the resulting UniversalPlan or an {\"error\": ...} JSON object to stdout. The src subdirectory presumably holds the Rust entry-point source; the manifest explicitly documents why a subprocess is used instead of an in-process NIF dependency."
    },
    {
      "file_count": 1,
      "file_insights": [
        {
          "code_purpose": "entry",
          "dependencies": [
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "ferroplan::solve_hddl",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "ferroplan::PlannerLimits",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "std::env",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "std::fs",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "std::process::ExitCode",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "This file is the executable entry point of the project, serving as a thin but essential CLI wrapper around the ferroplan library's solve_hddl function (beam4pm's actual FOND HTN solver). It handles argument parsing, file I/O, result serialization to JSON, and process exit-code semantics. While the core planning logic resides in the ferroplan dependency, this file is the sole integration surface users interact with.",
          "file_path": "/Users/sac/ash_a2a/native/hddl_cli/src/main.rs",
          "importance_score": 0.8,
          "interfaces": [
            {
              "description": null,
              "interface_type": "function",
              "name": "main",
              "parameters": [],
              "return_type": "ExitCode",
              "visibility": ""
            }
          ],
          "name": "main.rs",
          "responsibilities": [
            "Parse command-line arguments to obtain HDDL domain and problem file paths",
            "Read the domain and problem files from disk",
            "Delegate solving to the ferroplan solve_hddl FOND HTN solver",
            "Serialize the resulting UniversalPlan to JSON on stdout",
            "Handle all errors uniformly by printing a JSON error object and exiting with code 1"
          ],
          "source_summary": "The main function begins with a doc comment explaining the CLI contract (argv[1] = domain file path, argv[2] = problem file path). It imports solve_hddl and PlannerLimits from the ferroplan crate plus std::env, std::fs, and std::process::ExitCode, then reads the two files, invokes the real solver, and prints the resulting UniversalPlan as JSON on success; on any failure (missing files, HDDL parse/ground/translate/solve errors) it prints a JSON error object and returns a failing ExitCode.",
          "summary": "Entry point of the HDDL-solve CLI binary that reads domain and problem file paths from argv, invokes the ferroplan FOND HTN solver, and emits the plan as JSON. It implements a simple success/error contract: JSON plan output with exit 0, or a JSON error object with exit 1."
        }
      ],
      "importance_score": 0.8,
      "key_files": [
        "main.rs"
      ],
      "name": "src",
      "path": "/Users/sac/ash_a2a/native/hddl_cli/src",
      "purpose": "core",
      "subdirectory_count": 0,
      "summary": "The src directory contains the binary crate entry point for a small HDDL-solve command-line application. Its single file, main.rs, orchestrates the entire execution flow: it parses domain and problem file paths from command-line arguments, reads those HDDL files, delegates solving to the real ferroplan FOND HTN solver via a Cargo path-dependency, and prints the resulting UniversalPlan as JSON on stdout with proper exit codes."
    },
    {
      "file_count": 1,
      "file_insights": [
        {
          "code_purpose": "model",
          "dependencies": [
            {
              "dependency_type": "import",
              "is_external": true,
              "line_number": null,
              "name": "rdf",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "import",
              "is_external": true,
              "line_number": null,
              "name": "rdfs",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "include",
              "is_external": false,
              "line_number": null,
              "name": "templates/extension.ex.eex",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "use",
              "is_external": false,
              "line_number": null,
              "name": "ggen_igniter",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "This file serves as the semantic schema for the ash-a2a pack, formally describing its domain concepts as an RDF/RDFS ontology. It anchors the pack's terminology under the ash_a2a namespace (http://seanchatmangpt.github.io/packs/ash-a2a#) and is intended to be consumed alongside the templates/extension.ex.eex code-generation template. It also carries a legacy disclosure warning readers that these artifacts predate ggen_igniter's GeneratorCapability pattern.",
          "file_path": "/Users/sac/ash_a2a/priv/ggen/ash_a2a/ontology.ttl",
          "importance_score": 0.55,
          "interfaces": [
            {
              "description": null,
              "interface_type": "namespace",
              "name": "ash_a2a",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "iri",
                  "param_type": "IRI"
                }
              ],
              "return_type": "prefix binding",
              "visibility": ""
            },
            {
              "description": null,
              "interface_type": "namespace",
              "name": "rdf",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "iri",
                  "param_type": "IRI"
                }
              ],
              "return_type": "prefix binding",
              "visibility": ""
            },
            {
              "description": null,
              "interface_type": "namespace",
              "name": "rdfs",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "iri",
                  "param_type": "IRI"
                }
              ],
              "return_type": "prefix binding",
              "visibility": ""
            }
          ],
          "name": "ontology.ttl",
          "responsibilities": [
            "Define the RDF/RDFS vocabulary (classes and properties) for the ash-a2a agent-to-agent pack",
            "Declare namespace prefixes mapping the ash_a2a, rdf, and rdfs terms to their IRIs",
            "Document the legacy status of the ontology relative to ggen_igniter's GeneratorCapability pattern",
            "Provide the semantic reference consumed by the pack's EEx code-generation templates"
          ],
          "source_summary": "The visible source declares @prefix bindings for ash_a2a, rdf, and rdfs namespaces, establishing the vocabulary's IRI base. A prominent 'LEGACY DISCLOSURE (v26.9.10 finish-all pass)' comment block instructs readers to review before use and notes the ontology plus templates/extension.ex.eex predate ggen_igniter's admitted GeneratorCapability pattern. The remainder of the file (truncated) presumably continues with class and property definitions for agent-to-agent concepts.",
          "summary": "A Turtle (RDF) ontology file defining the semantic vocabulary and namespace for the ash-a2a pack, including a legacy disclosure about superseded GeneratorCapability patterns."
        }
      ],
      "importance_score": 0.42,
      "key_files": [
        "ontology.ttl"
      ],
      "name": "ash_a2a",
      "path": "/Users/sac/ash_a2a/priv/ggen/ash_a2a",
      "purpose": "other",
      "subdirectory_count": 2,
      "summary": "The ash_a2a directory is a plugin/pack (likely for the Ash Framework Elixir ecosystem) that provides agent-to-agent (A2A) protocol integration. Its single visible file, ontology.ttl, is a Turtle/RDF ontology that defines the semantic vocabulary for the pack's concepts, declaring namespace prefixes and carrying a legacy disclosure noting that this ontology and the accompanying extension.ex.eex template predate the ggen_igniter 'GeneratorCapability' pattern. The two subdirectories (e.g., templates and implementation code) work with this ontology to generate Ash resources/extensions based on the defined terms."
    },
    {
      "file_count": 1,
      "file_insights": [
        {
          "code_purpose": "tool",
          "dependencies": [
            {
              "dependency_type": "use",
              "is_external": false,
              "line_number": null,
              "name": "ontology.ttl",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "use",
              "is_external": false,
              "line_number": null,
              "name": "ash_a2a",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "This file is a data-extraction query against the project's semantic layer, targeting the AshExtensionSpec singleton defined in the ash-a2a ontology. It was revised following a Zach-Daniel-style review pass (v26.9.10) to replace the earlier generic aex: prefixed DslSection/DslEntity shape with the concrete ash_a2a: prefixes that match the authored ontology.ttl. It serves as the canonical query used to pull spec and skill metadata out of the knowledge graph.",
          "file_path": "/Users/sac/ash_a2a/priv/ggen/ash_a2a/queries/spec.rq",
          "importance_score": 0.45,
          "interfaces": [
            {
              "description": null,
              "interface_type": "sparql_select",
              "name": "spec-extraction-query",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "graph",
                  "param_type": "RDF dataset/graph (implicit, ontology.ttl-loaded store)"
                }
              ],
              "return_type": "singleton row of AshExtensionSpec with nested Skill / Skill.Argument bindings",
              "visibility": ""
            }
          ],
          "name": "spec.rq",
          "responsibilities": [
            "Extract the singleton AshExtensionSpec row from the RDF graph",
            "Query the nested Skill entities associated with the spec",
            "Retrieve the Skill.Argument entity shape for each skill",
            "Maintain prefix alignment with the authored ontology.ttl (ash_a2a namespace)"
          ],
          "source_summary": "The file begins with a header comment documenting its purpose and the fix history: it previously used a PREFIX aex: <.../ash-extension-core#> with generic aex:DslSection/aex:DslSectionOf shapes written before ontology.ttl existed. The corrected version declares the ash_a2a: prefix bound to the <.../ash-a2a#> namespace from the real authored ontology.ttl and performs a singleton-row SELECT of the AshExtensionSpec together with its nested Skill and Skill.Argument entity structures.",
          "summary": "A SPARQL query file that extracts the singleton AshExtensionSpec row plus its nested Skill and Skill.Argument entities from the ash_a2a RDF ontology graph."
        }
      ],
      "importance_score": 0.42,
      "key_files": [
        "spec.rq"
      ],
      "name": "queries",
      "path": "/Users/sac/ash_a2a/priv/ggen/ash_a2a/queries",
      "purpose": "other",
      "subdirectory_count": 0,
      "summary": "The 'queries' directory holds SPARQL query artifacts used to extract structured specification data from the project's RDF knowledge graph. Its single file, spec.rq, performs a singleton-row extraction of the ash_a2a AshExtensionSpec along with its nested Skill and Skill.Argument entity shapes, aligned with the authored ontology.ttl prefixes."
    },
    {
      "file_count": 1,
      "file_insights": [
        {
          "code_purpose": "tool",
          "dependencies": [
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "spark",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "import",
              "is_external": true,
              "line_number": null,
              "name": "ash",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "igniter",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "This template is consumed by the ggen_igniter code generator and writes its rendered output to lib/ash_a2a.ex using its frontmatter `to:` directive. Its body hand-emits raw Elixir source, including defmodule declarations and %Spark.Dsl.Entity{} literals, to construct the A2A extension module. An embedded legacy disclosure comment (v26.9.10 finish-all pass) notes this hand-rendering pattern is superseded by the AGENTS.md doctrine, which instead requires an Igniter.Mix.Task composing real Ash/Igniter generators, and that the template predates that doctrine and has never been re-run through `mix ggen_igniter`.",
          "file_path": "/Users/sac/ash_a2a/priv/ggen/ash_a2a/templates/extension.ex.eex",
          "importance_score": 0.4,
          "interfaces": [
            {
              "description": null,
              "interface_type": "module",
              "name": "AshA2A (emitted defmodule)",
              "parameters": [],
              "return_type": "lib/ash_a2a.ex",
              "visibility": ""
            }
          ],
          "name": "extension.ex.eex",
          "responsibilities": [
            "Generate the lib/ash_a2a.ex module from EEx template assigns",
            "Hand-render Spark.Dsl.Entity literals defining the A2A Ash extension",
            "Declare the output destination via igniter-style `to:` frontmatter",
            "Document its own legacy status relative to the ggen_igniter AGENTS.md doctrine"
          ],
          "source_summary": "The visible source consists of frontmatter mapping the template output to lib/ash_a2a.ex followed by a legacy disclosure comment block. The comment explains that the template hand-renders defmodule and %Spark.Dsl.Entity{} literals directly, records that this contradicts the admitted composition pattern in ggen_igniter's AGENTS.md, and marks the file as predating that doctrine.",
          "summary": "An EEx template with `to:` frontmatter that generates lib/ash_a2a.ex by hand-rendering the AshA2A module with Spark DSL entity literals; explicitly self-documented as legacy."
        }
      ],
      "importance_score": 0.42,
      "key_files": [
        "extension.ex.eex"
      ],
      "name": "templates",
      "path": "/Users/sac/ash_a2a/priv/ggen/ash_a2a/templates",
      "purpose": "other",
      "subdirectory_count": 0,
      "summary": "The templates directory contains a single EEx code-generation template (extension.ex.eex) that renders the main AshA2A Elixir library module into lib/ash_a2a.ex via igniter-style `to:` frontmatter. Its body hand-emits raw Elixir defmodule declarations and %Spark.Dsl.Entity{} literals, a pattern the project's own ggen_igniter AGENTS.md doctrine explicitly marks as legacy/superseded in favor of composing real Ash/Igniter generators. As a legacy generation artifact, it serves as meta-infrastructure for the build toolchain rather than runtime business code."
    },
    {
      "file_count": 12,
      "file_insights": [
        {
          "code_purpose": "test",
          "dependencies": [
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "ash_a2a",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "beam4pm",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "HDDL planner",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "This file is a timestamped evidence artifact attesting that an HDDL-planned facilitator dispatched over A2A produced OCEL v2 events accepted by an out-of-process beam4pm ingest endpoint with HTTP 201 for every phase transition. It was recorded on a dirty worktree (sha dbb5cc0) under Elixir 1.19.5 / OTP 28 on host 'Mac'. It serves as the first recorded run in the ERC-001 claim series.",
          "file_path": "/Users/sac/ash_a2a/research/erc/ERC-001-1789199133588.json",
          "importance_score": 0.5,
          "interfaces": [
            {
              "description": null,
              "interface_type": "data_schema",
              "name": "ERC evidence record",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "artifact",
                  "param_type": "object"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "claim",
                  "param_type": "string"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "environment",
                  "param_type": "object"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "evidence",
                  "param_type": "object"
                }
              ],
              "return_type": "object",
              "visibility": ""
            }
          ],
          "name": "ERC-001-1789199133588.json",
          "responsibilities": [
            "Record the ERC-001 pipeline verification claim",
            "Pin evidence to a specific git commit and dirty-worktree state",
            "Capture runtime environment details (Elixir/OTP/host)",
            "Reference captured evidence artifacts (deviant capture file)"
          ],
          "source_summary": "The JSON contains an 'artifact' block with repo (ash_a2a), git_sha (dbb5cc06577111d5bf26fcbdc9ffbc32c1b7fede) and git_dirty=true, a 'claim' string describing the pipeline behavior, an 'environment' block (Elixir 1.19.5, OTP 28, hostname Mac), and an 'evidence' block referencing a deviant capture file under the beam4pm qualification gym_bridge directory.",
          "summary": "Evidence record for the earliest ERC-001 verification run of the end-to-end A2A-to-beam4pm pipeline claim. Captures the artifact, environment, and evidence captured during the run."
        },
        {
          "code_purpose": "test",
          "dependencies": [
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "ash_a2a",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "beam4pm",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "HDDL planner",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "This record is a near-immediate re-run of the ERC-001 claim on the same dirty commit (dbb5cc0), providing repetition evidence for the pipeline verification. It carries identical environment details (Elixir 1.19.5, OTP 28) and the same claim text, reinforcing confidence in the initial result.",
          "file_path": "/Users/sac/ash_a2a/research/erc/ERC-001-1789199220470.json",
          "importance_score": 0.45,
          "interfaces": [
            {
              "description": null,
              "interface_type": "data_schema",
              "name": "ERC evidence record",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "artifact",
                  "param_type": "object"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "claim",
                  "param_type": "string"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "environment",
                  "param_type": "object"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "evidence",
                  "param_type": "object"
                }
              ],
              "return_type": "object",
              "visibility": ""
            }
          ],
          "name": "ERC-001-1789199220470.json",
          "responsibilities": [
            "Provide a repeat run of the ERC-001 verification claim",
            "Confirm reproducibility on the same commit (dbb5cc0)",
            "Capture environment and evidence references"
          ],
          "source_summary": "The JSON mirrors the first ERC-001 record: artifact repo ash_a2a at sha dbb5cc06577111d5bf26fcbdc9ffbc32c1b7fede with git_dirty=true, environment Elixir 1.19.5/OTP 28 on host Mac, and evidence referencing a deviant capture file in beam4pm's qualification gym_bridge directory.",
          "summary": "Second ERC-001 evidence run, recorded roughly 90 seconds after the first against the same commit. Repeats the end-to-end A2A/OCEL/beam4pm ingestion claim."
        },
        {
          "code_purpose": "test",
          "dependencies": [
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "ash_a2a",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "beam4pm",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "HDDL planner",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "This record re-validates the ERC-001 claim against commit 2ed49ba403e5d8833f703b2489e3510c1979e1af with a dirty worktree, showing the pipeline continued to work after new changes. It introduces the 'depends_on' field (empty), indicating the evidence schema evolved to support claim dependency chains.",
          "file_path": "/Users/sac/ash_a2a/research/erc/ERC-001-1789200525841.json",
          "importance_score": 0.5,
          "interfaces": [
            {
              "description": null,
              "interface_type": "data_schema",
              "name": "ERC evidence record",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "artifact",
                  "param_type": "object"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "claim",
                  "param_type": "string"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "depends_on",
                  "param_type": "array"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "environment",
                  "param_type": "object"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "evidence",
                  "param_type": "object"
                }
              ],
              "return_type": "object",
              "visibility": ""
            }
          ],
          "name": "ERC-001-1789200525841.json",
          "responsibilities": [
            "Re-validate ERC-001 claim on a newer commit",
            "Introduce the depends_on schema field",
            "Pin evidence to commit 2ed49ba and record environment"
          ],
          "source_summary": "The JSON contains the artifact block (repo ash_a2a, sha 2ed49ba403e5d8833f703b2489e3510c1979e1af, git_dirty=true), an empty depends_on array, the ERC-001 claim about HDDL/A2A/OCEL v2/beam4pm HTTP 201 ingestion, environment Elixir 1.19.5/OTP 28 on Mac, and an evidence block with a deviant capture file path under beam4pm qualification.",
          "summary": "ERC-001 evidence run against a newer commit (2ed49ba), adding an explicit depends_on field. Continues validating the end-to-end OCEL v2 ingestion pipeline."
        },
        {
          "code_purpose": "test",
          "dependencies": [
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "ash_a2a",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "beam4pm",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "HDDL planner",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "This evidence record attests the end-to-end pipeline claim against commit faa86055591cdf2bda867a4c033b8b6f18b79780 with git_dirty=false, meaning the verification was performed on exactly the committed code state. This makes it the most reproducible and trustworthy ERC-001 record in the directory.",
          "file_path": "/Users/sac/ash_a2a/research/erc/ERC-001-1789301803779.json",
          "importance_score": 0.6,
          "interfaces": [
            {
              "description": null,
              "interface_type": "data_schema",
              "name": "ERC evidence record",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "artifact",
                  "param_type": "object"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "claim",
                  "param_type": "string"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "depends_on",
                  "param_type": "array"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "environment",
                  "param_type": "object"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "evidence",
                  "param_type": "object"
                }
              ],
              "return_type": "object",
              "visibility": ""
            }
          ],
          "name": "ERC-001-1789301803779.json",
          "responsibilities": [
            "Record ERC-001 evidence on a clean, committed code state",
            "Provide highest-provenance verification of the pipeline claim",
            "Capture environment and evidence references for audit"
          ],
          "source_summary": "The JSON records artifact repo ash_a2a at sha faa86055591cdf2bda867a4c033b8b6f18b79780 with git_dirty=false, an empty depends_on array, the standard ERC-001 claim text, environment Elixir 1.19.5/OTP 28 on Mac, and evidence referencing the beam4pm qualification deviant capture path.",
          "summary": "The only ERC-001 record captured from a clean (non-dirty) worktree at commit faa86055, giving it the strongest provenance in the series. Validates the pipeline claim on committed, reproducible code."
        },
        {
          "code_purpose": "test",
          "dependencies": [
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "ash_a2a",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "beam4pm",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "HDDL planner",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "This record repeats the ERC-001 end-to-end pipeline verification at commit faa86055 with git_dirty=true, taken roughly seventeen minutes after the clean-worktree run. It shows the claim held under iteration but with weaker provenance than its clean counterpart.",
          "file_path": "/Users/sac/ash_a2a/research/erc/ERC-001-1789302824467.json",
          "importance_score": 0.5,
          "interfaces": [
            {
              "description": null,
              "interface_type": "data_schema",
              "name": "ERC evidence record",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "artifact",
                  "param_type": "object"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "claim",
                  "param_type": "string"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "depends_on",
                  "param_type": "array"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "environment",
                  "param_type": "object"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "evidence",
                  "param_type": "object"
                }
              ],
              "return_type": "object",
              "visibility": ""
            }
          ],
          "name": "ERC-001-1789302824467.json",
          "responsibilities": [
            "Repeat ERC-001 verification on commit faa86055",
            "Document dirty-worktree run conditions",
            "Reference captured evidence for auditability"
          ],
          "source_summary": "The JSON holds the artifact block (ash_a2a at faa86055591cdf2bda867a4c033b8b6f18b79780, git_dirty=true), empty depends_on, the ERC-001 claim about HDDL/A2A/OCEL v2 events accepted by beam4pm's ingest endpoint (HTTP 201), environment Elixir 1.19.5/OTP 28 on Mac, and evidence pointing to the qualification deviant capture file.",
          "summary": "ERC-001 re-run on the same commit (faa86055) but with a dirty worktree, recorded shortly after the clean run. Provides repeat evidence while local changes were present."
        },
        {
          "code_purpose": "test",
          "dependencies": [
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "ash_a2a",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "beam4pm",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "HDDL planner",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "This is the most recent ERC-001 record, re-validating the HDDL/A2A/OCEL v2/beam4pm ingestion claim at commit 5074dbb04963edb235dcac89cfd1d4344d2a9285. Notably, its environment reports OTP 27 rather than 28, providing cross-runtime verification coverage for the claim.",
          "file_path": "/Users/sac/ash_a2a/research/erc/ERC-001-1789374865346.json",
          "importance_score": 0.6,
          "interfaces": [
            {
              "description": null,
              "interface_type": "data_schema",
              "name": "ERC evidence record",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "artifact",
                  "param_type": "object"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "claim",
                  "param_type": "string"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "depends_on",
                  "param_type": "array"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "environment",
                  "param_type": "object"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "evidence",
                  "param_type": "object"
                }
              ],
              "return_type": "object",
              "visibility": ""
            }
          ],
          "name": "ERC-001-1789374865346.json",
          "responsibilities": [
            "Provide the latest ERC-001 pipeline verification run",
            "Extend claim coverage to the OTP 27 runtime",
            "Pin evidence to commit 5074dbb0 for traceability"
          ],
          "source_summary": "The JSON contains the artifact block (ash_a2a, sha 5074dbb04963edb235dcac89cfd1d4344d2a9285, git_dirty=true), empty depends_on, the ERC-001 claim text, environment Elixir 1.19.5 with OTP 27 on host Mac, and evidence referencing the beam4pm qualification deviant capture file.",
          "summary": "Latest ERC-001 evidence run, executed on commit 5074dbb0 under OTP 27 instead of OTP 28. Demonstrates the pipeline claim holds across a different Erlang runtime."
        },
        {
          "code_purpose": "test",
          "dependencies": [
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "ash_a2a",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "beam4pm",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "Z.AI",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "This record captures the initial run of the client-side concurrency verification, where 50 dispatches were attempted concurrently against a Z.AI-backed avatar over real A2A. Its evidence block tracks attempted and completion counts plus failure reasons, feeding the dependent ERC-004 completion-rate claim.",
          "file_path": "/Users/sac/ash_a2a/research/erc/ERC-003-1789201496812.json",
          "importance_score": 0.5,
          "interfaces": [
            {
              "description": null,
              "interface_type": "data_schema",
              "name": "ERC evidence record",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "artifact",
                  "param_type": "object"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "claim",
                  "param_type": "string"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "depends_on",
                  "param_type": "array"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "environment",
                  "param_type": "object"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "evidence",
                  "param_type": "object"
                }
              ],
              "return_type": "object",
              "visibility": ""
            }
          ],
          "name": "ERC-003-1789201496812.json",
          "responsibilities": [
            "Record the ERC-003 concurrency verification run",
            "Track attempted dispatch counts and failure reasons",
            "Serve as the base evidence for ERC-004 completion-rate analysis"
          ],
          "source_summary": "The JSON records artifact ash_a2a at sha 4f0ab33be45590f8c0390f273e618f93589343ad (dirty), an empty depends_on array, the ERC-003 claim text about 45+ concurrent dispatches, environment Elixir 1.19.5/OTP 28 on Mac, and evidence including attempted=50, a completion count, and a failure_reasons map keyed by error tuples.",
          "summary": "First evidence record for the ERC-003 concurrency claim: 45+ live A2A dispatches to a Z.AI-backed avatar in flight simultaneously, each producing an OCEL v2 event ingested by beam4pm. Records 50 attempted dispatches at commit 4f0ab33."
        },
        {
          "code_purpose": "test",
          "dependencies": [
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "ash_a2a",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "beam4pm",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "Z.AI",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "This evidence record re-executes the ERC-003 verification at commit 9d061c9576df18c064a4912b1faa5174323fde8b, testing whether 45+ A2A dispatches can be genuinely in flight simultaneously. It pairs with the ERC-004 record taken at the same timestamp to assess completion rates under real rate limits.",
          "file_path": "/Users/sac/ash_a2a/research/erc/ERC-003-1789358762387.json",
          "importance_score": 0.5,
          "interfaces": [
            {
              "description": null,
              "interface_type": "data_schema",
              "name": "ERC evidence record",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "artifact",
                  "param_type": "object"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "claim",
                  "param_type": "string"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "depends_on",
                  "param_type": "array"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "environment",
                  "param_type": "object"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "evidence",
                  "param_type": "object"
                }
              ],
              "return_type": "object",
              "visibility": ""
            }
          ],
          "name": "ERC-003-1789358762387.json",
          "responsibilities": [
            "Re-validate the ERC-003 concurrency claim on a newer commit",
            "Capture dispatch attempt and failure statistics",
            "Support the dependent ERC-004 completion-rate records"
          ],
          "source_summary": "The JSON contains the artifact block (ash_a2a, sha 9d061c9576df18c064a4912b1faa5174323fde8b, git_dirty=true), empty depends_on, the ERC-003 claim text, environment Elixir 1.19.5/OTP 28 on Mac, and evidence with attempted=50 plus completion and failure_reasons details.",
          "summary": "Re-run of the ERC-003 concurrency claim on commit 9d061c9 under OTP 28. Repeats the 50-dispatch concurrency experiment against the Z.AI-backed avatar."
        },
        {
          "code_purpose": "test",
          "dependencies": [
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "ash_a2a",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "beam4pm",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "Z.AI",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "This is the most recent ERC-003 record, re-running the 50-dispatch concurrency verification at commit 5074dbb04963edb235dcac89cfd1d4344d2a9285 with OTP 27. It extends concurrency claim coverage across runtime versions and anchors the latest ERC-004 dependency in the same run session.",
          "file_path": "/Users/sac/ash_a2a/research/erc/ERC-003-1789374858338.json",
          "importance_score": 0.55,
          "interfaces": [
            {
              "description": null,
              "interface_type": "data_schema",
              "name": "ERC evidence record",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "artifact",
                  "param_type": "object"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "claim",
                  "param_type": "string"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "depends_on",
                  "param_type": "array"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "environment",
                  "param_type": "object"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "evidence",
                  "param_type": "object"
                }
              ],
              "return_type": "object",
              "visibility": ""
            }
          ],
          "name": "ERC-003-1789374858338.json",
          "responsibilities": [
            "Provide the latest ERC-003 concurrency verification run",
            "Extend claim coverage to OTP 27",
            "Anchor the paired ERC-004 completion-rate record"
          ],
          "source_summary": "The JSON holds the artifact block (ash_a2a at 5074dbb04963edb235dcac89cfd1d4344d2a9285, dirty), empty depends_on, the ERC-003 claim about 45+ concurrent dispatches producing OCEL v2 events accepted by beam4pm, environment Elixir 1.19.5/OTP 27 on Mac, and evidence with attempted=50 and failure_reasons data.",
          "summary": "Latest ERC-003 evidence run, executed on commit 5074dbb0 under OTP 27. Repeats the concurrency dispatch experiment on a different runtime version."
        },
        {
          "code_purpose": "test",
          "dependencies": [
            {
              "dependency_type": "use",
              "is_external": false,
              "line_number": null,
              "name": "ERC-003",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "ash_a2a",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "Z.AI",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "This record captures the outcome of the ERC-004 claim that at least 45 of 50 concurrent Z.AI dispatches complete successfully under the account's real rate limits. Its evidence shows attempted=50 but only completed=2, with a failure_reasons map detailing error causes, making this a documented failure/negative result that depends on the ERC-003 run taken at the same moment.",
          "file_path": "/Users/sac/ash_a2a/research/erc/ERC-004-1789201496832.json",
          "importance_score": 0.5,
          "interfaces": [
            {
              "description": null,
              "interface_type": "data_schema",
              "name": "ERC evidence record",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "artifact",
                  "param_type": "object"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "claim",
                  "param_type": "string"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "depends_on",
                  "param_type": "array"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "environment",
                  "param_type": "object"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "evidence",
                  "param_type": "object"
                }
              ],
              "return_type": "object",
              "visibility": ""
            }
          ],
          "name": "ERC-004-1789201496832.json",
          "responsibilities": [
            "Evaluate the ERC-004 completion-rate claim derived from ERC-003",
            "Record failure reasons for concurrent dispatch completion",
            "Document a negative result (2 of 50 completions) for rate-limit analysis"
          ],
          "source_summary": "The JSON contains artifact ash_a2a at sha 4f0ab33be45590f8c0390f273e618f93589343ad (dirty), depends_on=[ERC-003], the ERC-004 claim text, environment Elixir 1.19.5/OTP 28 on Mac, and evidence with attempted=50, completed=2, and failure_reasons keyed by error tuples such as '{:error, ...}'.",
          "summary": "First ERC-004 completion-rate record, dependent on ERC-003, evaluating whether 45+ of 50 concurrent dispatches complete successfully. Evidence shows only 2 completed, indicating the claim was not met under real rate limits."
        },
        {
          "code_purpose": "test",
          "dependencies": [
            {
              "dependency_type": "use",
              "is_external": false,
              "line_number": null,
              "name": "ERC-003",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "ash_a2a",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "Z.AI",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "This record re-evaluates the ERC-004 completion-rate claim at commit 9d061c9576df18c064a4912b1faa5174323fde8b under OTP 28, explicitly depending on ERC-003. The evidence again shows attempted=50 with completed=2 and structured failure reasons, confirming persistent rate-limit-driven failures across commits.",
          "file_path": "/Users/sac/ash_a2a/research/erc/ERC-004-1789358762405.json",
          "importance_score": 0.5,
          "interfaces": [
            {
              "description": null,
              "interface_type": "data_schema",
              "name": "ERC evidence record",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "artifact",
                  "param_type": "object"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "claim",
                  "param_type": "string"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "depends_on",
                  "param_type": "array"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "environment",
                  "param_type": "object"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "evidence",
                  "param_type": "object"
                }
              ],
              "return_type": "object",
              "visibility": ""
            }
          ],
          "name": "ERC-004-1789358762405.json",
          "responsibilities": [
            "Re-assess the ERC-004 completion-rate claim on a newer commit",
            "Track completion counts and failure reasons across runs",
            "Maintain the depends_on link to its paired ERC-003 record"
          ],
          "source_summary": "The JSON records artifact ash_a2a at sha 9d061c9576df18c064a4912b1faa5174323fde8b (dirty), depends_on=[ERC-003], the ERC-004 claim text about 45+ of 50 dispatches completing, environment Elixir 1.19.5/OTP 28 on Mac, and evidence with attempted=50, completed=2, and a failure_reasons map.",
          "summary": "ERC-004 completion-rate re-run on commit 9d061c9, paired with the ERC-003 record of the same timestamp. Again records only 2 of 50 concurrent dispatches completing successfully."
        },
        {
          "code_purpose": "test",
          "dependencies": [
            {
              "dependency_type": "use",
              "is_external": false,
              "line_number": null,
              "name": "ERC-003",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "ash_a2a",
              "path": null,
              "version": null
            },
            {
              "dependency_type": "use",
              "is_external": true,
              "line_number": null,
              "name": "Z.AI",
              "path": null,
              "version": null
            }
          ],
          "detailed_description": "This is the most recent ERC-004 record, re-evaluating the completion-rate claim at commit 5074dbb04963edb235dcac89cfd1d4344d2a9285 under OTP 27. It depends on ERC-003 and documents that completion rates remain far below the claimed 45+, with failure_reasons capturing the dominant error modes under real account rate limits.",
          "file_path": "/Users/sac/ash_a2a/research/erc/ERC-004-1789374858370.json",
          "importance_score": 0.55,
          "interfaces": [
            {
              "description": null,
              "interface_type": "data_schema",
              "name": "ERC evidence record",
              "parameters": [
                {
                  "description": null,
                  "is_optional": false,
                  "name": "artifact",
                  "param_type": "object"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "claim",
                  "param_type": "string"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "depends_on",
                  "param_type": "array"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "environment",
                  "param_type": "object"
                },
                {
                  "description": null,
                  "is_optional": false,
                  "name": "evidence",
                  "param_type": "object"
                }
              ],
              "return_type": "object",
              "visibility": ""
            }
          ],
          "name": "ERC-004-1789374858370.json",
          "responsibilities": [
            "Provide the latest ERC-004 completion-rate verification run",
            "Extend the negative result coverage to OTP 27",
            "Maintain the ERC-003 dependency link and failure-reason tracking"
          ],
          "source_summary": "The JSON contains artifact ash_a2a at sha 5074dbb04963edb235dcac89cfd1d4344d2a9285 (dirty), depends_on=[ERC-003], the ERC-004 claim text, environment Elixir 1.19.5 with OTP 27 on Mac, and evidence including attempted=50, completed=2, and a failure_reasons map keyed by error tuples.",
          "summary": "Latest ERC-004 completion-rate record, run on commit 5074dbb0 under OTP 27 alongside the newest ERC-003 record. Continues to document only 2 of 50 dispatches completing, extending the negative result to a new runtime."
        }
      ],
      "importance_score": 0.45,
      "key_files": [
        "ERC-001-1789374865346.json",
        "ERC-001-1789301803779.json",
        "ERC-003-1789374858338.json",
        "ERC-004-1789374858370.json"
      ],
      "name": "erc",
      "path": "/Users/sac/ash_a2a/research/erc",
      "purpose": "other",
      "subdirectory_count": 0,
      "summary": "The 'erc' directory is an evidence store of machine-readable verification records (ERC JSON files) for the ash_a2a project, each capturing a claim, the git artifact it was validated against, the runtime environment (Elixir/OTP), and structured evidence payloads. The records verify end-to-end process-mining integration (HDDL-planned facilitator dispatched over A2A producing OCEL v2 events accepted by beam4pm's HTTP ingest endpoint) and concurrency behavior of Z.AI-backed dispatches, with multiple re-runs per claim across different commits and OTP versions. ERC-004 records explicitly declare a depends_on link to ERC-003, forming a small dependency chain among claims."
    }
  ],
  "file_insights": []
}
```

## Memory Storage Statistics

**Total Storage Size**: 832460 bytes

- **timing**: 39 bytes (0.0%)
- **documentation**: 427140 bytes (51.3%)
- **studies_research**: 212827 bytes (25.6%)
- **preprocess**: 192454 bytes (23.1%)

## Generated Documents Statistics

Number of Generated Documents: 12

- Key Modules and Components Research Report_Message Dispatch & Trust Boundary
- Key Modules and Components Research Report_Developer Tooling & Governance
- Boundary Interfaces
- Key Modules and Components Research Report_Receipted Command Execution
- Core Workflows
- Key Modules and Components Research Report_Planning Synthesis
- Key Modules and Components Research Report_Semantic Compilation
- Key Modules and Components Research Report_Capability Projection & Discovery
- Architecture Description
- Key Modules and Components Research Report_Integration Adapters
- Key Modules and Components Research Report_Agent Runtime & Lifecycle
- Project Overview
