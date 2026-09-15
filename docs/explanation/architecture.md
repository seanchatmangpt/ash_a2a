# Architecture

This explains how ash_a2a is actually put together today, not how it is
eventually meant to work. There are two layers in this codebase, and they are
at very different levels of maturity: a projection layer that is real, tested,
and wired into every dispatch, and an admission/receipt layer that is real
and tested but sits beside the default path rather than inside it.

## Layer 1: capability projection (the default path)

`AshA2A.Info.agent_card/2` and `AshA2A.CapabilityIndex.Compiler` turn a
resource or domain's `AshA2A` DSL entities into a compiled, persisted
capability index, and `AshA2A.CapabilityIndex.AgentCardBuilder` projects that
index into an `A2A.AgentCard` (name, skills). `AshA2A.Agent.__using__`
reads this same compiled card at macro-expansion time via
`__card_opts__/2`, so the `A2A.Agent` GenServer generated for a resource can
never advertise a skill the compiler didn't actually see.

When a message arrives, `AshA2A.Agent.__dispatch__` resolves the skill name,
pulls `history` off the `A2A.Agent.context()` and `auth_identity` out of
`context.metadata["a2a.auth"]` (populated only by `A2A.Plug.Auth` after real
credential verification -- never from caller-controlled `A2A.Message.metadata`),
and calls `AshA2A.Dispatcher.dispatch/5` directly. `Dispatcher` resolves
actor/tenant through `AshA2A.ContextResolver.from_a2a_message/4` and invokes
the real Ash action with the non-bang `Ash.Changeset.for_create/3` /
`Ash.Query.for_read/3` / `Ash.ActionInput.for_action/3` APIs. This chain --
projection, resolution, dispatch -- is what every `AshA2A.Agent` call goes
through today, and it is the only thing a plain `MyApp.EchoAgent` deployment
exercises.

Alongside it, `AshA2A.LLMProfiles` gives resources a role-based way to
resolve which LLM provider/model backs a given capability. It is real and
wired in wherever a resource author calls it, tested against a live call,
and orthogonal to admission -- it answers "which provider," not "was this
authorized."

## Layer 2: admission and receipts (real, and mandatory for consequence-bearing skills)

`AshA2A.Command`, `AshA2A.Authority`, `AshA2A.Identity`, and
`AshA2A.CommandBus.run/4` are the canonical receipted admission layer over
the same dispatcher. `CommandBus.run/4` looks up the skill via
`AshA2A.Info.skill/2` and reads its real, compiled `consequence`
classification (`AshA2A.Skill`'s `:observe` / `:change` / `:external_do` /
`:unknown` -- computed once at compile time from the real Ash `action.type`
plus any explicit `a2a do skill ..., consequence: ... end` override, never
re-derived ad hoc per caller). For `:change`/`:external_do` it requires an
`AshA2A.Authority` struct naming the same principal and capability the
command claims (`Authority.admits?/2`) -- a command with no authority, or
authority for a different principal or capability, is refused before
dispatch ever runs; `:unknown` is refused closed with
`:consequence_unclassified`, never silently treated as safe. Once admitted,
it asks a pluggable `AshA2A.ReceiptStore` to `claim/2` the command, keyed on
`command.command_id`: a fresh claim proceeds to real dispatch and commits an
`AshA2A.Receipt`; a claim already executed under that same `command_id` with
an identical `Command.fingerprint/1` is replayed by returning the stored
receipt instead of re-executing (a matching `command_id` with a *different*
fingerprint is a real `:command_conflict` refusal). This is real idempotency
and real evidence, not a sketch, and it is now the route both
`AshA2A.Reactor.ExecuteCommand`/the Oban/FLAME adapters AND the default
`AshA2A.Agent.__dispatch__` path use (see below) -- not a parallel,
opt-in route only some callers happen to take.

## The ecosystem adapters are real integrations, not just seams (as of v26.9.14)

`AshA2A.Delivery.Oban`, `AshA2A.Topology.Group`, `AshA2A.Topology.Presence`,
`AshA2A.Durability.DurableServer`, `AshA2A.Execution.FLAME`, and
`AshA2A.TaskLifecycle`'s `AshStateMachine` adapter each guard themselves
with `Code.ensure_loaded?/1` and degrade to an `:unsupported` error or a
no-op when their provider isn't present -- that adapter shape is unchanged.
What changed in v26.9.14: `oban`, `ash_oban`, `ash_state_machine`, and
`postgrex` are now real, direct dependencies of this project's own
`mix.exs` (`flame`/`durable_server`/`phoenix_pubsub`/`phoenix` already were),
and every one of these six providers now has a real Chicago-style
qualification test in this repository's own suite exercising it against a
genuinely running real collaborator -- not a stub, not merely the
`:unsupported` degradation path:

- `AshA2A.Delivery.Oban` -- `test/ash_a2a/oban_delivery_qualification_test.exs`:
  a real Postgres-backed `oban_jobs` table, a real `Oban.Worker` reconstructing
  an admitted `Command` and re-admitting through `CommandBus`, proving queue
  acceptance != execution receipt and that Oban's at-least-once delivery
  replays through `CommandBus` rather than double-executing.
- `AshA2A.Topology.Group` -- `test/ash_a2a/group_real_topology_test.exs`
  (single-node) and `test/ash_a2a/distributed_node_loss_test.exs` (two real
  BEAM nodes via `:peer`): real registration/membership/purge-on-death
  against the real `:group` dependency.
- `AshA2A.Topology.Presence` -- `test/ash_a2a_runtime_providers_integration_test.exs`:
  real `Phoenix.PubSub` + `Phoenix.Presence` track/list/untrack.
- `AshA2A.Durability.DurableServer` -- `test/ash_a2a_runtime_providers_integration_test.exs`
  (real managed GenServer lifecycle) and
  `test/ash_a2a/durable_server_real_restart_test.exs` (real OTP process
  death + real supervision-driven restart with real recovered state).
  Real cross-node rehome (a second real node taking over an orphaned task)
  remains unexercised -- a real, disclosed gap, not the same claim as the
  single-node restart evidence above.
- `AshA2A.Execution.FLAME` -- `test/ash_a2a/flame_real_placement_test.exs`:
  a real `FLAME.Pool` (`FLAME.LocalBackend`) genuinely placing a
  `CommandBus.run/4` dispatch on a distinct real process.
- `AshA2A.TaskLifecycle`'s `AshStateMachine` adapter --
  `test/ash_a2a/task_lifecycle_state_machine_test.exs`: a real fixture
  resource genuinely transitioning state through the real extension's
  compiled atomic guard.

None of this changes the authority model: queue insertion still only
records delivery, FLAME placement still never gains independent authority,
a `Group`/`Presence` registration still only returns an
`AshA2A.RuntimeReceipt`, never Ash domain truth, and a state transition is
still not a DO -- every one of these adapters still funnels any real
consequence through `AshA2A.CommandBus`, which the direct-Ash-DO census in
`test/ash_a2a_property_fuzz_test.exs`'s security re-audit (and this
project's own architecture verifier) confirm still holds.

`ash_r2rml` semantic mapping also moved from "refusal-path-only" to a real,
asserted mapping: `test/ash_a2a/semantic_projection_r2rml_real_test.exs`
exercises a real `AshR2RML.Resource`-extended fixture through
`AshR2RML.Resource.Verify`'s real compile-time admission and
`AshR2RML.render/1`'s real Turtle output, not merely the pre-existing
`:REFUSED_MISSING_SUBJECT_MAP` contrast case.

## CommandBus on the default dispatch path

`AshA2A.Agent.__dispatch__` now builds a real `AshA2A.Command` from the
inbound message and routes any skill whose real, compiled
`AshA2A.Skill.consequence` is `:change`/`:external_do` through
`AshA2A.CommandBus.run/4` (which itself calls the same
`AshA2A.Dispatcher.dispatch/5` unchanged) instead of calling `dispatch/5`
directly. Routing is by consequence classification, never by re-deriving a
binary judgment from `action.type` at dispatch time -- `action.type` alone
cannot tell a pure generic `:action` (a calculation, a read-shaped custom
query) from a real mutating/externally-effecting one, which is exactly why
this is a real, separate capability-truth field rather than an inline
`if action.type == :read` check (see "Consequence semantics" below).

`command_id` is the real, protocol-native `A2A.Message.message_id` -- not a
freshly generated id per dispatch -- so a genuine client retry (the same
`message_id` resent after a dropped response) engages `CommandBus`'s real
replay/conflict detection through this default path too: the same
`command_id` with an identical `Command.fingerprint/1` replays the original
receipt instead of re-executing; the same `command_id` with genuinely
different content is a real `:command_conflict` refusal.

`Authority` is synthesized per call via
`AshA2A.Authority.from_verified_identity/2` from the already-verified
`auth_identity` (`nil` for an unauthenticated caller, which fails
`:change`/`:external_do` admission closed with `:authority_required` before
the Ash action ever runs); this authority always admits for its own
principal/capability pair -- it does not replace or tighten Ash's own
actor/policy authorization, which still runs exactly as before inside the
wrapped `dispatch/5` call. Its `token_id` is deterministic (a stable hash of
`{subject, capability_id}`), not a fresh random one per call: a synthesized
*standing* claim ("this already-verified principal may act with this
capability") must be idempotent for the same pair, or every retry's
`Command.fingerprint/1` (which hashes the authority's `token_id`) would
differ from the last and permanently defeat replay detection -- a real,
reproduced-and-fixed regression, not a hypothetical.

## Other real additions this release

- **`AshA2A.SemanticSubject`** binds A2A command/receipt identity to a
  semantic graph digest, a generated-projection digest, and a manufacturer
  digest, folded into `Command.fingerprint/1` and copied into `Receipt`
  (`lib/ash_a2a/semantic_subject.ex`, `test/ash_a2a_semantic_subject_command_test.exs`).
  It is identity/evidence only: `CommandBus` remains the only DO path, and
  `SemanticSubject` grants no authority and never promotes `Receipt.standing`
  past `:observed` on its own.
- **Typed per-skill arguments**: `AshA2A.CapabilityIndex.Compiler.project/3`
  derives real `AshA2A.Argument` entries from `Ash.Resource.Info.action/2`'s
  real `arguments` (plus, for `:create`/`:update`, `action.accept`-derived
  attributes) instead of the previous hardcoded `arguments: []`. Consumed via
  `AshA2A.Info.capability_index/1`/`AshA2A.Info.skill/2` -- the wire
  `A2A.AgentCard` projection still cannot carry per-argument schema data (no
  such field on that vendored struct).
- **OCEL: one event per dispatch, not two.** A CommandBus-routed dispatch
  used to fire both `[:ash_a2a, :dispatch, :stop]` and
  `[:ash_a2a, :receipt, :committed]` as two separate HTTP-posted events for
  one logical action. `CommandBus.run/4` now correlates its internal
  `Dispatcher.dispatch/5` call so `AshA2A.Telemetry.OcelForwarder` merges the
  dispatch span's fields into the single receipt-derived event instead of
  posting both -- a direct (non-CommandBus) `Dispatcher.dispatch/5` caller is
  unaffected.
- **`mix ash_a2a.install` merges into an existing `extensions:` list** (via
  `Spark.Igniter.add_extension/5`, matching `ash_r2rml.install.ex`'s own
  pattern) instead of adding a second, separate `extensions:` option when the
  target module already declares one.

## Consequence semantics: not `action.type`

`AshA2A.Skill.consequence` (`:observe` / `:change` / `:external_do` /
`:unknown`) is computed once at compile time
(`AshA2A.CapabilityIndex.Compiler.project/3`) and carried as real capability
truth alongside `id`/`resource`/`action`, rather than recomputed ad hoc by
each consumer. Repository-native defaults: Ash `:read` -> `:observe`;
`:create`/`:update`/`:destroy` -> `:change`; a generic `:action` -> `:unknown`
unless a resource author explicitly overrides it
(`a2a do skill :name, :action, consequence: :observe | :change | :external_do end`).
An `:unknown` capability is refused closed by both enforcement points
(`AshA2A.Agent.__dispatch__` before any dispatch attempt at all, and
`CommandBus.admit/2` independently, for any caller reaching it directly) --
never treated as either safe-to-skip or safe-to-execute by default. This
exists because `action.type` alone is not a sufficient consequence calculus:
a real regression this design prevents was caught directly -- naively
routing every non-`:read` skill through `CommandBus` broke a real,
non-mutating multi-turn `:action` fixture (an ordinary pure calculation)
by failing it closed for lack of authority it never needed. Every
pre-existing generic `:action` skill in this repository has now been
explicitly classified (`:observe` for pure calculations/queries -- `ping`,
`whoami`, `converse`, `respond_to_prompt`, `verse`, `judge`, `run_phase`;
`:change` for the two that genuinely mutate real state --
`FreedomGym.Facilitator`'s `:next_phase`/`:reset_plan`, which advance/reset
a real in-memory plan position).

`:read` stays off the `CommandBus` route regardless of consequence
classification for a second, independent reason: a streaming `:read` reply
(`Dispatcher.run_read_stream/4`, PRD §3.7) would have its real
`Enumerable.t()` collapsed to a placeholder by `AshA2A.Receipt.from_reply/4`'s
`summarize/1` if routed through `CommandBus` -- `:read` is also, by its own
default, `:observe`, so this is consistent with, not an exception to, the
consequence-based routing rule above.

Two things remain real, disclosed gaps, not silently resolved by this work:

- **A new generic `:action` skill defaults to `:unknown` (refused) until a
  resource author explicitly classifies it.** This is intentional
  fail-closed behavior, not an oversight -- but it does mean a resource
  author adding a new generic action must remember to declare
  `consequence:` for it to be reachable through the default agent path at
  all.
- The default `ReceiptStore` is still the in-memory one
  (`AshA2A.ReceiptStore.Memory`, no persistence across a restart). A host
  wanting durable receipts across restarts can now configure a real,
  shipped alternative instead of writing their own:
  `AshA2A.ReceiptStore.Ekv` (`lib/ash_a2a/receipt_store/ekv.ex`), a real
  on-disk-persisted store backed by the `:ekv` dependency, auto-wired by
  `AshA2A.Application.receipt_store_children/0` when configured via
  `config :ash_a2a, :receipt_store, AshA2A.ReceiptStore.Ekv`. `CommandBus`
  marks a receipt's `standing: :durable` (vs. `:observed`) whenever the
  configured store declares itself durable (`durable?/0`), checked the same
  `Code.ensure_loaded?`/`function_exported?` way every other provider
  adapter in this file is detected -- no hardcoded module allowlist.

## The explicit semantic-request surface (v26.9.14)

The semantic-closed-loop pipeline (`Source -> SemanticIR -> Admission -> Ontology ->
PlanningIR -> SemanticSynthesis -> ExecutionPackage`, `AshA2A.Semantic.Compiler.compile/3`)
had zero non-test production caller until this surface. `AshA2A.Agent.__dispatch__` now
picks between two real routes before either the consequence-based `CommandBus` routing
above or the ordinary skill-resolution path ever runs:

- **Gate 1** — the target resource/domain declared `a2a do semantic_requests true end`
  (`AshA2A.Dsl`'s new `:a2a` section option, persisted by
  `AshA2A.Transformers.BuildCapabilityIndex` and read back via
  `AshA2A.Info.semantic_requests_enabled?/1`). Real compiled DSL truth, not a runtime
  check; defaults to `false`, so no existing resource's behavior changes.
- **Gate 2** — the caller's own inbound `A2A.Message.metadata` sets
  `:semantic_request`/`"semantic_request"` to `true`, resolved through the same
  atom-then-string `AshA2A.MetadataKey.get/2` convention `:skill` metadata already uses.

Only when **both** are true does dispatch reach the private `dispatch_semantic/2`, which
extracts the message's real text (`A2A.Message.text/1`) and calls
`AshA2A.Semantic.Compiler.compile/3` for real, converting the resulting
`AshA2A.Semantic.ExecutionPackage` into a real `AshA2A.Dispatcher.reply()` via the new
`AshA2A.Semantic.ExecutionPackage.to_reply/1`. Either gate false, or a message with no
`A2A.Part.Text` part, falls straight through to the ordinary skill-resolution path
(`dispatch_skill/4`) unchanged — this is a new, explicit route added beside the existing
one, never a content sniff of unstructured text and never a silent fallback for an
unrecognized skill name.

This route never joins `CommandBus`/`Authority`/`ReceiptStore`, and it cannot produce
anything mistakable for a `DO` receipt: `to_reply/1` only ever emits `standing:
"candidate"`, `authority: "none"` evidence (re-admitted `capability_ids`, the synthesized
`hddl`/`fond`/`rationale`, and the package's own content-addressed
`execution_package_fingerprint` for a later `Compiler.replan/4` continuation) or, for a
package that fails the same `standing: :candidate, authority: :none` fence
`ExecutionPackage.new/6` enforces at construction, a typed
`:semantic_package_authority_ceiling_violated` refusal. `Compiler.compile/3` calls
`AshA2A.LLMProfiles.model_spec!/1`, which genuinely `raise`s on a misconfigured LLM role —
unlike every other `AshA2A.Dispatcher` path's deliberately non-raising contract —
so `dispatch_semantic/2` wraps the whole compile in a real `rescue`, turning any real
compilation failure (misconfigured profile or otherwise) into a typed
`:semantic_compilation_failed` reply rather than crashing the shared `A2A.Agent`
GenServer and taking down every other in-flight task it is managing.

See [Enable semantic requests](../how-to/enable-semantic-requests.md) for the concrete
DSL declaration, the exact caller-side message shape, and the real reply field names.

Both gaps disclosed in an earlier revision of this section are now closed, real, and
tested -- corrected here rather than left stale:

- **Receipt -> feedback -> replan closure** is real: a follow-up `:semantic_request`
  message that also carries `:continuation_fingerprint` metadata (same
  `AshA2A.MetadataKey` atom-then-string convention as `:skill`/`:semantic_request`)
  correlates back to the real committed `AshA2A.Receipt` via the configured
  `AshA2A.ReceiptStore` and routes through `AshA2A.Semantic.Compiler.replan/4` for real
  (`Feedback.from_receipt/2` -> `PlanningIR.with_observation/2` -> re-synthesis) --
  `lib/ash_a2a/agent.ex`'s `dispatch_semantic_replan/2`,
  `test/ash_a2a_agent_semantic_replan_test.exs`. A missing/unresolvable continuation
  fingerprint falls through to a fresh compile rather than replanning silently against
  the wrong evidence. This closure is caller-triggered (a message must carry the
  fingerprint), not a background process that replans every receipt on its own.
- **Architecture-verifier coverage exists**: `mix ash_a2a.verify_architecture` (9/9 real
  checks) includes `check_semantic_requests_gate_compiles` (the DSL opt-in real-compiles
  as real capability truth) and `check_unopted_semantic_request_falls_through` (an
  unopted-in resource's `:semantic_request`-flagged dispatch real-falls-through to
  ordinary skill resolution, never silently routing to `Semantic.Compiler.compile/3`).
