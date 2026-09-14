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
index into an `A2A.AgentCard` (name, skills). `AshA2A.Agent.__using__/1`
reads this same compiled card at macro-expansion time via
`__card_opts__/2`, so the `A2A.Agent` GenServer generated for a resource can
never advertise a skill the compiler didn't actually see.

When a message arrives, `AshA2A.Agent.__dispatch__/3` resolves the skill name,
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
`AshA2A.Agent.__dispatch__/3` path use (see below) -- not a parallel,
opt-in route only some callers happen to take.

## The ecosystem adapters are seams, not integrations

`AshA2A.Delivery.Oban`, `AshA2A.Topology.Group`, `AshA2A.Topology.Presence`,
`AshA2A.Durability.DurableServer`, and `AshA2A.Execution.FLAME` each guard
themselves with `Code.ensure_loaded?/1` and degrade to an `:unsupported`
error or a no-op when their provider isn't present. None of `oban`, `flame`,
a `Group` topology module, `Phoenix.Presence`, or a `DurableServer` provider
is a dependency of this project's `mix.exs` today. These modules exist so a
host that *does* depend on one of those libraries gets a receipted,
non-authoritative bridge to it (queue insertion records delivery only;
FLAME placement never gains independent authority; a `Group` registration
returns an `AshA2A.RuntimeReceipt`, never Ash domain truth) -- but inside
this repository, every one is exercised only by tests that stub the
provider or assert the `:unsupported` degradation path. They are real code
with no real collaborator to call yet.

`AshA2A.TaskLifecycle` is the same shape for a sixth dependency:
`AshStateMachine` is not installed here, so `possible_next_states/2` always
returns `{:error, {:unsupported, :ash_state_machine}}` in this repo -- the
module declares the canonical A2A state vocabulary for interoperability but
defers transition legality to the host's own `AshStateMachine` when present.

## CommandBus on the default dispatch path

`AshA2A.Agent.__dispatch__/3` now builds a real `AshA2A.Command` from the
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
(`AshA2A.Agent.__dispatch__/3` before any dispatch attempt at all, and
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
  (`AshA2A.ReceiptStore.Memory`); a host wanting durable receipts across
  restarts still configures `:receipt_store` to a real implementation, as
  before.

## The explicit semantic-request surface (v26.9.14)

The semantic-closed-loop pipeline (`Source -> SemanticIR -> Admission -> Ontology ->
PlanningIR -> SemanticSynthesis -> ExecutionPackage`, `AshA2A.Semantic.Compiler.compile/3`)
had zero non-test production caller until this surface. `AshA2A.Agent.__dispatch__/3` now
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

Two things remain real, disclosed gaps here too, matching this file's existing "not
silently resolved" convention: committed runtime evidence (a `Receipt`) does not yet
automatically reach `AshA2A.Semantic.Feedback`/`Compiler.replan/4` for a semantic-compiled
task's continuation, and there is no architecture-verifier gate yet asserting this surface
is production-reachable.
